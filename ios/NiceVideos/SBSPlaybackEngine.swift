import UIKit

/// Both VLC outputs live under the same SwiftUI surface for the lifetime of a clip.
final class SBSPlaybackView: UIView {
    private var pendingStart: ((SBSPlaybackView) -> Void)?
    private var startWork: DispatchWorkItem?
    private var didStartPlayback = false
    private static let readinessNotifications = [
        UIWindow.didBecomeVisibleNotification, UIScene.didActivateNotification, UIApplication.didBecomeActiveNotification
    ]
    let drawableView = UIView()
    private(set) var renderer: SBSMetalView?
    var onOutputChange: (() -> Void)?
    private var format: SBSDisplayMode = .standard
    private var standardFrameOutput: Bool?
    var mode: SBSDisplayMode {
        get { format }
        set { configure(mode: newValue, standardFrameOutput: standardFrameOutput) }
    }

    func selectDefaultOutput(forPickedFile picked: Bool) {
        if standardFrameOutput == nil { configure(mode: mode, standardFrameOutput: picked) }
    }

    func configure(mode: SBSDisplayMode, standardFrameOutput: Bool?) {
        guard mode != format || standardFrameOutput != self.standardFrameOutput else { return }
        let usedFrameOutput = renderer != nil
        format = mode
        self.standardFrameOutput = standardFrameOutput
        let needsFrames = mode != .standard || standardFrameOutput == true
        if needsFrames && renderer == nil {
            let view = SBSMetalView(frame: bounds)
            if mode != .standard || view.isReadyForDisplay {
                view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                addSubview(view)
                renderer = view
            }
        }
        if !needsFrames || (mode == .standard && renderer?.isReadyForDisplay == false) {
            renderer?.clear()
            renderer?.removeFromSuperview()
            renderer = nil
        }
        renderer?.mode = mode
        drawableView.isHidden = renderer != nil
        // Flat and both stereo projections can share a single decoder and clock.
        if usedFrameOutput != (renderer != nil) { onOutputChange?() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        drawableView.frame = bounds
        drawableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(drawableView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    // SwiftUI can create the view before giving it a window or a size. Opening
    // VLC on that first zero-size drawable can leave an unusable framebuffer.
    func startPlaybackWhenReady(_ start: @escaping (SBSPlaybackView) -> Void) {
        guard !didStartPlayback, pendingStart == nil else { return }
        pendingStart = start
        for name in Self.readinessNotifications {
            NotificationCenter.default.addObserver(self, selector: #selector(windowBecameAvailable(_:)),
                                                   name: name, object: nil)
        }
        scheduleStartIfReady()
    }

    func cancelPendingStart() {
        pendingStart = nil
        startWork?.cancel()
        startWork = nil
        for name in Self.readinessNotifications {
            NotificationCenter.default.removeObserver(self, name: name, object: nil)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            startWork?.cancel()
            startWork = nil
        } else {
            scheduleStartIfReady()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scheduleStartIfReady()
    }

    @objc private func windowBecameAvailable(_ notification: Notification) { scheduleStartIfReady() }

    private var hasReadyViewport: Bool {
        guard let window, !window.isHidden, bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return false }
        if let scene = window.windowScene { return scene.activationState == .foregroundActive }
        return true
    }

    private func scheduleStartIfReady() {
        guard pendingStart != nil, startWork == nil, hasReadyViewport else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.startWork = nil
            guard self.hasReadyViewport, let start = self.pendingStart else { return }
            self.didStartPlayback = true
            self.cancelPendingStart()
            start(self)
        }
        startWork = work
        DispatchQueue.main.async(execute: work)
    }
}

/// VLC selects a native drawable or vmem when it opens a video output. Reopen only
/// when crossing that boundary. The flat Metal view and both SBS formats share a decoder.
final class SBSPlaybackEngine: LocalPlaybackEngine {
    var onUpdate: ((PlaybackSnapshot) -> Void)?
    private var session: VLCPlaybackEngine?
    private weak var hostView: SBSPlaybackView?
    private var usesFrameOutput = false
    private let pickedFile: PickedVideoFile?
    private var file: URL?
    private var seconds = 0.0
    private var phase: PlaybackPhase = .idle
    private var hasStarted = false
    private var wantsPlayback = false
    private var openingPaused = false
    private var awaitingOutput = false
    private var pendingSeek: Double?
    private var stopped = false

    init(pickedFile: PickedVideoFile? = nil) { self.pickedFile = pickedFile }

    func attach(to view: UIView) {
        guard !stopped else { return }
        guard let host = view as? SBSPlaybackView else {
            nativeSession().attach(to: view)
            return
        }
        MainActor.assumeIsolated {
            hostView?.onOutputChange = nil
            hostView = host
            host.selectDefaultOutput(forPickedFile: pickedFile != nil)
            host.onOutputChange = { [weak self, weak host] in
                guard let self, let host, self.hostView === host else { return }
                self.changeOutput(host)
            }
            if session == nil {
                installOutput(host)
            } else if usesFrameOutput != (host.renderer != nil) {
                changeOutput(host)
            } else if !usesFrameOutput {
                session?.attach(to: host.drawableView)
            }
        }
    }

    private func observe(_ newSession: VLCPlaybackEngine) {
        session = newSession
        newSession.onUpdate = { [weak self] snapshot in
            guard let self, !self.stopped else { return }
            // A stopped event may trail EOF. Only an explicit reload can
            // restart that input, including when changing output at the end.
            let pickedFileFailure = self.pickedFile != nil && snapshot.phase == .failed
            if self.phase == .failed || (self.phase == .ended && !pickedFileFailure) { return }
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
        let newSession = VLCPlaybackEngine(frameHandler: nil, pickedFile: pickedFile)
        observe(newSession)
        return newSession
    }

    @MainActor private func installOutput(_ host: SBSPlaybackView) {
        usesFrameOutput = host.renderer != nil
        if usesFrameOutput {
            observe(VLCPlaybackEngine(frameHandler: { [weak self] frame in
                // Resolve the current SwiftUI host at delivery, including after reattachment.
                MainActor.assumeIsolated { self?.hostView?.renderer?.display(frame) }
            }, pickedFile: pickedFile))
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
