import Foundation
import UIKit
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

final class VLCPlaybackEngine: NSObject, LocalPlaybackEngine, VLCMediaPlayerDelegate {
    var onUpdate: ((PlaybackSnapshot) -> Void)?
    private static var lifetimeAssociationKey: UInt8 = 0
    private let playerResource: BackgroundPlaybackResource<VLCMediaPlayer>
    private weak var nativeLifetime: BackgroundPlaybackResource<NSObject>?
    private var player: VLCMediaPlayer? { playerResource.resource }
    private var stopped = false
    private var loaded = false

    // VLC may fire timeChanged very frequently around a seek. Enqueuing every
    // callback onto the main queue can visibly stall SwiftUI and make the slider
    // bounce. Coalesce time callbacks to at most one publish every 80 ms while
    // state changes still publish immediately.
    private let callbackLock = NSLock()
    private var timePublishScheduled = false
    private var seekGate = SeekFeedbackGate()

    override init() {
        let construction = NICEVLCPlayerConstruction(options: ["--no-video-title-show", "--no-metadata-network-access"])
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
        guard !stopped, let player else { return }
        nativeLifetime?.keepAlive(view)
        player.drawable = view
    }
    func load(fileURL: URL) throws {
        guard !stopped else { throw ClientError("播放器已关闭，请重新打开视频。") }
        guard let player else { throw ClientError("播放器初始化失败，请关闭后重新打开视频。") }
        // Check again immediately before giving VLC a file, even for non-store callers.
        try OfflineMediaPolicy.validateLocalFile(fileURL)
        player.media = VLCMedia(path: fileURL.path)
        loaded = true
    }
    func play() { if loaded && !stopped { player?.play() } }
    func pause() { if loaded && !stopped { player?.pause() } }
    func seek(to seconds: Double) {
        guard !stopped, let player else { return }
        let duration = Double(player.media?.length.intValue ?? 0) / 1000
        guard player.isSeekable,
              let seconds = PlaybackPosition.clamp(seconds, duration: duration) else { return }

        // Do not issue a decoder seek for a sub-frame-sized correction.
        let current = max(0, Double(player.time.intValue) / 1000)
        guard abs(current - seconds) >= 0.20 else { return }

        callbackLock.lock()
        seekGate.begin(target: seconds, now: ProcessInfo.processInfo.systemUptime)
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
        // No borrowed native player reference is held while clients receive an
        // update: a client may close or switch the player from this callback.
        onUpdate?(snapshot)
    }

    private func makeSnapshot() -> PlaybackSnapshot? {
        guard !stopped, let player else { return nil }
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
        callbackLock.unlock()

        return PlaybackSnapshot(
            phase: phase,
            seconds: displayedSeconds,
            duration: max(0, Double(player.media?.length.intValue ?? 0) / 1000),
            seekable: player.isSeekable,
            hasVideo: player.hasVideoOut,
            error: phase == .failed ? "VLC 无法解码这个本地文件。请检查文件是否损坏、编码是否受支持，必要时重新下载。" : nil
        )
    }
    deinit { stop() }
}
