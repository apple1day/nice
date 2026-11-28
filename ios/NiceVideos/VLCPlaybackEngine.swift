import Foundation
import UIKit
import CoreMedia
import CoreVideo
import MobileVLCKit
import ObjectiveC

// Each policy belongs to a single libVLC instance, including seek and replay reopens.
enum VLCDecoderPolicy: String {
    case automatic, software
}

// VMEM's callback only reports a fourcc and dimensions. Carry the color
// description we already read from this asset across the decoder fallback.
enum VLCFrameColor {
    case packedRGB
    case ycbcr(String)

    var matrix: String? {
        guard case let .ycbcr(matrix) = self else { return nil }
        return matrix
    }

    init?(format: CMFormatDescription?) {
        guard let format else { return nil }
        let tags = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        let sourceMatrix = tags[kCVImageBufferYCbCrMatrixKey as String] as? String
        let transfer = tags[kCVImageBufferTransferFunctionKey as String] as? String
        let primaries = tags[kCVImageBufferColorPrimariesKey as String] as? String
        let rec601 = kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String
        let rec709 = kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
        let sdrTransfers = [kCVImageBufferTransferFunction_ITU_R_709_2 as String,
                            kCVImageBufferTransferFunction_sRGB as String]
        let sdrPrimaries = [kCVImageBufferColorPrimaries_ITU_R_709_2 as String,
                            kCVImageBufferColorPrimaries_EBU_3213 as String, kCVImageBufferColorPrimaries_SMPTE_C as String]
        // Use VLC's preexisting BGRA conversion when the source calls for
        // full range, tone mapping, or a matrix outside the SDR shader path.
        if tags[kCMFormatDescriptionExtension_FullRangeVideo as String] as? Bool == true ||
            sourceMatrix.map({ ![rec601, rec709].contains($0) }) == true ||
            transfer.map({ !sdrTransfers.contains($0) }) == true ||
            primaries.map({ !sdrPrimaries.contains($0) }) == true {
            self = .packedRGB
        } else {
            let size = CMVideoFormatDescriptionGetDimensions(format)
            self = .ycbcr(sourceMatrix ?? (size.height > 576 ? rec709 : rec601))
        }
    }
}

enum PlaybackPhase: Equatable { case idle, opening, playing, paused, ended, failed }
struct PlaybackSnapshot {
    var phase: PlaybackPhase
    var seconds: Double = 0
    var duration: Double = 0
    var seekable = false
    var hasVideo = false
    var error: String?
    var videoOutput: MovieOutput?
    var videoDetails: String?
    var retryVLCWithSmallerFrames = false
    var reopenVLCAtSeek: Double?
    var suggestsCompatibleCopy = false
}

// One transaction owns the latest requested seek. A native stream may report
// seekability, the original :start-time and eventually the requested clock in
// different callbacks. Keep the target until an actual clock confirms it.
struct SeekFeedbackGate {
    enum Action: Equatable { case none, issue(Double), reopen(Double), reportFailure(Double) }
    private(set) var target: Double?
    private var issued = false
    private var mayReopen = true
    private var observedSeconds = 0.0
    private var previous: TimeInterval?
    private var firstMatch: (host: TimeInterval, raw: Double)?

    mutating func begin(target: Double, now: TimeInterval, verifyingReopen: Bool = false) {
        self.target = target
        issued = verifyingReopen
        mayReopen = !verifyingReopen
        observedSeconds = 0
        previous = now
        firstMatch = nil
    }

    mutating func update(raw: Double, duration: Double, seekable: Bool, playing: Bool,
                         ended: Bool, foreground: Bool, now: TimeInterval) -> Action {
        guard var target else { return .none }
        guard foreground else { previous = nil; return .none }
        if let previous, now > previous {
            // Busy foreground callbacks still consume the budget. A suspended
            // process cannot contribute an entire unobserved background interval.
            observedSeconds += min(2, now - previous)
        }
        previous = now
        if duration > 0, duration.isFinite {
            target = min(target, max(0, duration - 0.1))
            self.target = target
        }
        if issued, duration > 0, raw >= target - 0.65, raw <= target + (playing ? observedSeconds : 0) + 0.65 {
            // A time event can briefly claim the target before a queued older
            // seek wins. Confirm two observations, with clock motion during play.
            if let firstMatch, now - firstMatch.host >= 0.15, !playing || raw > firstMatch.raw {
                clear()
                return .none
            }
            if firstMatch == nil { firstMatch = (now, raw) }
        } else {
            firstMatch = nil
        }
        if !issued, seekable, duration > 0, !ended {
            issued = true
            observedSeconds = 0
            return .issue(target)
        }
        if observedSeconds >= (mayReopen ? 6 : 10) || (ended && duration > 0 && target < duration - 0.65) {
            let action: Action = mayReopen ? .reopen(target) : .reportFailure(target)
            clear()
            return action
        }
        if ended && duration > 0 { clear() }
        return .none
    }

