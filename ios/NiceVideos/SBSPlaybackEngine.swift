import UIKit

/// Both VLC outputs live under the same SwiftUI surface for the lifetime of a clip.
final class SBSPlaybackView: UIView {
    let drawableView = UIView()
    private(set) var renderer: SBSMetalView?
    var onOutputChange: (() -> Void)?
    var mode: SBSDisplayMode = .standard {
        didSet {
            guard mode != oldValue else { return }
            if mode == .standard {
                renderer?.clear()
                renderer?.removeFromSuperview()
                renderer = nil
                drawableView.isHidden = false
            } else {
                let view = renderer ?? SBSMetalView(frame: bounds)
                if renderer == nil {
                    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    addSubview(view)
                    renderer = view
                }
                view.mode = mode
                drawableView.isHidden = true
            }
            if (oldValue == .standard) != (mode == .standard) { onOutputChange?() }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        drawableView.frame = bounds
        drawableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(drawableView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
}

/// VLC selects a native drawable or vmem when it opens a video output. Reopen only
/// when crossing that boundary. Both SBS formats share the same decoder and clock.
final class SBSPlaybackEngine: LocalPlaybackEngine {
    var onUpdate: ((PlaybackSnapshot) -> Void)?
    private var session: VLCPlaybackEngine?
    private var file: URL?
    private var seconds = 0.0
    private var phase: PlaybackPhase = .idle
    private var hasStarted = false
    private var wantsPlayback = false
    private var openingPaused = false
    private var awaitingOutput = false
    private var pendingSeek: Double?
    private var stopped = false

    func attach(to view: UIView) {
        guard !stopped else { return }
        guard let host = view as? SBSPlaybackView else {
            nativeSession().attach(to: view)
            return
        }
        MainActor.assumeIsolated {
            host.onOutputChange = { [weak self, weak host] in
                guard let self, let host else { return }
                self.changeOutput(host)
            }
            if session == nil {
                installOutput(host)
            } else if host.mode == .standard {
                session?.attach(to: host.drawableView)
            } else {
                changeOutput(host)
            }
        }
    }

    private func observe(_ newSession: VLCPlaybackEngine) {
        session = newSession
        newSession.onUpdate = { [weak self] snapshot in
            guard let self, !self.stopped else { return }
            // A stopped event may trail EOF. Only an explicit reload can
            // restart that input, including when changing output at the end.
            if self.phase == .ended || self.phase == .failed { return }
            var visible = snapshot
            if self.openingPaused && snapshot.phase == .paused {
                self.openingPaused = false
                if self.wantsPlayback { self.session?.play() }
            }
            if self.hasStarted && !self.wantsPlayback &&
                (snapshot.phase == .opening || snapshot.phase == .playing) {
                // A pause requested before VLC's input opened may have been
                // ignored; honor it as soon as the decoder reports playing.
                if snapshot.phase == .playing && !self.openingPaused { self.session?.pause() }
                visible.phase = .paused
            }
            if self.awaitingOutput {
                // SwiftUI can deliver a seek while the replacement decoder is
                // opening. Commit the latest request when it becomes seekable.
                if let target = self.pendingSeek {
                    visible.seconds = target
                    if snapshot.seekable && snapshot.duration > 0 {
                        self.pendingSeek = nil
                        self.session?.seek(to: target)
                        self.awaitingOutput = false
                    }
                } else if snapshot.seconds == 0 && self.seconds > 0 {
                    visible.seconds = self.seconds
                } else if snapshot.seekable && snapshot.duration > 0 {
                    self.awaitingOutput = false
                }
            }
            self.seconds = visible.seconds
            self.phase = visible.phase
            self.onUpdate?(visible)
        }
    }

    private func nativeSession() -> VLCPlaybackEngine {
        if let session { return session }
        let newSession = VLCPlaybackEngine()
        observe(newSession)
        return newSession
    }

    @MainActor private func installOutput(_ host: SBSPlaybackView) {
        if let renderer = host.renderer {
            observe(VLCPlaybackEngine(frameHandler: { [weak renderer] frame in
                // The frame-delivery bridge coalesces output onto the main queue.
                MainActor.assumeIsolated { renderer?.display(frame) }
            }))
        } else {
            nativeSession().attach(to: host.drawableView)
        }
    }

    @MainActor private func changeOutput(_ host: SBSPlaybackView) {
        guard !stopped else { return }
        session?.stop()
        session = nil
        installOutput(host)
        guard let file, let session else { return }
        do {
            let resume = hasStarted && phase != .ended && phase != .failed
            openingPaused = resume && !wantsPlayback
            awaitingOutput = resume
            pendingSeek = nil
            try session.load(fileURL: file, startAt: seconds, paused: openingPaused)
            if resume { session.play(waitForPausedFrame: openingPaused) }
        } catch {
            // This can happen if the local file disappears while the clip is open.
            phase = .failed
            let failure = PlaybackSnapshot(phase: .failed, error: "切换播放格式失败，请关闭并重新打开视频。\n" + error.localizedDescription)
            DispatchQueue.main.async { [weak self, weak session] in
                guard let self, self.session === session, !self.stopped else { return }
                self.onUpdate?(failure)
            }
        }
    }

    func load(fileURL: URL) throws {
        guard !stopped else { throw ClientError("播放器已关闭，请重新打开视频。") }
        try nativeSession().load(fileURL: fileURL)
        file = fileURL
        seconds = 0
        phase = .idle
        openingPaused = false
        awaitingOutput = false
        pendingSeek = nil
        hasStarted = false
    }

    func play() {
        guard !stopped, file != nil else { return }
        wantsPlayback = true
        hasStarted = true
        session?.play()
    }

    func pause() {
        wantsPlayback = false
        session?.pause()
    }

    func seek(to position: Double) {
        guard position.isFinite else { return }
        seconds = max(0, position)
        if awaitingOutput {
            pendingSeek = seconds
        } else {
            session?.seek(to: seconds)
        }
    }

    func stop() {
        stopped = true
        onUpdate = nil
        session?.stop()
        session = nil
    }
}
