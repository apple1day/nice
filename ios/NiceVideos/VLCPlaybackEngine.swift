import Foundation
import UIKit
import CoreVideo
import MobileVLCKit
import ObjectiveC

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
}

// Keeps the UI pinned to the user's requested position while VLC is still
// reporting stale pre-seek timestamps. Once VLC reaches the target neighborhood
// (or the short protection window expires), normal time updates resume.
struct SeekFeedbackGate {
    private(set) var target: Double?
    private(set) var deadline: TimeInterval = 0

    mutating func begin(target: Double, now: TimeInterval, timeout: TimeInterval = 1.25) {
        self.target = target
        deadline = now + timeout
    }

    mutating func displayedSeconds(raw: Double, now: TimeInterval, tolerance: Double = 1.0) -> Double {
        guard let target else { return raw }
        if abs(raw - target) <= tolerance || now >= deadline {
            self.target = nil
            return raw
        }
        return target
    }

    mutating func clear() {
        target = nil
        deadline = 0
    }
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

final class VLCPlaybackEngine: NSObject, SwitchableVideoEngine, VLCMediaPlayerDelegate {
    weak var diagnostics: PlaybackDiagnostics?
    private var lastStatsTime = -Double.infinity
    private var frameProgress = VLCFrameProgress()
    private var frameLossWatch = VLCFrameLossWatch()
    private var lossTimer: DispatchSourceTimer?
    private var stalledAtMinimum = false
    private let reducedFrameOutput: Bool
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
              callbackLock.withLock({ seekGate.target == nil && unconfirmedSeek == nil }) else { return false }
        let clock = max(0, Double(player.time.intValue) / 1000)
        return durationSeconds(player) - clock > 2
    }
    private var videoDetails: String?
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
    // The UI's feedback timeout can elapse before a slow native seek lands.
    // Do not replace its decoder for a quality adjustment during that gap.
    private var unconfirmedSeek: (target: Double, host: TimeInterval)?

    override convenience init() { self.init(frameHandler: nil) }

    init(frameHandler: ((CVPixelBuffer) -> Void)?, pickedFile: PickedVideoFile? = nil,
         reducedFrameOutput: Bool = false, preferSmallerPanoramaFrames: Bool = false) {
        self.pickedFile = pickedFile
        self.reducedFrameOutput = reducedFrameOutput
        let construction = NICEVLCPlayerConstruction(options: ["--no-video-title-show", "--no-metadata-network-access"],
                                                     frameHandler: frameHandler)
        frameDelivery = construction?.frameDelivery
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
    }
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
        frameProgress.reset()
        frameLossWatch.reset()
        callbackLock.withLock { unconfirmedSeek = nil }
        stalledAtMinimum = false
        stopLossTimer()
        lastStatsTime = -.infinity
        videoDetails = nil
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

    private func durationSeconds(_ player: VLCMediaPlayer) -> Double {
        if pickedFile != nil {
            return max(0, Double(nativeLifetime?.resource?.lengthMilliseconds ?? 0) / 1000)
        }
        return max(0, Double(player.media?.length.intValue ?? 0) / 1000)
    }