    mutating func clear() { self = SeekFeedbackGate() }
}

// UIKit/VLC details are isolated; state/position/lifecycle tests use a fake engine.
protocol LocalPlaybackEngine: AnyObject {
    var onUpdate: ((PlaybackSnapshot) -> Void)? { get set }
    func attach(to view: UIView)
    func load(fileURL: URL) throws
    func play()
    func pause()
    func seek(to seconds: Double)
    func stop()
}

protocol SwitchableVideoEngine: LocalPlaybackEngine {
    func load(fileURL: URL, startAt seconds: Double, paused: Bool) throws
    func play(waitForPausedFrame: Bool)
}

// A VLC byte callback runs off-main and can report failure just before native
// EOF/state notifications arrive. Keep the first real error per opened input.
private final class PickedFileReadStatus {
    private let lock = NSLock()
    private var firstError: String?

    var message: String? { lock.withLock { firstError } }

    func record(_ error: Error, at offset: UInt64) -> Bool {
        lock.withLock {
            guard firstError == nil else { return false }
            let cause = error as NSError
            let reason: String
            switch (cause.domain, cause.code) {
            case (NSCocoaErrorDomain, CocoaError.Code.fileReadCorruptFile.rawValue):
                reason = "视频数据不完整。请确认文件已传输或下载完成，再重新打开。"
            case (NSCocoaErrorDomain, CocoaError.Code.fileReadNoPermission.rawValue),
                 (NSPOSIXErrorDomain, Int(EACCES)), (NSPOSIXErrorDomain, Int(EPERM)):
                reason = "没有读取权限。请从「打开文件」重新选择视频。"
            case (NSCocoaErrorDomain, CocoaError.Code.fileReadNoSuchFile.rawValue),
                 (NSCocoaErrorDomain, CocoaError.Code.fileNoSuchFile.rawValue),
                 (NSPOSIXErrorDomain, Int(ENOENT)), (NSPOSIXErrorDomain, Int(ENODEV)),
                 (NSPOSIXErrorDomain, Int(ENXIO)):
                reason = "文件或存储设备已不可用。请在「文件」中确认可以访问后重新打开。"
            case (NSURLErrorDomain, _), ("NSFileProviderErrorDomain", _):
                reason = "文件提供方暂时无法提供数据。请在「文件」中确认影片可以下载和打开。"
            default:
                reason = "读取视频失败。请在「文件」中检查原文件能否打开。"
            }
            firstError = "\(reason)\n\(cause.domain) \(cause.code) · 读取位置 \(offset) 字节"
            return true
        }
    }
}

// VLC's first displayed picture can remain on screen long after its audio clock
// has moved on. Warn only after sustained wall time AND continuous media time.
struct VLCFrameProgress {
    private var anchor: (frames: UInt64, media: Double, host: TimeInterval)?
    private var lastMedia: Double?

    mutating func reset() {
        anchor = nil
        lastMedia = nil
    }

    mutating func stalled(frames: UInt64, media: Double, host: TimeInterval, playing: Bool) -> Bool {
        guard playing, media.isFinite, host.isFinite else { reset(); return false }
        let previous = lastMedia
        lastMedia = media
        guard let anchor, frames == anchor.frames, host >= anchor.host, let previous,
              (0...2).contains(media - previous) else {
            self.anchor = (frames, media, host)
            return false
        }
        return media - anchor.media >= 12 && host - anchor.host >= 12
    }
}

// VLC can decode every submitted picture without reporting losses even when
// real presentation throughput is far below the source rate. Measure images
// delivered to the App against both the foreground and movie clocks.
struct VLCImmersiveFrameRateWatch {
    private struct Sample {
        let host: TimeInterval
        let media: Double
        let offered: UInt64
        let delivered: UInt64
        let bufferMisses: UInt64
        let staleSource: UInt64
        let formatSetups: UInt64
    }

