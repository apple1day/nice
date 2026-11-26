import UIKit

enum MovieOutput: Equatable {
    case system, afterglow, vlcNative, vlcFrames

    var usesAVPlayer: Bool { self == .system || self == .afterglow }

    static func defaultOutput(for url: URL, pickedFile: PickedVideoFile?) -> Self {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v", "mov": return .system
        default: return pickedFile == nil ? .vlcNative : .vlcFrames
        }
    }

    var title: String {
        switch self {
        case .system: return "系统播放器"
        case .afterglow: return "Afterglow XR"
        case .vlcNative: return "VLC 原生显示"
        case .vlcFrames: return "VLC 兼容显示"
        }
    }
}
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
    private(set) var standardOutput: MovieOutput?
    var mode: SBSDisplayMode {
        get { format }
        set { configure(mode: newValue, standardOutput: standardOutput) }
    }

    func configure(mode: SBSDisplayMode, standardOutput: MovieOutput?) {
        guard mode != format || standardOutput != self.standardOutput else { return }
        format = mode
        self.standardOutput = standardOutput
        let needsFrames = mode != .standard || standardOutput == .vlcFrames
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
        drawableView.isHidden = renderer != nil && standardOutput?.usesAVPlayer != true
        onOutputChange?()
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

// The Apple decoder can feed either the layer or the two-eye renderer.
// VLC's native and callback-based outputs require separate decoder sessions.
extension AppleFilePlaybackEngine: SwitchableVideoEngine {}

protocol SystemOutputRetrying: AnyObject {
    @MainActor func retrySystemOutput()
    @MainActor func retryAfterglowOutput()
}

final class SBSPlaybackEngine: LocalPlaybackEngine, PlaybackDiagnosticReporting, SystemOutputRetrying {
    private let diagnostics: PlaybackDiagnostics
    var onUpdate: ((PlaybackSnapshot) -> Void)?
    private var session: SwitchableVideoEngine?
    private weak var hostView: SBSPlaybackView?
    private(set) var currentOutput: MovieOutput?
    private var failedAppleOutput: MovieOutput?
    private var reducedVLCFrameOutput = false
    private var systemStereo = false
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

    init(pickedFile: PickedVideoFile? = nil) {
        self.pickedFile = pickedFile
        diagnostics = PlaybackDiagnostics(bytes: pickedFile?.byteCount)
    }

    @MainActor private var rendererStatus: String {
        hostView?.renderer?.frameDiagnostics ?? "metal=inactive"
    }

    @MainActor func playbackDiagnosticReport() -> String? {
        diagnostics.report { rendererStatus }
    }

    func attach(to view: UIView) {
        guard !stopped else { return }
        guard let host = view as? SBSPlaybackView else {
            nativeSession().attach(to: view)
            return
        }
        MainActor.assumeIsolated {
            hostView?.onOutputChange = nil
            hostView = host
            if host.standardOutput == nil, let url = pickedFile?.url ?? file {
                host.configure(mode: host.mode, standardOutput: MovieOutput.defaultOutput(for: url, pickedFile: pickedFile))
            }
            host.onOutputChange = { [weak self, weak host] in
                guard let self, let host, self.hostView === host else { return }
                self.reconcileOutput(host)
            }
            reconcileOutput(host, attaching: true)
        }
    }

    private func observe(_ newSession: SwitchableVideoEngine) {
        session = newSession
        newSession.onUpdate = { [weak self, weak newSession] snapshot in
            guard let self, !self.stopped, self.session === newSession else { return }
            self.diagnostics.observe(snapshot) { MainActor.assumeIsolated { self.rendererStatus } }
            if let output = self.currentOutput, output.usesAVPlayer, snapshot.phase == .failed, let host = self.hostView {
                self.diagnostics.event("fallback \(output) -> VLC (system session reported failure)")
                self.failedAppleOutput = output
                // The failing input may be the first event, before it has a
                // usable timestamp. Preserve the requested seek in that case.
                if let seek = self.pendingSeek { self.seconds = seek }
                else if snapshot.seconds.isFinite, snapshot.seconds > 0 { self.seconds = snapshot.seconds }
                MainActor.assumeIsolated { self.reconcileOutput(host) }
                return
            }
            if snapshot.retryVLCWithSmallerFrames, self.currentOutput == .vlcFrames,
               !self.reducedVLCFrameOutput, self.wantsPlayback, !self.awaitingOutput, !self.openingPaused,
               self.pendingSeek == nil, self.phase != .ended, self.phase != .failed, let host = self.hostView {
                MainActor.assumeIsolated {
                    self.seconds = snapshot.seconds
                    self.reducedVLCFrameOutput = true
                    self.diagnostics.event("VLC: late pictures without new frames; reopening at \(self.seconds)s, maximum frame edge 1280")
                    self.retireSession()
                    self.installVLCFrameSession()
                    self.reopenAfterOutputChange(host)
                }
                return
            }
            // A stopped event may trail EOF. Only an explicit reload can
            // restart that input, including when changing output at the end.
            let pickedFileFailure = self.pickedFile != nil && snapshot.phase == .failed
            if self.phase == .failed || (self.phase == .ended && !pickedFileFailure) { return }
            var visible = snapshot
            visible.videoOutput = self.currentOutput
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

    private func nativeSession() -> SwitchableVideoEngine {
        if let session { return session }
        let newSession = VLCPlaybackEngine(frameHandler: nil, pickedFile: pickedFile)
        currentOutput = .vlcNative
        newSession.diagnostics = diagnostics
        diagnostics.setRoute(.vlcNative, mode: .standard)
        observe(newSession)
        return newSession
    }

    @MainActor private func frameHandler() -> (CVPixelBuffer) -> Void {
        { [weak self] pixelBuffer in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.currentOutput == .vlcFrames { self.diagnostics.decodedFrame(pixelBuffer, pts: nil) }
                self.hostView?.renderer?.display(pixelBuffer)
            }
        }
    }

    @MainActor private func installVLCFrameSession() {
        let vlc = VLCPlaybackEngine(frameHandler: frameHandler(), pickedFile: pickedFile,
                                    reducedFrameOutput: reducedVLCFrameOutput,
                                    preferSmallerPanoramaFrames: hostView.map { $0.mode != .standard } ?? false)
        vlc.diagnostics = diagnostics
        observe(vlc)
    }

    @MainActor private func reconcileOutput(_ host: SBSPlaybackView, attaching: Bool = false) {
        // A bare playback surface can be attached before the local URL is known.
        guard let output = host.standardOutput else { return }
        let useRequestedOutput = output.usesAVPlayer && failedAppleOutput != output
        let next: MovieOutput = useRequestedOutput ? output : (host.renderer == nil ? .vlcNative : .vlcFrames)
        diagnostics.setRoute(next, mode: host.mode)
        if next == currentOutput, let session {
            if let vlc = session as? VLCPlaybackEngine, next == .vlcFrames {
                vlc.preferSmallerPanoramaFrames = host.mode != .standard
            }
            if attaching && next != .vlcFrames { session.attach(to: host.drawableView) }
            if let apple = session as? AppleFilePlaybackEngine {
                configureSystemStereo(apple, host: host)
            }
            return
        }
        if phase == .failed { phase = .opening }
        retireSession()
        host.renderer?.clear()
        currentOutput = next
        systemStereo = false
        if next.usesAVPlayer {
            let apple = AppleFilePlaybackEngine(pickedFile: pickedFile, afterglow: next == .afterglow)
            apple.diagnostics = diagnostics
            observe(apple)
            apple.attach(to: host.drawableView)
            configureSystemStereo(apple, host: host)
        } else if next == .vlcFrames {
            installVLCFrameSession()
        } else {
            nativeSession().attach(to: host.drawableView)
        }
        reopenAfterOutputChange(host)
    }

    @MainActor private func configureSystemStereo(_ apple: AppleFilePlaybackEngine, host: SBSPlaybackView) {
        let stereo = host.mode != .standard
        if stereo != systemStereo {
            systemStereo = stereo
            apple.setVideoFrameHandler(stereo ? frameHandler() : nil)
        }
    }

    @MainActor func retrySystemOutput() {
        retry(.system)
    }

    @MainActor func retryAfterglowOutput() {
        retry(.afterglow)
    }

    @MainActor private func retry(_ output: MovieOutput) {
        guard failedAppleOutput == output else { return }
        failedAppleOutput = nil
        if let hostView, hostView.standardOutput == output { reconcileOutput(hostView) }
    }

    @MainActor private func reopenAfterOutputChange(_ host: SBSPlaybackView) {
        // At EOF the model will explicitly reload on replay or a new seek.
        // Opening here would first prepare an unused input at the end of the file.
        guard phase != .ended, let file, let session else { return }
        do {
            let resume = hasStarted
            openingPaused = resume && !wantsPlayback
            awaitingOutput = resume
            pendingSeek = nil
            diagnostics.beginInput(at: seconds)
            try session.load(fileURL: file, startAt: seconds, paused: openingPaused)
            if resume { session.play(waitForPausedFrame: openingPaused) }
        } catch {
            if let output = currentOutput, output.usesAVPlayer {
                failedAppleOutput = output
                reconcileOutput(host)
                return
            }
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
        let differentFile = file != fileURL
        if differentFile {
            reducedVLCFrameOutput = false
            let size = pickedFile?.byteCount ?? (fileURL.isFileURL
                ? (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { UInt64(exactly: $0) }
                : nil)
            diagnostics.setFileByteCount(size)
        }
        MainActor.assumeIsolated {
            if let host = hostView, host.standardOutput == nil {
                host.configure(mode: host.mode, standardOutput: MovieOutput.defaultOutput(for: fileURL, pickedFile: pickedFile))
            }
        }
        if currentOutput == .vlcFrames, let vlc = session as? VLCPlaybackEngine, vlc.loaded {
            // VLC 3 may reuse a vout across equal-format inputs. Its vmem
            // format still owns the old media token; do not reuse that player
            // or weaken the check that rejects frames from a retired input.
            retireSession()
            MainActor.assumeIsolated {
                hostView?.renderer?.clear()
                installVLCFrameSession()
            }
        }
        file = fileURL
        seconds = 0
        phase = .idle
        openingPaused = false
        awaitingOutput = false
        pendingSeek = nil
        hasStarted = false
        do {
            let player = nativeSession()
            diagnostics.beginInput(at: 0, differentFile: differentFile)
            try player.load(fileURL: fileURL)
        } catch {
            guard let output = currentOutput, output.usesAVPlayer, let hostView else { throw error }
            failedAppleOutput = output
            MainActor.assumeIsolated { reconcileOutput(hostView) }
        }
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
        diagnostics.event("seek target=\(seconds)")
        if awaitingOutput {
            pendingSeek = seconds
        } else {
            session?.seek(to: seconds)
        }
    }

    func stop() {
        stopped = true
        onUpdate = nil
        retireSession()
    }

    private func retireSession() {
        session?.onUpdate = nil
        session?.stop()
        session = nil
    }
}