    func play() { play(waitForPausedFrame: false) }
    func play(waitForPausedFrame: Bool) {
        guard loaded && !stopped else { return }
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
        stopLossTimer()
        frameProgress.reset()
        frameLossWatch.reset()
        stalledAtMinimum = false
        if loaded && !stopped { player?.pause() }
    }
    func seek(to seconds: Double) {
        guard !stopped, let player else { return }
        let duration = durationSeconds(player)
        guard player.isSeekable,
              let seconds = PlaybackPosition.clamp(seconds, duration: duration) else { return }

        // Do not issue a decoder seek for a sub-frame-sized correction.
        let current = max(0, Double(player.time.intValue) / 1000)
        guard abs(current - seconds) >= 0.20 else { return }

        frameProgress.reset()
        frameLossWatch.reset()
        stalledAtMinimum = false
        callbackLock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        seekGate.begin(target: seconds, now: now)
        unconfirmedSeek = (seconds, now)
        callbackLock.unlock()

        // Fractional seeking avoids the Int32 millisecond limit for long media.
        // VLCKit 3.x does not expose VLC 4's explicit fast-seek flag, so keep the
        // proven position API and optimize callback pressure/UI stabilization here.
        player.position = Float(seconds / duration)
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
        switch player.state {
        case .playing: phase = .playing
        case .paused: phase = .paused
        case .ended: phase = .ended
        case .error: phase = .failed
        case .stopped: phase = .idle
        default: phase = player.isPlaying ? .playing : .opening
        }

        let rawSeconds = max(0, Double(player.time.intValue) / 1000)
        let now = ProcessInfo.processInfo.systemUptime
        callbackLock.lock()
        let displayedSeconds = seekGate.displayedSeconds(raw: rawSeconds, now: now)
        if let seek = unconfirmedSeek {
            // A busy decoder may publish its first post-seek tick several
            // seconds into the requested interval. Paused seeks should land at
            // the actual requested position.
            let elapsed = phase == .playing ? max(0, now - seek.host) : 0
            if rawSeconds >= seek.target - 1, rawSeconds <= seek.target + elapsed + 1 {
                unconfirmedSeek = nil
            }
        }
        let awaitingSeek = seekGate.target != nil || unconfirmedSeek != nil
        callbackLock.unlock()

        if videoDetails == nil, phase == .playing || phase == .paused, now >= nextTrackCheck {
            nextTrackCheck = now + 2
            videoDetails = nativeLifetime?.resource?.videoTrackDescription
        }
        let stats = frameDelivery?.frameStats
        let duration = durationSeconds(player)
        let activelyPlaying = player.state == .playing && !awaitingSeek && pausedPreviewDeadline == nil &&
            MainActor.assumeIsolated { UIApplication.shared.applicationState == .active }
        // Keep the reason in a copyable report even if no output arrives.
        let recoveryState = VLCFrameLossWatch.State(
            active: activelyPlaying, seekable: player.isSeekable, remaining: duration - rawSeconds,
            outputEdge: stats?.outputLongEdge ?? 0, reducedLimit: Self.reducedLongEdge, alreadyReduced: reducedFrameOutput)
        let canReduce = recoveryState == .monitoring
        let monitorLoss = canReduce || recoveryState == .minimum
        if !monitorLoss {
            frameLossWatch.reset()
            stalledAtMinimum = false
        }
        var retryWithSmallerFrames = false
        if now - lastStatsTime >= 1 && (monitorLoss || diagnostics != nil) {
            lastStatsTime = now
            let native = nativeLifetime?.resource?.videoStatistics
            if monitorLoss, let stats, let native {
                let stalled = frameLossWatch.needsSmallerOutput(.init(
                    clock: rawSeconds, host: now, decoded: native.decoded, displayed: native.displayed,
                    lost: native.lost, offered: stats.offered, delivered: stats.delivered,
                    bufferMisses: stats.bufferMisses, staleSource: stats.staleSource, formatSetups: stats.formatSetups))
                retryWithSmallerFrames = canReduce && stalled
                stalledAtMinimum = reducedFrameOutput && stalled
            }
            if let diagnostics {
                var status = "stats=unavailable"
                if let native, native.decoded >= 0 {
                    status = "decoded=\(native.decoded) displayed=\(native.displayed) lost=\(native.lost)"
                }
                if let stats {
                    status += " offered=\(stats.offered) delivered=\(stats.delivered) coalesced=\(stats.coalesced) bufferMisses=\(stats.bufferMisses)"
                    status += " formatSetups=\(stats.formatSetups) staleSource=\(stats.staleSource)"
                    status += " vmemCap=\(stats.negotiatedLimit) recovery=\(stalledAtMinimum ? "minimum-stalled" : recoveryState.rawValue)"
                    status += " watchMediaSec=\(Int(frameLossWatch.observedMediaSeconds))"
                }
                MainActor.assumeIsolated { diagnostics.vlcStatus(status) }
            }
        }
        var warning: String?
        if stalledAtMinimum {
            warning = "VLC 已把输出降至 1280 像素，但仍在丢帧。可使用较低分辨率或帧率的片源。"
        } else if let stats, frameProgress.stalled(frames: stats.delivered, media: rawSeconds, host: now,
                playing: activelyPlaying) {
            warning = "播放时间在前进，VLC 已有 12 秒没有送出新画面。请复制播放诊断，或退出 VR 对比普通播放。"
        }
        return PlaybackSnapshot(
            phase: phase,
            seconds: displayedSeconds,
            duration: duration,
            seekable: player.isSeekable,
            hasVideo: frameDelivery?.hasDeliveredFrame ?? player.hasVideoOut,
            error: phase == .failed ? "VLC 无法解码这个本地文件。请检查文件是否损坏、编码是否受支持，必要时重新下载。" : warning,
            videoDetails: videoDetails,
            retryVLCWithSmallerFrames: retryWithSmallerFrames
        )
    }
    deinit { stop() }
}
