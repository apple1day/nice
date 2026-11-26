import AVFoundation
import CoreVideo
import UIKit

private final class AppleVideoSurface: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var videoLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// For Apple-supported local containers, keep native decoding and display attached
/// to one item. Only stereo projection requests decoded video buffers from AVPlayer.
final class AppleFilePlaybackEngine: LocalPlaybackEngine {
    var onUpdate: ((PlaybackSnapshot) -> Void)?
    weak var diagnostics: PlaybackDiagnostics?
    private let pickedFile: PickedVideoFile?
    private let player = AVPlayer()
    private let afterglow: Bool
    private var preparingItem: AVPlayerItem?
    private var afterglowSourceSize = CGSize.zero
    private var firstPictureWatch = AfterglowFirstPictureWatch()
    private var firstPictureTimer: DispatchSourceTimer?
    private var surface: AppleVideoSurface?
    private var loader: PickedAssetResourceLoader?
    private var frameHandler: ((CVPixelBuffer) -> Void)?
    private var stereo: AppleStereoFrameOutput?
    private var observations: [NSKeyValueObservation] = []
    private var displayObservation: NSKeyValueObservation?
    private var notifications: [NSObjectProtocol] = []
    private var periodicObserver: Any?
    private var trackCheck: Task<Void, Never>?
    private var stallCheck: DispatchWorkItem?
    private var pendingSeek: Double?
    private var seeking = false
    private var seekGeneration = 0
    private var wantsPlayback = false
    private var ended = false
    private var stopped = false
    private var failure: String?
    private var frameWatch = AppleVideoFrameWatch()
    private var videoTimeRange: CMTimeRange?
    private var isSDR = false
    private var frameRate: Float?
    private var trackDetails: String?
    private var reportedPlaybackStalls = 0

    init(pickedFile: PickedVideoFile? = nil, afterglow: Bool = false) {
        self.pickedFile = pickedFile
        self.afterglow = afterglow
    }

