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
    private let pickedFile: PickedVideoFile
    private let player = AVPlayer()
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
    private var clockWithoutFrame = 0.0
    private var lastClock: Double?
    private var lastStereoSequence: UInt64?
    private var frameRate: Float?
    private var trackDetails: String?

    init(pickedFile: PickedVideoFile) { self.pickedFile = pickedFile }

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
            video.videoLayer.player = player
            displayObservation = video.videoLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.publish() }
            }
        }
    }

    func setVideoFrameHandler(_ handler: ((CVPixelBuffer) -> Void)?) {
        guard !stopped else { return }
        frameHandler = handler
        resetFrameWatch()
        // The host hides its native view in VR. Keeping the layer associated
        // lets AVFoundation prepare the item before a sized output is available.
        MainActor.assumeIsolated { installStereoOutput() }
        if handler == nil, let item = player.currentItem { prerollIfPaused(item) }
    }

    @MainActor private func installStereoOutput() {
        stereo?.stop()
        stereo = nil
        guard let item = player.currentItem, let frameHandler else { return }
        var first = true
        stereo = AppleStereoFrameOutput(item: item, onAttach: { [weak self, weak item] in
            // Item size, and hence the stereo output, can become available
            // several event turns after the user paused. Preroll it after attach.
            DispatchQueue.main.async {
                guard let self, let item, self.frameHandler != nil else { return }
                self.prerollIfPaused(item)
            }
        }) { [weak self, weak item] buffer in
            guard let self, let item, self.player.currentItem === item else { return }
            frameHandler(buffer)
            if first {
                first = false
                DispatchQueue.main.async { [weak self] in self?.publish() }
            }
        }
    }

    private func prerollIfPaused(_ item: AVPlayerItem) {
        guard player.currentItem === item, item.status == .readyToPlay,
              !wantsPlayback, !seeking, pendingSeek == nil, !ended, !stopped else { return }
        seek(to: item.currentTime().seconds)
    }

    func load(fileURL: URL) throws { try load(fileURL: fileURL, startAt: 0, paused: false) }

    func load(fileURL: URL, startAt seconds: Double, paused: Bool) throws {
        guard !stopped, pickedFile.url == fileURL else { throw ClientError("无法打开所选文件，请重新选择视频。") }
        retireItem()
        ended = false
        failure = nil
        trackDetails = nil
        frameRate = nil
        wantsPlayback = false
        pendingSeek = seconds.isFinite && seconds > 0 ? seconds : nil
        let input = PickedAssetResourceLoader(file: pickedFile)
        let item = AVPlayerItem(asset: input.asset)
        loader = input
        player.replaceCurrentItem(with: item)
        MainActor.assumeIsolated { installStereoOutput() }
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
        for name in [NSNotification.Name.AVPlayerItemDidPlayToEndTime, .AVPlayerItemFailedToPlayToEndTime, .AVPlayerItemPlaybackStalled] {
            notifications.append(center.addObserver(forName: name, object: item, queue: .main) { [weak self, weak item] note in
                guard let self, let item, self.player.currentItem === item else { return }
                switch name {
                case .AVPlayerItemDidPlayToEndTime: self.ended = true
                case .AVPlayerItemFailedToPlayToEndTime:
                    let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                    self.failure = error?.localizedDescription ?? "系统播放器无法继续解码这部影片。"
                default: self.checkReportedStall(item)
                }
                self.publish()
            })
        }
        // An audio track can run while the video codec is unsupported. Check the
        // actual video tracks, independently of the item clock or audio readiness.
        trackCheck = Task { @MainActor [weak self, weak item] in
            guard let item else { return }
            do {
                for track in try await item.asset.loadTracks(withMediaType: .video) {
                    if try await track.load(.isDecodable) {
                        let formats = try? await track.load(.formatDescriptions)
                        let rate = try? await track.load(.nominalFrameRate)
                        guard !Task.isCancelled, let self, self.player.currentItem === item else { return }
                        self.frameRate = rate
                        self.trackDetails = Self.videoDescription(format: formats?.first, rate: rate)
                        self.publish()
                        return
                    }
                }
                guard !Task.isCancelled, let self, self.player.currentItem === item else { return }
                self.failure = "系统播放器没有找到可解码的视频轨道。"
                self.publish()
            } catch {
                guard !Task.isCancelled, let self, self.player.currentItem === item else { return }
                self.failure = error.localizedDescription
                self.publish()
            }
        }
    }

    private static func videoDescription(format: CMFormatDescription?, rate: Float?) -> String? {
        var fields: [String] = []
        if let format {
            let size = CMVideoFormatDescriptionGetDimensions(format)
            if size.width > 0, size.height > 0 { fields.append("\(size.width)×\(size.height)") }
            let code = CMFormatDescriptionGetMediaSubType(format)
            let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
            if bytes.allSatisfy({ (32...126).contains($0) }), let subtype = String(bytes: bytes, encoding: .ascii) {
                fields.append(subtype)
            }
        }
        if let rate, rate.isFinite, rate > 0 {
            fields.append(String(format: rate.rounded() == rate ? "%.0f fps" : "%.2f fps", Double(rate)))
        }
        return fields.isEmpty ? nil : fields.joined(separator: " · ")
    }

    func play() { play(waitForPausedFrame: false) }

    func play(waitForPausedFrame: Bool) {
        guard !stopped, player.currentItem != nil else { return }
        wantsPlayback = !waitForPausedFrame
        applyIntent()
    }

    func pause() {
        wantsPlayback = false
        player.pause()
        resetFrameWatch()
        stallCheck?.cancel()
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, !stopped, player.currentItem != nil else { return }
        pendingSeek = max(0, seconds)
        seekGeneration += 1
        seeking = false
        resetFrameWatch()
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
                    self.stereo?.refresh()
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

    private func resetFrameWatch() {
        clockWithoutFrame = 0
        lastClock = nil
        lastStereoSequence = nil
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

    private func publish() {
        guard !stopped, let item = player.currentItem else { return }
        let duration = item.duration.seconds
        let clock = item.currentTime().seconds
        let hasVideo = MainActor.assumeIsolated { stereo?.hasVideoFrame ?? surface?.videoLayer.isReadyForDisplay ?? false }
        var details = trackDetails
        if wantsPlayback && !ended && !seeking && visibleInForeground && player.timeControlStatus == .playing && clock.isFinite {
            let advance = lastClock.map { min(1, max(0, clock - $0)) } ?? 0
            lastClock = clock
            if !hasVideo {
                clockWithoutFrame += advance
                if clockWithoutFrame >= 6 { failure = "系统播放器的进度已前进，但未能输出视频画面。" }
            } else if let sequence = MainActor.assumeIsolated({ stereo?.frameSequence }), (frameRate ?? 0) >= 12 {
                clockWithoutFrame = lastStereoSequence == sequence ? clockWithoutFrame + advance : 0
                lastStereoSequence = sequence
                if clockWithoutFrame >= 8 {
                    details = [trackDetails, "VR 暂无新视频帧，可切换播放器测试"].compactMap { $0 }.joined(separator: " · ")
                }
            } else { clockWithoutFrame = 0 }
        } else { resetFrameWatch() }
        if item.status == .failed || player.status == .failed {
            failure = item.error?.localizedDescription ?? player.error?.localizedDescription ?? "系统播放器无法解码这个视频。"
        }
        let phase: PlaybackPhase
        if failure != nil { phase = .failed }
        else if ended { phase = .ended }
        else if item.status != .readyToPlay { phase = .opening }
        else if !wantsPlayback { phase = .paused }
        else { phase = player.timeControlStatus == .playing ? .playing : .opening }
        let length = duration.isFinite ? max(0, duration) : 0
        onUpdate?(PlaybackSnapshot(phase: phase, seconds: pendingSeek ?? (clock.isFinite ? max(0, clock) : 0),
                                   duration: length, seekable: item.status == .readyToPlay && length > 0,
                                   hasVideo: hasVideo, error: failure, videoDetails: details))
    }

    private func retireItem() {
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
        resetFrameWatch()
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
