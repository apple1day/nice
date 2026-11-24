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
            var visible = snapshot
            if self.openingPaused {
                // Opening a paused file can first report .opening/.playing. Keep
                // controls paused and never toggle native audio on to get a frame.
                if snapshot.phase == .paused {
                    self.openingPaused = false
                    if self.wantsPlayback { self.session?.play() }
                } else if !self.wantsPlayback && (snapshot.phase == .opening || snapshot.phase == .playing) {
                    visible.phase = .paused
                }
            }
            // Until a reopened input reports a timestamp, keep the displayed
            // position even if the user rapidly switches the output again.
            if visible.seconds == 0, self.seconds > 0,
               visible.phase == .opening || visible.phase == .paused || visible.phase == .playing {
                visible.seconds = self.seconds
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
            try session.load(fileURL: file, startAt: seconds, paused: openingPaused)
            if resume { session.play() }
        } catch {
            // This can happen if the local file disappears while the clip is open.
            phase = .failed
            let failure = PlaybackSnapshot(phase: .failed, error: error.localizedDescription)
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
        session?.seek(to: position)
    }

    func stop() {
        stopped = true
        onUpdate = nil
        session?.stop()
        session = nil
    }
}