    private var previous: Sample?
    private var window: Sample?
    private var previousSlowRate: Double?
    private var previousSlowInput = false
    private(set) var needsSmallerOutput = false
    private(set) var deliveredFPS: Double?
    private(set) var slowRate: Double?

    mutating func reset() { self = Self() }

    mutating func sample(host: TimeInterval, media: Double, offered: UInt64, delivered: UInt64,
                         bufferMisses: UInt64, staleSource: UInt64, formatSetups: UInt64, nominalFPS: Double, active: Bool) {
        guard active, nominalFPS.isFinite, nominalFPS >= 23, host.isFinite, media.isFinite,
              delivered > 0, formatSetups > 0 else { reset(); return }
        let current = Sample(host: host, media: media, offered: offered, delivered: delivered,
                             bufferMisses: bufferMisses, staleSource: staleSource, formatSetups: formatSetups)
        defer { previous = current }
        guard let previous, let window, host > previous.host, host - previous.host <= 3.5,
              media >= previous.media, media - previous.media <= host - previous.host + 1.25,
              offered >= previous.offered, delivered >= previous.delivered, formatSetups == previous.formatSetups else {
            reset()
            self.window = current
            return
        }

        // Two separate five-second windows must both advance at approximately
        // playback speed after the first actual picture. A completely frozen
        // vout may report neither new pictures nor native losses.
        let time = host - window.host
        guard time >= 5 else { return }
        self.window = current
        let mediaTime = media - window.media
        let fps = Double(delivered - window.delivered) / time
        deliveredFPS = mediaTime >= 0.8 * time && mediaTime <= time + 1.25 ? fps : nil
        // Judge against the lower of the source cadence and a 30 fps viewing
        // target. Include 24000/1001 film and avoid downgrading healthy 24 fps.
        let slowThreshold = min(nominalFPS, 30) / 2
        guard deliveredFPS != nil, fps < slowThreshold else {
            previousSlowRate = nil
            previousSlowInput = false
            needsSmallerOutput = false
            slowRate = nil
            return
        }
        // Reduce the output only if VLC also offered few pictures in both
        // windows. A busy main thread or exhausted surface pool can instead
        // make delivery slow while decoding and conversion are healthy.
        let inputFPS = Double(offered - window.offered) / time
        let slowInput = inputFPS < slowThreshold &&
            bufferMisses == window.bufferMisses && staleSource == window.staleSource
        needsSmallerOutput = previousSlowInput && slowInput
        previousSlowInput = slowInput
        slowRate = previousSlowRate.map { ($0 + fps) / 2 }
        previousSlowRate = fps
    }
}

final class VLCPlaybackEngine: NSObject, SwitchableVideoEngine, VLCMediaPlayerDelegate {
    weak var diagnostics: PlaybackDiagnostics?
    private var lastStatsTime = -Double.infinity
    private var frameProgress = VLCFrameProgress()
    private var frameLossWatch = VLCFrameLossWatch()
    private var deliveryRate = VLCImmersiveFrameRateWatch()
    var monitorsImmersiveFrameRate = false {
        didSet { if !monitorsImmersiveFrameRate { deliveryRate.reset() } }
    }
    private var lossTimer: DispatchSourceTimer?
    private var minimumLoss = VLCFrameLossWatch.Pattern.none
    private let reducedFrameOutput: Bool
    let decoderPolicy: VLCDecoderPolicy
    static let reducedLongEdge: UInt32 = 1280
    private var checkExistingPanoramaFormat = false
    var preferSmallerPanoramaFrames: Bool {
        get { frameDelivery?.preferSmallerPanoramaFrames ?? false }
        set {
            guard newValue != preferSmallerPanoramaFrames else { return }
            checkExistingPanoramaFormat = newValue
            frameDelivery?.preferSmallerPanoramaFrames = newValue
        }
    }