    func attach(to view: UIView) {
        guard !stopped else { return }
        MainActor.assumeIsolated {
            let video = surface ?? AppleVideoSurface(frame: view.bounds)
            if video.superview !== view {
                video.removeFromSuperview()
                video.frame = view.bounds
                video.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                video.isUserInteractionEnabled = false
                video.videoLayer.videoGravity = .resizeAspect
                view.addSubview(video)
            }
            surface = video
            video.videoLayer.player = afterglow && frameHandler != nil ? nil : player
            displayObservation = video.videoLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.publish() }
            }
        }
    }

    func setVideoFrameHandler(_ handler: ((CVPixelBuffer) -> Void)?) {
        guard !stopped else { return }
        let returningToLayer = frameHandler != nil && handler == nil
        frameHandler = handler
        frameWatch = AppleVideoFrameWatch()
        // Keep the native display alive under the opaque stereo view. A ready
        // layer can be uncovered without an extra seek or decoder restart.
        let needsPreroll = MainActor.assumeIsolated {
            if afterglow { surface?.videoLayer.player = handler == nil ? player : nil }
            installStereoOutput()
            guard returningToLayer, let old = surface, let host = old.superview,
                  !old.videoLayer.isReadyForDisplay else { return false }
            // If the layer lost readiness, replace only the display surface.
            // Preroll the same item without overwriting a newer user seek.
            displayObservation = nil
            old.videoLayer.player = nil
            old.removeFromSuperview()
            surface = nil
            attach(to: host)
            return true
        }
        if needsPreroll, let item = player.currentItem { preroll(item) }
    }

    @MainActor private func installStereoOutput(on preparedItem: AVPlayerItem? = nil, recovery: Bool = false) {
        stereo?.stop()
        stereo = nil
        guard let item = preparedItem ?? player.currentItem, let frameHandler else { return }
        let format = afterglow ? AfterglowMovieOutput.Format(source: afterglowSourceSize, sdr: isSDR,
                                                             recovery: recovery) : nil
        stereo = AppleStereoFrameOutput(item: item, recovery: recovery, preferBiPlanar: { [weak self] in
            self?.isSDR == true
        }, afterglowFormat: format, onAttach: { [weak self, weak item] in
            // Item size, and hence the stereo output, can become available
            // several event turns after the user paused. Preroll it after attach.
            DispatchQueue.main.async {
                guard let self, let item, self.frameHandler != nil else { return }
                if !self.wantsPlayback { self.preroll(item) }
            }
        }) { [weak self, weak item] buffer, pts, firstInSequence in
            guard let self, let item, self.player.currentItem === item else { return }
            if self.afterglow && (self.seeking || self.pendingSeek != nil) { return }
            self.diagnostics?.decodedFrame(buffer, pts: pts)
            frameHandler(buffer)
            if self.afterglow && !self.firstPictureWatch.delivered {
                self.firstPictureWatch.receivedPicture()
                self.stopFirstPictureTimer()
            }
            if firstInSequence {
                DispatchQueue.main.async { [weak self] in self?.publish() }
            }
        }
    }

    private func preroll(_ item: AVPlayerItem) {
        guard player.currentItem === item, item.status == .readyToPlay,
              !seeking, pendingSeek == nil, !ended, !stopped else { return }
        seek(to: item.currentTime().seconds)
    }

    func load(fileURL: URL) throws { try load(fileURL: fileURL, startAt: 0, paused: false) }

    func load(fileURL: URL, startAt seconds: Double, paused: Bool) throws {
        guard !stopped else { throw ClientError("播放器已关闭，请重新打开视频。") }
        let newLoader: PickedAssetResourceLoader?
        let asset: AVURLAsset
        if let pickedFile {
            guard pickedFile.url == fileURL else { throw ClientError("无法打开所选文件，请重新选择视频。") }
            let input = PickedAssetResourceLoader(file: pickedFile)
            newLoader = input
            asset = input.asset
        } else {
            try OfflineMediaPolicy.validateLocalFile(fileURL)
            newLoader = nil
            asset = AVURLAsset(url: fileURL, options: [
                AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
            ])
        }
        retireItem()
        loader = newLoader
        ended = false
        failure = nil
        trackDetails = nil
        reportedPlaybackStalls = 0
        isSDR = false
        videoTimeRange = nil
        frameRate = nil
        wantsPlayback = false
        pendingSeek = seconds.isFinite && seconds > 0 ? seconds : (afterglow && paused ? 0 : nil)
        let item = AVPlayerItem(asset: asset)
        if afterglow {
            // Afterglow attaches its packed output before handing the item to AVPlayer.
            // Read the local video geometry first so an 8K BGRA surface is never
            // requested by default while waiting for AVPlayerItem.presentationSize.
            preparingItem = item
        } else {
            player.replaceCurrentItem(with: item)
            MainActor.assumeIsolated { installStereoOutput() }
        }
        observations = [
            item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
                DispatchQueue.main.async {
                    guard let self, let item, self.player.currentItem === item else { return }
                    self.applyIntent()
                    self.publish()
                }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.publish() }
            }
        ]
        periodicObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 5), queue: .main) {
            [weak self] _ in self?.publish()
        }
        let center = NotificationCenter.default
        if afterglow {
            notifications.append(center.addObserver(forName: UIApplication.willResignActiveNotification,
                object: nil, queue: .main) { [weak self] _ in self?.firstPictureWatch.suspend() })
        }
        for name in [NSNotification.Name.AVPlayerItemDidPlayToEndTime, .AVPlayerItemFailedToPlayToEndTime, .AVPlayerItemPlaybackStalled] {
            notifications.append(center.addObserver(forName: name, object: item, queue: .main) { [weak self, weak item] note in
                guard let self, let item, self.player.currentItem === item else { return }
                switch name {
                case .AVPlayerItemDidPlayToEndTime: self.ended = true
                case .AVPlayerItemFailedToPlayToEndTime:
                    let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                    self.failure = error?.localizedDescription ?? "系统播放器无法继续解码这部影片。"
                default:
                    if self.wantsPlayback, !self.seeking, !self.ended { self.reportedPlaybackStalls += 1 }
                    self.checkReportedStall(item)
                }
                self.publish()
            })
        }
        // An audio track can run while the video codec is unsupported. Check the
        // actual video tracks, independently of the item clock or audio readiness.
        trackCheck = Task { @MainActor [weak self, weak item] in
            guard let item else { return }
            do {
                let tracks = try await item.asset.loadTracks(withMediaType: .video)
                for track in tracks {
                    let decodable = try await track.load(.isDecodable)
                    // On the explicit Afterglow route try the single video
                    // track even if AVFoundation flags it as unsupported.
                    // Actual picture delivery is bounded by the startup check.
                    if decodable || (self?.afterglow == true && tracks.count == 1) {
                        let formats = try? await track.load(.formatDescriptions)
                        let rate = try? await track.load(.nominalFrameRate)
                        let range = try? await track.load(.timeRange)
                        let bitRate = try? await track.load(.estimatedDataRate)
                        let size = try? await track.load(.naturalSize)
                        guard !Task.isCancelled, let self,
                              self.player.currentItem === item || self.preparingItem === item else { return }
                        self.frameRate = rate
                        self.videoTimeRange = range
                        self.isSDR = Self.supportsSDRConversion(formats?.first)
                        self.trackDetails = Self.videoDescription(format: formats?.first, rate: rate, bitRate: bitRate)
                        if self.preparingItem === item {
                            self.afterglowSourceSize = size ?? .zero
                            if let format = formats?.first {
                                let display = CMVideoFormatDescriptionGetPresentationDimensions(format,
                                    usePixelAspectRatio: true, useCleanAperture: true)
                                if display.width > 0, display.height > 0 { self.afterglowSourceSize = display }
                            }
                            guard AfterglowMovieOutput.Format(source: self.afterglowSourceSize, sdr: self.isSDR,
                                                               recovery: false) != nil else {
                                self.failure = "Afterglow XR 无法读取该片的视频尺寸。"
                                self.publish()
                                return
                            }
                            self.firstPictureWatch.classifyTrack(decodable: decodable)
                            self.diagnostics?.event("Afterglow: packed movie output; trackDecodable=\(decodable)")
                            self.installStereoOutput(on: item)
                            self.player.replaceCurrentItem(with: item)
                            self.preparingItem = nil
                            self.applyIntent()
                        }
                        self.publish()
                        return
                    }
                }
                guard !Task.isCancelled, let self,
                      self.player.currentItem === item || self.preparingItem === item else { return }
                self.diagnostics?.event("AV: no decodable video track")
                self.failure = "系统播放器没有找到可解码的视频轨道。"
                self.publish()
            } catch {
                guard !Task.isCancelled, let self,
                      self.player.currentItem === item || self.preparingItem === item else { return }
                self.failure = error.localizedDescription
                self.publish()
            }
        }
    }

    // Preserve the existing system color conversion for HDR, wide gamut and
    // untagged sources. The two-plane shader handles conventional SDR video.
    private static func supportsSDRConversion(_ format: CMFormatDescription?) -> Bool {
        guard let format, let tags = CMFormatDescriptionGetExtensions(format) as? [String: Any],
              let transfer = tags[kCVImageBufferTransferFunctionKey as String] as? String,
              [kCVImageBufferTransferFunction_ITU_R_709_2 as String, kCVImageBufferTransferFunction_sRGB as String].contains(transfer)
        else { return false }
        if let matrix = tags[kCVImageBufferYCbCrMatrixKey as String] as? String,
           ![kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String, kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String].contains(matrix) {
            return false
        }
        if let primaries = tags[kCVImageBufferColorPrimariesKey as String] as? String {
            return [kCVImageBufferColorPrimaries_ITU_R_709_2 as String, kCVImageBufferColorPrimaries_SMPTE_C as String,
                    kCVImageBufferColorPrimaries_EBU_3213 as String].contains(primaries)
        }
        return true
    }

    private static func videoDescription(format: CMFormatDescription?, rate: Float?, bitRate: Float?) -> String? {
        var fields: [String] = []
        if let format {
            let size = CMVideoFormatDescriptionGetDimensions(format)
            if size.width > 0, size.height > 0 { fields.append("\(size.width)×\(size.height)") }
            let tags = CMFormatDescriptionGetExtensions(format) as? [String: Any]
            if let transfer = tags?[kCVImageBufferTransferFunctionKey as String] as? String {
                let names = [kCVImageBufferTransferFunction_ITU_R_709_2 as String: "BT.709",
                             kCVImageBufferTransferFunction_sRGB as String: "sRGB",
                             kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String: "PQ",
                             kCVImageBufferTransferFunction_ITU_R_2100_HLG as String: "HLG"]
                if let name = names[transfer] { fields.append(name) }
            }
            let code = CMFormatDescriptionGetMediaSubType(format)
            let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
            if bytes.allSatisfy({ (32...126).contains($0) }), let subtype = String(bytes: bytes, encoding: .ascii) {
                fields.append(subtype)
            }
        }
        if let rate, rate.isFinite, rate > 0 {
            fields.append(String(format: rate.rounded() == rate ? "%.0f fps" : "%.2f fps", Double(rate)))
        }
        if let bitRate, bitRate.isFinite, bitRate > 0 { fields.append(String(format: "%.1f Mb/s", Double(bitRate) / 1_000_000)) }
        return fields.isEmpty ? nil : fields.joined(separator: " · ")
    }

    func play() { play(waitForPausedFrame: false) }

    func play(waitForPausedFrame: Bool) {
        guard !stopped, player.currentItem != nil || preparingItem != nil else { return }
        wantsPlayback = !waitForPausedFrame
        updateFirstPictureTimer()
        applyIntent()
    }

    func pause() {
        wantsPlayback = false
        stopFirstPictureTimer()
        player.pause()
        frameWatch.interrupt()
        stallCheck?.cancel()
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, !stopped, player.currentItem != nil || preparingItem != nil else { return }
        firstPictureWatch.seek()
        pendingSeek = max(0, seconds)
        seekGeneration += 1
        seeking = false
        frameWatch.interrupt()
        stallCheck?.cancel()
        applyIntent()
    }

    private func applyIntent() {
        guard let item = player.currentItem, item.status == .readyToPlay,
              !stopped, failure == nil, !ended, !seeking else { return }
        if let target = pendingSeek {
            let request = seekGeneration
            seeking = true
            let duration = item.duration.seconds
            let clamped = duration.isFinite && duration > 0 ? min(target, duration) : target
            let time = CMTime(seconds: clamped, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak item] _ in
                DispatchQueue.main.async {
                    guard let self, let item, self.player.currentItem === item, self.seekGeneration == request else { return }
                    self.pendingSeek = nil
                    self.seeking = false
                    self.stereo?.refreshAfterSeek()
                    self.applyIntent()
                    self.publish()
                }
            }
        } else if wantsPlayback {
            player.play()
        } else {
            player.pause()
            MainActor.assumeIsolated { stereo?.refresh() }
        }
    }

    private var visibleInForeground: Bool {
        MainActor.assumeIsolated {
            guard let window = surface?.window, !window.isHidden else { return false }
            return window.windowScene.map { $0.activationState == .foregroundActive } ?? true
        }
    }

    private func checkReportedStall(_ item: AVPlayerItem) {
        stallCheck?.cancel()
        guard wantsPlayback, !seeking, visibleInForeground else { return }
        let start = item.currentTime().seconds
        let check = DispatchWorkItem { [weak self, weak item] in
            guard let self, let item, self.player.currentItem === item, self.wantsPlayback,
                  !self.seeking, !self.ended, self.visibleInForeground, self.player.timeControlStatus != .playing,
                  abs(item.currentTime().seconds - start) < 0.25 else { return }
            self.failure = "系统播放器停滞，未能继续播放该视频。"
            self.publish()
        }
        stallCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: check)
    }

    private func stopFirstPictureTimer() {
        firstPictureTimer?.cancel()
        firstPictureTimer = nil
        firstPictureWatch.suspend()
    }

    private func updateFirstPictureTimer() {
        guard afterglow else { return }
        guard frameHandler != nil, wantsPlayback, !stopped, !ended, failure == nil,
              !firstPictureWatch.delivered, let item = player.currentItem ?? preparingItem else {
            if firstPictureTimer != nil { stopFirstPictureTimer() }
            return
        }
        guard firstPictureTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(40))
        timer.setEventHandler { [weak self, weak item] in
            guard let self, let item, self.player.currentItem === item || self.preparingItem === item,
                  !self.stopped, !self.ended, self.failure == nil else { return }
            let clock = self.pendingSeek ?? item.currentTime().seconds
            let active = self.wantsPlayback && self.frameHandler != nil &&
                self.visibleInForeground && self.expectsVideo(at: clock)
            let playing = self.player.timeControlStatus == .playing && !self.seeking && self.pendingSeek == nil
            if let reason = self.firstPictureWatch.sample(at: ProcessInfo.processInfo.systemUptime,
                                                         active: active, playing: playing) {
                self.stopFirstPictureTimer()
                self.diagnostics?.event("Afterglow: no first picture (\(reason.rawValue)); requesting decoder fallback")
                self.failure = "Afterglow XR 未能解出首帧，正在尝试兼容播放。"
                self.publish()
            }
        }
        firstPictureTimer = timer
        timer.resume()
    }

    private func expectsVideo(at clock: Double) -> Bool {
        guard let range = videoTimeRange, range.isValid, range.duration.isNumeric,
              range.duration.seconds > 0, clock.isFinite else { return true }
        return clock >= range.start.seconds && clock < range.end.seconds
    }

    private func publish() {
        guard !stopped, let item = player.currentItem ?? preparingItem else { return }
        updateFirstPictureTimer()
        let duration = item.duration.seconds
        let clock = item.currentTime().seconds
        let projected = stereo != nil
        let active = wantsPlayback && !ended && !seeking && pendingSeek == nil && failure == nil &&
            visibleInForeground && player.timeControlStatus == .playing
        var details = trackDetails
        let hasVideo = MainActor.assumeIsolated {
            stereo?.setContinuousPull(active, paused: !wantsPlayback)
            let ready = surface?.videoLayer.isReadyForDisplay ?? false
            let hasImage = stereo?.hasVideoFrame ?? ready
            let wantsFramesAtClock = expectsVideo(at: clock)
            let action = frameWatch.sample(clock: clock, expectingVideo: active && wantsFramesAtClock,
                                           projected: projected, hasImage: hasImage,
                                           sequence: stereo?.frameSequence ?? 0, fps: frameRate)
            if let diagnostics {
                let route = stereo.map { "\($0.requestDescription) ticks=\($0.ticks) parked=\($0.isParked) uniquePTS=\($0.frameSequence)" } ?? "nativeLayer"
                diagnostics.appleStatus("item=\(item.status.rawValue) timeControl=\(player.timeControlStatus.rawValue) layerReady=\(ready) output=\(route) stalls=\(reportedPlaybackStalls)")
            }
            switch action {
            case .rebuildOutput:
                diagnostics?.event("AV: media time advanced without fresh video; rebuilding the video output on the same item")
                installStereoOutput(recovery: true)
            case .fail:
                diagnostics?.event("AV: media time advanced without fresh video; requesting decoder fallback")
                failure = "系统播放时间持续前进，视频画面没有更新。"
            case nil: break
            }
            if projected && frameWatch.rebuilt {
                details = [trackDetails, "已重连系统视频输出"].compactMap { $0 }.joined(separator: " · ")
            }
            return hasImage
        }
        if item.status == .failed || player.status == .failed {
            let error = (item.error ?? player.error) as NSError?
            if failure == nil {
                let domain = error?.domain == AVFoundationErrorDomain ? "AVFoundation" : "system"
                diagnostics?.event("AV failure: domain=\(domain) code=\(error?.code ?? 0)")
            }
            failure = error?.localizedDescription ?? "系统播放器无法解码这个视频。"
        }
        let phase: PlaybackPhase
        if failure != nil { phase = .failed }
        else if ended { phase = .ended }
        else if item.status != .readyToPlay { phase = .opening }
        else if !wantsPlayback { phase = .paused }
        else { phase = player.timeControlStatus == .playing ? .playing : .opening }
        if reportedPlaybackStalls > 0 {
            details = [details, "系统报告播放停顿 \(reportedPlaybackStalls) 次"].compactMap { $0 }.joined(separator: " · ")
        }
        let length = duration.isFinite ? max(0, duration) : 0
        onUpdate?(PlaybackSnapshot(phase: phase, seconds: pendingSeek ?? (clock.isFinite ? max(0, clock) : 0),
                                   duration: length, seekable: item.status == .readyToPlay && length > 0,
                                   hasVideo: hasVideo, error: failure, videoDetails: details))
    }

    private func retireItem() {
        stopFirstPictureTimer()
        firstPictureWatch = AfterglowFirstPictureWatch()
        preparingItem = nil
        afterglowSourceSize = .zero
        observations.removeAll()
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        notifications.removeAll()
        trackCheck?.cancel()
        trackCheck = nil
        stallCheck?.cancel()
        stallCheck = nil
        if let periodicObserver { player.removeTimeObserver(periodicObserver) }
        periodicObserver = nil
        MainActor.assumeIsolated { stereo?.stop(); stereo = nil }
        seekGeneration += 1
        seeking = false
        frameWatch = AppleVideoFrameWatch()
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        loader?.cancel()
        player.replaceCurrentItem(with: nil)
        loader = nil
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        onUpdate = nil
        frameHandler = nil
        displayObservation = nil
        retireItem()
        MainActor.assumeIsolated {
            surface?.videoLayer.player = nil
            surface?.removeFromSuperview()
            surface = nil
        }
    }

    deinit { stop() }
}