    // Limit a corrective reopen to a transition on an already running vmem
    // session. A fresh player negotiates the desired format before its first frame.
    func needsPanoramaRenegotiation() -> Bool {
        guard checkExistingPanoramaFormat, let stats = frameDelivery?.frameStats, stats.formatSetups > 0 else { return false }
        if stats.outputLongEdge <= stats.panoramaLimit {
            checkExistingPanoramaFormat = false
            return false
        }
        guard let player, player.isSeekable,
              player.state == .playing || player.state == .paused,
              callbackLock.withLock({ seekGate.target == nil }) else { return false }
        let clock = playbackSeconds(player)
        return durationSeconds(player) - clock > 2
    }
    private var videoDetails: String?
    private var nominalFrameRate = 0.0
    private var continuousPlaybackRequested = false
    private var nextTrackCheck = -Double.infinity
    var onUpdate: ((PlaybackSnapshot) -> Void)?
    private static var lifetimeAssociationKey: UInt8 = 0
    private let playerResource: BackgroundPlaybackResource<VLCMediaPlayer>
    private weak var nativeLifetime: BackgroundPlaybackResource<NICEVLCNativeReference>?
    private var player: VLCMediaPlayer? { playerResource.resource }
    private let frameDelivery: NICEVLCFrameDelivery?
    private let pickedFile: PickedVideoFile?
    private var pickedReadStatus: PickedFileReadStatus?
    private var stopped = false
    private(set) var loaded = false
    private var pausedPreviewDeadline: TimeInterval?
    private var needsPausedFrame = false

    // VLC may fire timeChanged very frequently around a seek. Enqueuing every
    // callback onto the main queue can visibly stall SwiftUI and make the slider
    // bounce. Coalesce time callbacks to at most one publish every 80 ms while
    // state changes still publish immediately.
    private let callbackLock = NSLock()
    private var timePublishScheduled = false
    private var seekGate = SeekFeedbackGate()
    private var seekFailureUntil: TimeInterval = -.infinity

    override convenience init() { self.init(frameHandler: nil) }

    init(frameHandler: ((CVPixelBuffer) -> Void)?, pickedFile: PickedVideoFile? = nil,
         reducedFrameOutput: Bool = false, preferSmallerPanoramaFrames: Bool = false,
         decoderPolicy: VLCDecoderPolicy = .automatic, frameColor: VLCFrameColor? = nil) {
        self.pickedFile = pickedFile
        self.reducedFrameOutput = reducedFrameOutput
        let panoramaOutput = frameHandler != nil && preferSmallerPanoramaFrames
        self.decoderPolicy = panoramaOutput ? decoderPolicy : .automatic
        var options = ["--no-video-title-show", "--no-metadata-network-access"]
        if panoramaOutput && decoderPolicy == .software {
            // MobileVLCKit 3.7.3 registers a stand-alone VideoToolbox decoder.
            // Disabling only avcodec hardware acceleration leaves that decoder eligible.
            options.append(contentsOf: ["--no-videotoolbox", "--avcodec-hw=none"])
        }
        if panoramaOutput {
            // VLC 3 drops a picture already half a frame late before vmem can
            // offer it. At 59.94 fps that leaves about 8 ms. Keep the decoded
            // panorama available for presentation, with at most one pending
            // picture in our renderer. Leave VLC's original audio clock intact.
            options.append("--no-drop-late-frames")
            // In VLC 3, mode 0 is fast bilinear. Panorama already samples a
            // bounded surface; spend the conversion budget on fresh frames.
            options.append("--swscale-mode=0")
            // The avcodec hurry-up path can discard a *compressed* reference
            // block after 11 late frames, producing a cascade of missing POCs.
            // Preserve the reference chain; the decoder's 5 s late-block
            // safety and the regular playback clock remain enabled.
            options.append("--no-avcodec-hurry-up")
            if reducedFrameOutput {
                // This is already a quality-recovery input. FFmpeg may omit
                // non-reference pictures without breaking later HEVC pictures.
                options.append("--avcodec-skip-frame=1")
            }
        }
        let construction = NICEVLCPlayerConstruction(options: options, frameHandler: frameHandler)
        frameDelivery = construction?.frameDelivery
        if let frameColor { construction?.frameDelivery?.panoramaYCbCrMatrix = frameColor.matrix }
        construction?.frameDelivery?.preferSmallerPanoramaFrames = preferSmallerPanoramaFrames
        if reducedFrameOutput { construction?.frameDelivery?.maximumLongEdge = Self.reducedLongEdge }
        playerResource = BackgroundPlaybackResource(construction?.player)
        super.init()
        if let construction {
            let lifetime = BackgroundPlaybackResource(construction.nativeReference)
            // Associated objects are disposed after VLCMediaPlayer's dealloc
            // releases its C reference. Its extra native reference therefore
            // survives even a late main-queue callback owning the ObjC player.
            objc_setAssociatedObject(construction.player, &Self.lifetimeAssociationKey,
                                     lifetime, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            nativeLifetime = lifetime
        }
        player?.delegate = self
        if frameHandler != nil {
            NotificationCenter.default.addObserver(self, selector: #selector(discardFrameRateEvidence),
                name: UIApplication.willResignActiveNotification, object: nil)
        }
    }

    @objc private func discardFrameRateEvidence() { deliveryRate.reset() }

    func attach(to view: UIView) {
        guard !stopped, frameDelivery == nil, let player else { return }
        nativeLifetime?.keepAlive(view)
        player.drawable = view
    }
    func load(fileURL: URL) throws {
        try load(fileURL: fileURL, startAt: 0, paused: false)
    }
    func load(fileURL: URL, startAt seconds: Double, paused: Bool) throws {
        guard !stopped else { throw ClientError("播放器已关闭，请重新打开视频。") }
        guard let player else { throw ClientError("播放器初始化失败，请关闭后重新打开视频。") }
        if preferSmallerPanoramaFrames { nativeLifetime?.resource?.observeVideoDecoderForNewInput() }
        frameProgress.reset()
        frameLossWatch.reset()
        deliveryRate.reset()
        callbackLock.withLock { seekGate.clear() }
        seekFailureUntil = -.infinity
        minimumLoss = .none
        stopLossTimer()
        lastStatsTime = -.infinity
        videoDetails = nil
        nominalFrameRate = 0
        continuousPlaybackRequested = false
        nextTrackCheck = -.infinity
        var options: [String] = []
        if seconds.isFinite && seconds > 0 { options.append(":start-time=\(seconds)") }
        if paused { options.append(":start-paused") }
        if let pickedFile {
            guard fileURL == pickedFile.url, let native = nativeLifetime?.resource else {
                throw ClientError("无法打开所选文件，请重新选择视频。")
            }
            let status = PickedFileReadStatus()
            pickedReadStatus = status
            let opened = native.loadFile(byteCount: pickedFile.byteCount, options: options) { [weak self] buffer, count, offset in
                do {
                    return try pickedFile.read(into: buffer, count: count, at: offset)
                } catch {
                    // imem can translate a failed read into EOF. Save the cause
                    // before returning to VLC, including for already queued events.
                    if status.record(error, at: offset) {
                        DispatchQueue.main.async { [weak self] in self?.fileReadDidFail(status) }
                    }
                    return -1
                }
            }
            guard opened else { throw ClientError("无法打开所选文件，请重新选择视频。") }
        } else {
            try OfflineMediaPolicy.validateLocalFile(fileURL)
            let media = VLCMedia(path: fileURL.path)
            for option in options { media.addOption(option) }
            frameDelivery?.sourceMedia = media
            player.media = media
        }
        pausedPreviewDeadline = nil
        loaded = true
    }
    private func fileReadDidFail(_ status: PickedFileReadStatus) {
        guard !stopped, pickedReadStatus === status else { return }
        player?.stop()
        publishNow()
    }

    // The VLCKit delegate can publish a cached time from before a paused seek.
    // Read the same native input clock during confirmation and after resuming.
    private func playbackSeconds(_ player: VLCMediaPlayer) -> Double {
        if let milliseconds = nativeLifetime?.resource?.timeMilliseconds, milliseconds >= 0 {
            return Double(milliseconds) / 1000
        }
        return max(0, Double(player.time.intValue) / 1000)
    }

    private func durationSeconds(_ player: VLCMediaPlayer) -> Double {
        if pickedFile != nil {
            return max(0, Double(nativeLifetime?.resource?.lengthMilliseconds ?? 0) / 1000)
        }
        return max(0, Double(player.media?.length.intValue ?? 0) / 1000)
    }

    func play() { play(waitForPausedFrame: false) }
    func play(waitForPausedFrame: Bool) {
        guard loaded && !stopped else { return }
        continuousPlaybackRequested = !waitForPausedFrame
        needsPausedFrame = waitForPausedFrame
        pausedPreviewDeadline = waitForPausedFrame ? ProcessInfo.processInfo.systemUptime + 10 : nil
        player?.play()
        if !waitForPausedFrame { startLossTimer() }
        if waitForPausedFrame { scheduleTimePublish(after: 0.1) }
    }
    // VLCKit clock callbacks can be delayed or repeated while a stressed vout
    // drops frames. Probe only the memory-frame path and only between playback
    // and pause/stop. Ordinary native playback keeps its event-driven updates.
    private func startLossTimer() {
        guard frameDelivery != nil, lossTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, ProcessInfo.processInfo.systemUptime - self.lastStatsTime >= 1 else { return }
            self.publishNow()
        }
        lossTimer = timer
        timer.resume()
    }

    private func stopLossTimer() {
        lossTimer?.cancel()
        lossTimer = nil
    }

    func pause() {
        continuousPlaybackRequested = false
        stopLossTimer()
        frameProgress.reset()
        frameLossWatch.reset()
        deliveryRate.reset()
        minimumLoss = .none
        if loaded && !stopped { player?.pause() }
    }
    func seek(to seconds: Double) {
        guard !stopped, let player else { return }
        guard seconds.isFinite else { return }
        let duration = durationSeconds(player)
        let target = PlaybackPosition.clamp(seconds, duration: duration) ?? max(0, seconds)
        startSeek(target, verifyingReopen: false)
    }

    func verifyReopenedSeek(at seconds: Double) {
        // This new media was opened with :start-time. Verify it without sending
        // a competing seek or recursively reopening a persistently bad input.
        startSeek(seconds, verifyingReopen: true)
    }

    private func startSeek(_ seconds: Double, verifyingReopen: Bool) {
        frameProgress.reset()
        frameLossWatch.reset()
        deliveryRate.reset()
        minimumLoss = .none
        seekFailureUntil = -.infinity
        callbackLock.withLock {
            seekGate.begin(target: seconds, now: ProcessInfo.processInfo.systemUptime, verifyingReopen: verifyingReopen)
        }
        scheduleTimePublish(after: 0.04)
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        stopLossTimer()
        frameDelivery?.invalidate()
        player?.delegate = nil
        onUpdate = nil
        callbackLock.lock()
        seekGate.clear()
        timePublishScheduled = false
        callbackLock.unlock()
        // Pinned VLCKit 3.7.3 stop() submits stop_async; keep that request before
        // returning to the store's existing session/deletion-lease transition.
        // The expensive final C release runs only in the retirement queue.
        if loaded { player?.stop() }
        loaded = false
        playerResource.retire()
        nativeLifetime = nil
    }
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.publishNow() }
    }
    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        scheduleTimePublish(after: 0.08)
    }

    private func scheduleTimePublish(after delay: TimeInterval) {
        callbackLock.lock()
        guard !timePublishScheduled, !stopped else {
            callbackLock.unlock()
            return
        }
        timePublishScheduled = true
        callbackLock.unlock()

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.callbackLock.lock()
            self.timePublishScheduled = false
            self.callbackLock.unlock()
            self.publishNow()
        }
    }

    private func publishNow() {
        guard !stopped, let snapshot = makeSnapshot() else { return }
        if snapshot.phase == .ended || snapshot.phase == .failed { stopLossTimer() }
        if let deadline = pausedPreviewDeadline {
            // Paused inputs do not emit clock ticks. VLCKit 3.x does not
            // forward vout/seekable readiness as a delegate callback either.
            if snapshot.phase == .failed || snapshot.phase == .ended || ProcessInfo.processInfo.systemUptime >= deadline {
                pausedPreviewDeadline = nil
            } else if needsPausedFrame, player?.hasVideoOut == true, player?.isSeekable == true {
                needsPausedFrame = false
                if frameDelivery?.hasDeliveredFrame != true { player?.gotoNextFrame() }
                scheduleTimePublish(after: 0.1)
            } else if snapshot.hasVideo && snapshot.seekable && snapshot.duration > 0 {
                pausedPreviewDeadline = nil
            } else {
                scheduleTimePublish(after: 0.1)
            }
        }
        // No borrowed native player reference is held while clients receive an
        // update: a client may close or switch the player from this callback.
        onUpdate?(snapshot)
    }

    private func makeSnapshot() -> PlaybackSnapshot? {
        guard !stopped, let player else { return nil }
        if let message = pickedReadStatus?.message {
            return PlaybackSnapshot(phase: .failed, error: message)
        }
        let phase: PlaybackPhase
        let nativeState = player.state
        switch nativeState {
        case .playing: phase = .playing
        case .paused: phase = .paused
        case .ended: phase = .ended
        case .error: phase = .failed
        case .stopped: phase = .idle
        default: phase = player.isPlaying ? .playing : .opening
        }

        let rawSeconds = playbackSeconds(player)
        let now = ProcessInfo.processInfo.systemUptime
        let duration = durationSeconds(player)
        let appState = MainActor.assumeIsolated { UIApplication.shared.applicationState }
        let isSeekable = player.isSeekable
        let (seekAction, waitingFor) = callbackLock.withLock {
            if phase == .failed { seekGate.clear() }
            let action = seekGate.update(raw: rawSeconds, duration: duration, seekable: isSeekable,
                                         playing: phase == .playing, ended: phase == .ended,
                                         foreground: appState != .background, now: now)
            return (action, seekGate.target)
        }
        var reopenAt: Double?
        switch seekAction {
        case .issue(let target):
            // The input's :start-time and this command both use VLC's timestamp
            // control. VLCKit's fractional setter uses a separate control.
            nativeLifetime?.resource?.seek(milliseconds: Int64((target * 1000).rounded()))
            diagnostics?.event("VLC: issuing seek target=\(target)s")
        case .reopen(let target):
            reopenAt = target
        case .reportFailure(let target):
            diagnostics?.event("VLC: reopen did not reach seek target=\(target)s; clock=\(rawSeconds)s")
            seekFailureUntil = now + 6
        case .none: break
        }
        let awaitingSeek = waitingFor != nil
        // Even a paused/buffering input without timeChanged callbacks must settle.
        if awaitingSeek { scheduleTimePublish(after: 0.25) }
        let displayedSeconds = waitingFor ?? reopenAt ?? rawSeconds

        if videoDetails == nil, phase == .playing || phase == .paused, now >= nextTrackCheck {
            nextTrackCheck = now + 2
            videoDetails = nativeLifetime?.resource?.videoTrackDescription(frameRate: &nominalFrameRate)
        }
        let stats = frameDelivery?.frameStats
        // VLCKit may still report buffering while isPlaying and the clock both
        // advance. The displayed phase and the loss monitor must agree. A
        // foreground-inactive transition alone cannot provide loss evidence.
        let gate = VLCFrameLossWatch.Gate(requested: continuousPlaybackRequested, preview: pausedPreviewDeadline != nil,
                                          seeking: awaitingSeek, playing: phase == .playing, background: appState == .background)
        let activelyPlaying = gate == .open
        // Keep the reason in a copyable report even if no output arrives.
        let recoveryState = VLCFrameLossWatch.State(
            active: activelyPlaying, seekable: player.isSeekable, remaining: duration - rawSeconds,
            outputEdge: stats?.outputLongEdge ?? 0, reducedLimit: Self.reducedLongEdge, alreadyReduced: reducedFrameOutput)
        let canReduce = recoveryState == .monitoring
        let endingMinimum = reducedFrameOutput && phase == .ended && continuousPlaybackRequested &&
            !awaitingSeek && pausedPreviewDeadline == nil && appState != .background
        // A final clock/counter sample can arrive with the terminal event. A
        // reset-to-zero EOF clock must not erase an already confirmed warning.
        let sampleEnd = endingMinimum && duration > 0 && rawSeconds >= duration - 2 &&
            frameLossWatch.observedMediaSeconds > 0 && now > lastStatsTime
        let monitorLoss = canReduce || recoveryState == .minimum || sampleEnd
        if !monitorLoss && !endingMinimum {
            frameLossWatch.reset()
            minimumLoss = .none
        }
        var retryWithSmallerFrames = false
        let rateEligible = monitorsImmersiveFrameRate && appState == .active && activelyPlaying
        let preserveRateAtEnd = monitorsImmersiveFrameRate && appState == .active && phase == .ended &&
            continuousPlaybackRequested && !awaitingSeek && pausedPreviewDeadline == nil
        if !rateEligible && !preserveRateAtEnd { deliveryRate.reset() }
        if (now - lastStatsTime >= 1 || sampleEnd) && (monitorLoss || rateEligible || diagnostics != nil) {
            lastStatsTime = now
            if !preserveRateAtEnd, let stats {
                deliveryRate.sample(host: now, media: rawSeconds, offered: stats.offered, delivered: stats.delivered,
                                    bufferMisses: stats.bufferMisses, staleSource: stats.staleSource,
                                    formatSetups: stats.formatSetups, nominalFPS: nominalFrameRate, active: rateEligible)
            }
            retryWithSmallerFrames = canReduce && deliveryRate.needsSmallerOutput
            let native = nativeLifetime?.resource?.videoStatistics
            if monitorLoss, let stats, let native {
                let stalled = frameLossWatch.needsSmallerOutput(.init(
                    clock: rawSeconds, host: now, decoded: native.decoded, displayed: native.displayed,
                    lost: native.lost, offered: stats.offered, delivered: stats.delivered,
                    bufferMisses: stats.bufferMisses, staleSource: stats.staleSource, formatSetups: stats.formatSetups),
                    nominalFrameRate: preferSmallerPanoramaFrames ? nominalFrameRate : 0)
                retryWithSmallerFrames = retryWithSmallerFrames || (canReduce && stalled)
                // A repeated native timestamp can defer a reopen. Keep a confirmed
                // warning stable until new samples clear the underlying pattern.
                if reducedFrameOutput && (!sampleEnd || frameLossWatch.pattern != .none) {
                    minimumLoss = frameLossWatch.pattern
                }
            }
            if let diagnostics {
                var status = "stats=unavailable"
                if let native, native.decoded >= 0 {
                    status = "decoded=\(native.decoded) displayed=\(native.displayed) lost=\(native.lost)"
                }
                status += " decoderPolicy=\(decoderPolicy.rawValue)"
                if preferSmallerPanoramaFrames {
                    let module = nativeLifetime?.resource?.observedVideoDecoder ?? "unreported"
                    status += " observedVideoDecoder=\(module)"
                }
                if let fps = deliveryRate.deliveredFPS {
                    status += String(format: " deliveredFPS=%.1f", fps)
                }
                if let fps = deliveryRate.slowRate {
                    status += String(format: " slowDeliveredFPS=%.1f", fps)
                }
                if let stats {
                    status += " offered=\(stats.offered) delivered=\(stats.delivered) coalesced=\(stats.coalesced) bufferMisses=\(stats.bufferMisses)"
                    status += " formatSetups=\(stats.formatSetups) staleSource=\(stats.staleSource)"
                    status += " vmemCap=\(stats.negotiatedLimit) recovery=\(minimumLoss != .none ? "minimum-stalled" : recoveryState.rawValue)"
                    status += " gate=\(gate.rawValue) vlcState=\(nativeState.rawValue) appState=\(appState.rawValue)"
                    status += " lossPattern=\(frameLossWatch.pattern.rawValue) watchMediaSec=\(Int(frameLossWatch.observedMediaSeconds))"
                }
                MainActor.assumeIsolated { diagnostics.vlcStatus(status) }
            }
        }
        var warning: String?
        if minimumLoss != .none {
            let symptom = minimumLoss == .frozen ? "播放时间前进时，画面输出停住并持续丢帧。" : "播放时间前进时，出帧过慢并持续丢帧。"
            warning = "VLC 已降至 1280 像素。" + symptom + "可打开已有的兼容副本，或返回「VR → 制作兼容副本」。"
        } else if let fps = deliveryRate.slowRate {
            warning = String(format: "全景画面持续出帧缓慢，近期每秒约 %.1f 帧，片源为 %.1f fps。可打开兼容副本，或返回「VR → 制作兼容副本」。", fps, nominalFrameRate)
        } else if let stats, frameProgress.stalled(frames: stats.delivered, media: rawSeconds, host: now,
                playing: activelyPlaying) {
            warning = "播放时间在前进，VLC 已有 12 秒没有送出新画面。请复制播放诊断，或退出 VR 对比普通播放。"
        }
        if now < seekFailureUntil { warning = "VLC 未能跳到指定位置，进度条已恢复为实际播放时间。" }
        return PlaybackSnapshot(
            phase: phase,
            seconds: displayedSeconds,
            duration: duration,
            seekable: player.isSeekable,
            hasVideo: frameDelivery?.hasDeliveredFrame ?? player.hasVideoOut,
            error: phase == .failed ? "VLC 无法解码这个本地文件。请检查文件是否损坏、编码是否受支持，必要时重新下载。" : warning,
            videoDetails: videoDetails,
            retryVLCWithSmallerFrames: retryWithSmallerFrames,
            reopenVLCAtSeek: reopenAt,
            suggestsCompatibleCopy: (minimumLoss != .none || deliveryRate.slowRate != nil) && phase != .failed
        )
    }
    deinit { stop() }
}
