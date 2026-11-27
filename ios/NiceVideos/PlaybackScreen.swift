import SwiftUI
import AVFoundation
import UIKit
import Combine

// Main-queue confined. The engine is injected in lifecycle tests, not mocked via VLC internals.
final class PlaybackModel: ObservableObject {
    @Published private(set) var phase: PlaybackPhase = .idle
    @Published private(set) var seconds: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var seekable = false
    @Published private(set) var videoOutput: MovieOutput?
    @Published private(set) var videoDetails: String?
    @Published private(set) var message: String?
    @Published private(set) var suggestsCompatibleCopy = false
    var onPlaybackEnded: (() -> Void)?
    private let request: PlaybackRequest
    private let engine: LocalPlaybackEngine
    private let defaults: UserDefaults
    private let manageAudioSession: Bool
    private var started = false
    private var pauseRequested = false
    private var closed = false
    private var copyingDiagnostics = false
    private var reportedPlaybackEnd = false
    private var pendingPlaybackEnd: UUID?
    private var rearmPlaybackEndOnPlaying = false
    private var playbackInputEnded = false
    private var isScrubbing = false
    private var pendingRestartSeek: Double?
    private var restoredPosition = false
    private var lastSave = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private var previousIdleTimer = false
    private var key: String { "position." + request.key }

    init(request: PlaybackRequest, engine: LocalPlaybackEngine? = nil,
         defaults: UserDefaults = .standard, manageAudioSession: Bool = true) {
        self.request = request
        self.engine = engine ?? SBSPlaybackEngine(pickedFile: request.pickedFile)
        self.defaults = defaults
        self.manageAudioSession = manageAudioSession
        self.engine.onUpdate = { [weak self] snapshot in self?.receive(snapshot) }
        if manageAudioSession {
            previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
            observers.append(NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
            ) { [weak self] notification in
                let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                if raw == AVAudioSession.InterruptionType.began.rawValue { self?.pause() }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
            ) { [weak self] notification in
                let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                if raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause() }
            })
        }
    }
    func attach(to view: UIView) {
        guard !closed else { return }
        engine.attach(to: view)
        guard !started else { return }
        started = true
        do {
            try engine.load(fileURL: request.url)
            if pauseRequested {
                phase = .paused
            } else {
                try activateAudio()
                phase = .opening
                engine.play()
            }
        } catch {
            message = error.localizedDescription
            phase = .failed
        }
    }
    private func activateAudio() throws {
        guard manageAudioSession else { return }
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try AVAudioSession.sharedInstance().setActive(true)
    }
    func toggle() {
        guard started && !closed else { return }
        if phase == .playing || phase == .opening { pause(); return }
        guard phase != .failed else { return }
        do {
            try activateAudio()
            pauseRequested = false
            if reportedPlaybackEnd { rearmPlaybackEndOnPlaying = true }
            if playbackInputEnded {
                pendingPlaybackEnd = nil
                if pendingRestartSeek == nil { seconds = 0 }
                restoredPosition = true
                phase = .opening
                // VLCKit 3.7.3 play() alone retains an EOF input. Reload the
                // file on the existing playback surface before resuming.
                try engine.load(fileURL: request.url)
            }
            engine.play()
        } catch {
            message = error.localizedDescription
            if playbackInputEnded { phase = .failed }
        }
    }
    func pause() {
        guard !closed else { return }
        pendingPlaybackEnd = nil
        pauseRequested = true
        guard started else { return }
        savePosition()
        engine.pause()
        if phase == .playing || phase == .opening { phase = .paused }
        if manageAudioSession { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
    }
    func setScrubbing(_ editing: Bool) {
        guard !closed, isScrubbing != editing else { return }
        isScrubbing = editing
        if !editing { schedulePendingPlaybackEnd() }
    }
    func seek(to value: Double) {
        guard !closed, seekable, let value = PlaybackPosition.clamp(value, duration: duration) else { return }
        pendingPlaybackEnd = nil
        if reportedPlaybackEnd { rearmPlaybackEndOnPlaying = true }
        restoredPosition = true
        seconds = value
        if !playbackInputEnded, pendingRestartSeek == nil {
            // Ordinary seeks stay on the existing input, without any file I/O.
            engine.seek(to: value)
            savePosition()
            return
        }
        // EOF recovery validates/reloads only this current file. Keep the same
        // engine and surface, and apply the target once its new input is ready.
        let alreadyWaiting = pendingRestartSeek != nil
        pendingRestartSeek = value
        if !alreadyWaiting {
            if pauseRequested {
                phase = .paused
            } else {
                do {
                    try activateAudio()
                    phase = .opening
                    try engine.load(fileURL: request.url)
                    engine.play()
                } catch {
                    message = error.localizedDescription
                    phase = .failed
                }
            }
        }
        savePosition()
    }
    @MainActor func copyPlaybackDiagnostics() async -> Bool {
        guard !closed, !copyingDiagnostics, let reporting = engine as? PlaybackDiagnosticReporting else { return false }
        copyingDiagnostics = true
        defer { copyingDiagnostics = false }
        guard let report = await reporting.capturePlaybackDiagnosticReport(), !closed else { return false }
        UIPasteboard.general.string = report
        UIAccessibility.post(notification: .announcement, argument: "播放诊断已复制")
        return true
    }

    @MainActor func prepareOutputChange(to output: MovieOutput, retry: Bool = true) {
        if phase == .failed {
            message = nil
            phase = .opening
        }
        guard retry else { return }
        if output == .system { (engine as? SystemOutputRetrying)?.retrySystemOutput() }
        if output == .afterglow { (engine as? SystemOutputRetrying)?.retryAfterglowOutput() }
    }

    private func receive(_ snapshot: PlaybackSnapshot) {
        guard !closed, phase != .failed else { return }
        if let output = snapshot.videoOutput, videoOutput != output { videoOutput = output }
        if let details = snapshot.videoDetails, videoDetails != details { videoDetails = details }
        // Native stop notifications may follow EOF. Preserve the terminal state
        // and cleared bookmark until an explicit replay or seek actually starts.
        if playbackInputEnded || pendingRestartSeek != nil, snapshot.phase == .idle { return }
        if rearmPlaybackEndOnPlaying || pendingRestartSeek != nil, snapshot.phase == .ended { return }
        let nextPhase: PlaybackPhase
        if snapshot.phase == .playing && pauseRequested {
            engine.pause()
            nextPhase = .paused
        } else {
            nextPhase = snapshot.phase
        }
        if nextPhase == .ended { playbackInputEnded = true }
        // A restarted decoder can report playing before it has a duration or
        // accepts seeks. Keep the old EOF suppressed until its queued target
        // has actually been applied to a ready input.
        if snapshot.phase == .playing, rearmPlaybackEndOnPlaying, pendingRestartSeek == nil {
            playbackInputEnded = false
        }
        if nextPhase == .playing, rearmPlaybackEndOnPlaying, pendingRestartSeek == nil {
            rearmPlaybackEndOnPlaying = false
            reportedPlaybackEnd = false
        }
        // Avoid publishing unchanged phase/duration/flags on every time callback.
        if phase != nextPhase { phase = nextPhase }
        let nextSeconds = snapshot.seconds.isFinite ? max(0, snapshot.seconds) : 0
        let rawDuration = snapshot.duration.isFinite ? max(0, snapshot.duration) : 0
        let nextDuration = rawDuration > 0 ? rawDuration
            : (playbackInputEnded || pendingRestartSeek != nil ? duration : 0)
        // EOF must not disable the progress control and cancel a held drag.
        // Keep its last valid range; seek() handles restarting a stopped input.
        let preservingSeekRange = playbackInputEnded || pendingRestartSeek != nil
        let nextSeekable = (snapshot.seekable || (preservingSeekRange && seekable)) && nextDuration > 0
        let displayedSeconds = pendingRestartSeek ?? nextSeconds
        if seconds != displayedSeconds { seconds = displayedSeconds }
        if duration != nextDuration { duration = nextDuration }
        if seekable != nextSeekable { seekable = nextSeekable }
        if message != snapshot.error { message = snapshot.error }
        if suggestsCompatibleCopy != snapshot.suggestsCompatibleCopy { suggestsCompatibleCopy = snapshot.suggestsCompatibleCopy }
        if manageAudioSession {
            let disabled = phase == .playing ? true : previousIdleTimer
            if UIApplication.shared.isIdleTimerDisabled != disabled {
                UIApplication.shared.isIdleTimerDisabled = disabled
            }
        }
        if phase == .ended {
            defaults.removeObject(forKey: key)
            restoredPosition = true
            reportPlaybackEnd()
            return
        }
        if let target = pendingRestartSeek, snapshot.seekable, rawDuration > 0,
           phase == .playing || phase == .paused {
            pendingRestartSeek = nil
            playbackInputEnded = false
            if phase == .playing {
                rearmPlaybackEndOnPlaying = false
                reportedPlaybackEnd = false
            }
            if let target = PlaybackPosition.clamp(target, duration: duration) {
                seconds = target
                engine.seek(to: target)
                savePosition()
            }
            return
        }
        if !restoredPosition, seekable, phase == .playing || phase == .paused {
            restoredPosition = true
            if let target = PlaybackPosition.resume(saved: defaults.double(forKey: key), duration: duration) {
                seconds = target
                engine.seek(to: target)
                lastSave = Date()
                return
            }
        }
        if Date().timeIntervalSince(lastSave) >= 5 { savePosition() }
    }
    private func reportPlaybackEnd() {
        guard !reportedPlaybackEnd else { return }
        reportedPlaybackEnd = true
        guard started, !pauseRequested else { return }
        pendingPlaybackEnd = UUID()
        schedulePendingPlaybackEnd()
    }
    private func schedulePendingPlaybackEnd() {
        guard !closed, !isScrubbing, !pauseRequested, let token = pendingPlaybackEnd else { return }
        // Finish processing the terminal snapshot before a playlist closes this
        // player. Touch-up reports editing=false before committing its seek;
        // deferring lets that seek cancel completion in the same event turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed, !self.pauseRequested, !self.isScrubbing,
                  self.phase == .ended, self.pendingPlaybackEnd == token else { return }
            self.pendingPlaybackEnd = nil
            self.onPlaybackEnded?()
        }
    }
    private func savePosition() {
        guard restoredPosition, phase != .ended, phase != .failed,
              seconds.isFinite, seconds >= 0 else { return }
        defaults.set(seconds, forKey: key)
        lastSave = Date()
    }
    func close() {
        guard !closed else { return }
        savePosition()
        closed = true
        pendingPlaybackEnd = nil
        pendingRestartSeek = nil
        onPlaybackEnded = nil
        engine.onUpdate = nil
        engine.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if manageAudioSession {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimer
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
    deinit {
        if !closed { engine.stop() }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}

private struct MovieVideoSurface: UIViewRepresentable {
    let model: PlaybackModel
    let mode: SBSDisplayMode
    let standardOutput: MovieOutput
    let decoderPolicy: VLCDecoderPolicy
    let camera: VRGestureCamera
    let followHead: Bool
    let wakeGesture: VRWakeGesture
    let nativeResolution: Bool
    let renderScalePercent: Int?
    let targetFrameRate: Int

    @MainActor private func configure(_ view: SBSPlaybackView) {
        view.configure(mode: mode, standardOutput: standardOutput, decoderPolicy: decoderPolicy)
        if let renderer = view.renderer {
            if renderer.nativeResolution != nativeResolution { renderer.nativeResolution = nativeResolution }
            if renderer.renderScalePercent != renderScalePercent { renderer.renderScalePercent = renderScalePercent }
            if renderer.targetFrameRate != targetFrameRate { renderer.targetFrameRate = targetFrameRate }
        }
        if case .immersive = mode { camera.connect(to: view.renderer, followHead: followHead, wake: wakeGesture) }
        else { camera.connect(to: nil, followHead: false) }
    }
    func makeCoordinator() -> PlaybackModel { model }
    func makeUIView(context: Context) -> SBSPlaybackView {
        let view = SBSPlaybackView(frame: .zero)
        configure(view)
        view.startPlaybackWhenReady { [weak model] view in model?.attach(to: view) }
        return view
    }
    func updateUIView(_ view: SBSPlaybackView, context: Context) { configure(view) }
    static func dismantleUIView(_ view: SBSPlaybackView, coordinator: PlaybackModel) {
        view.cancelPendingStart()
        coordinator.close()
    }
}

// Draft changes stay in this small view, without store/playlist traversal or
// file I/O. A committed seek stays on the existing input; only recovery after
// EOF revalidates and reopens the current file before applying its target.
private struct PlaybackProgressView: View {
    @ObservedObject var model: PlaybackModel
    let isEnabled: Bool
    let scrubber: PlaybackScrubController
    let onEditingChanged: (Bool) -> Void
    @State private var draftSeconds: Double?
    private var displayedSeconds: Double { draftSeconds ?? model.seconds }

    var body: some View {
        VStack(spacing: 4) {
            PlaybackSlider(seconds: model.seconds, duration: model.duration,
                           isEnabled: isEnabled && model.seekable, controller: scrubber,
                           onDraftChanged: { draftSeconds = $0 },
                           onEditingChanged: { editing in
                               model.setScrubbing(editing)
                               onEditingChanged(editing)
                           },
                           onCommit: { model.seek(to: $0) })
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .accessibilityIdentifier("playbackProgressSlider")
            HStack {
                Text(PlaybackPosition.label(displayedSeconds))
                    .accessibilityIdentifier("playbackElapsedTime")
                Spacer()
                Text(PlaybackPosition.label(model.duration))
            }.font(.caption.monospacedDigit())
        }
    }
}

struct PlaybackScreen: View {
    @EnvironmentObject private var store: VideoStore
    let request: PlaybackRequest
    var body: some View { PlaylistPlayerHost(request: request, store: store) }
}

private struct PlaylistPlayerHost: View {
    @StateObject private var playlist: PlaylistPlaybackModel
    init(request: PlaybackRequest, store: VideoStore) {
        _playlist = StateObject(wrappedValue: PlaylistPlaybackModel(request: request, store: store))
    }
    var body: some View { PlaylistPlayerView(playlist: playlist, model: playlist.player) }
}

// Observe the system Button's press state instead of installing an ancestor
// tap/drag recognizer. This preserves native cancellation and accessibility.
private struct PlaybackTransportButtonStyle: ButtonStyle {
    let onPressChanged: (UUID, Bool) -> Void
    func makeBody(configuration: Configuration) -> some View {
        PlaybackButtonPressSurface(label: configuration.label,
                                   isPressed: configuration.isPressed,
                                   onPressChanged: onPressChanged)
    }
}

private struct PlaybackButtonPressSurface<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    let label: Label
    let isPressed: Bool
    let onPressChanged: (UUID, Bool) -> Void
    @State private var pressToken = UUID()
    var body: some View {
        label
            .contentShape(Rectangle())
            .opacity(isEnabled ? (isPressed ? 0.55 : 1) : 0.35)
            .background(isPressed ? Color.white.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: isPressed) { _, pressed in onPressChanged(pressToken, pressed) }
            .onDisappear { onPressChanged(pressToken, false) }
    }
}

@MainActor private struct PlaylistPlayerView: View {
    @EnvironmentObject private var store: VideoStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @ObservedObject var playlist: PlaylistPlaybackModel
    @ObservedObject var model: PlaybackModel
    @State private var controls = PlaybackControlsState()
    // Draft updates stay in PlaybackProgressView. This reference is only used
    // to cancel the current native tracking session synchronously before actions.
    @State private var scrubber = PlaybackScrubController()
    @State private var showsPlaylist = false
    @State private var showsPlaybackOptions = false
    @State private var diagnosticCopyNotice: UUID?
    @State private var showsVRSettings = false
    @State private var showsCompatiblePicker = false
    @State private var compatibleSelection: PickedVideoFile.Selection?
    @State private var preparingCompatibleCopy: Task<Void, Never>?
    @State private var resumeAfterCopyPicker = false
    @StateObject private var camera: VRGestureCamera
    @State private var vrProfile: VRMoviePreferences
    @AppStorage("vr.viewer.gyro") private var followHead = false
    @AppStorage("vr.viewer.nativeResolution") private var nativeResolution = false
    @AppStorage("vr.viewer.wakeGesture") private var wakeGesture: VRWakeGesture = .off
    @AppStorage("vr.viewer.doubleTap") private var doubleTap: VRDoubleTapAction = .recenter
    @AppStorage("vr.viewer.pinch") private var pinchResponse: VRPinchResponse = .regular
    @AppStorage(AfterglowPreset.decoderKey) private var vrDecoderPolicy: VLCDecoderPolicy = .automatic
    @AppStorage(AfterglowPreset.gyroKey) private var afterglowGyro = true
    @AppStorage(AfterglowPreset.renderScaleKey) private var afterglowRenderScale = 75
    @AppStorage(AfterglowPreset.frameRateKey) private var afterglowFrameRate = 30
    @State private var afterglowViewing: Bool
    @State private var displayMode: SBSDisplayMode
    @State private var outputOverride: MovieOutput?

    init(playlist: PlaylistPlaybackModel, model: PlaybackModel) {
        self.playlist = playlist
        self.model = model
        let request = playlist.current
        let afterglow = request.startMode == .afterglow
        let profile: VRMoviePreferences
        switch request.startMode {
        case .afterglow: profile = AfterglowPreset.load()
        case .panorama: profile = VRMoviePreferences(key: request.key)
        case .standard: profile = VRMoviePreferences()
        }
        _afterglowViewing = State(initialValue: afterglow)
        _outputOverride = State(initialValue: afterglow ? .afterglow : nil)
        _vrProfile = State(initialValue: profile)
        _displayMode = State(initialValue: request.startMode == .standard ? .standard : VRMoviePreferences.mode)
        _camera = StateObject(wrappedValue: VRGestureCamera(fieldOfView: profile.fieldOfView))
    }

    private var defaultOutput: MovieOutput { MovieOutput.defaultOutput(for: request.url, pickedFile: request.pickedFile) }
    private var standardOutput: MovieOutput {
        // A playlist may move from a system-compatible container to an MKV.
        if outputOverride == .system { return defaultOutput }
        return outputOverride ?? defaultOutput
    }
    private var activeOutput: MovieOutput { model.videoOutput ?? standardOutput }
    private var request: PlaybackRequest { playlist.current }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var isFullscreen: Bool { controls.isFullscreen || displayMode != .standard }
    private var immersive: Bool { if case .immersive = displayMode { return true }; return false }
    private var hasMessage: Bool { store.errorMessage != nil || model.message != nil || showsPlaylist || showsPlaybackOptions || showsVRSettings }
    private var isLibraryVideo: Bool { request.pickedFile == nil }
    private var showsPause: Bool { model.phase == .playing || model.phase == .opening }
    private var canInteract: Bool { scenePhase == .active && store.errorMessage == nil && !showsPlaylist && !showsVRSettings &&
        !showsCompatiblePicker && preparingCompatibleCopy == nil }
    private var transportButtonStyle: PlaybackTransportButtonStyle {
        PlaybackTransportButtonStyle { token, pressed in
            controls.setControlPressed(token, pressed: pressed, at: now)
        }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ZStack {
                    Color.black.ignoresSafeArea()
                    MovieVideoSurface(model: model, mode: displayMode, standardOutput: standardOutput,
                                      decoderPolicy: immersive ? vrDecoderPolicy : .automatic,
                                      camera: camera, followHead: immersive && (afterglowViewing ? afterglowGyro : followHead) && scenePhase == .active && !showsVRSettings,
                                      wakeGesture: immersive && canInteract && !hasMessage ? wakeGesture : .off,
                                      nativeResolution: nativeResolution,
                                      renderScalePercent: afterglowViewing ? afterglowRenderScale : nil,
                                      targetFrameRate: afterglowViewing ? afterglowFrameRate : 60)
                        .id(request.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea(.container, edges: isFullscreen ? .all : [])
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("offlineVideoSurface")
                    Group {
                        if immersive {
                            VRPanoramaSurface(camera: camera,
                                              response: pinchResponse, onTap: toggleControls, onDoubleTap: doubleTapped,
                                              onZoomEnd: { fov in
                                vrProfile.fieldOfView = fov
                                saveCurrentProfile()
                            })
                        } else {
                            Rectangle().fill(Color.clear).contentShape(Rectangle())
                                .onTapGesture { toggleControls() }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement()
                    .accessibilityLabel(immersive ? "全景视频画面，轻点显示或隐藏控制栏" : "视频画面，轻点显示或隐藏控制栏")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { toggleControls() }
                    .accessibilityActions {
                        if immersive { Button("视角回正") { camera.recenter() } }
                        if isLibraryVideo {
                            Button("上一个视频") { navigate(.previous) }
                            Button("下一个视频") { navigate(.next) }
                        }
                    }
                    .accessibilityIdentifier("playbackSurfaceToggle")
                }
                .overlay(alignment: .top) {
                    if isFullscreen {
                        fullscreenHeader
                            .opacity(controls.isVisible ? 1 : 0)
                            .allowsHitTesting(controls.isVisible)
                            .accessibilityHidden(!controls.isVisible)
                    }
                }
                .overlay(alignment: .bottom) {
                    transportControls(isLandscape: proxy.size.width > proxy.size.height)
                        .opacity(controls.isVisible ? 1 : 0)
                        .allowsHitTesting(controls.isVisible)
                        .accessibilityHidden(!controls.isVisible)
                }
                .onChange(of: proxy.size) { _, _ in cancelProgressInteraction() }
            }
            .background(.black)
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(isFullscreen ? .hidden : .visible, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { closePlayback(); dismiss() } label: {
                        Text("关闭").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(transportButtonStyle)
                    .accessibilityIdentifier("closePlayerButton")
                }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(isFullscreen)
        .persistentSystemOverlays(isFullscreen && !controls.isVisible ? .hidden : .automatic)
        .background {
            VRGamepadInput(enabled: immersive && canInteract && !hasMessage, onCommand: gamepadCommand)
                .frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
        }
        .onReceive(camera.controlsRequested) { _ in
            if immersive && canInteract && !hasMessage { revealControls() }
        }
        .sheet(isPresented: $showsPlaylist) { playlistSheet }
        .sheet(isPresented: $showsVRSettings) { immersiveSettings }
        .sheet(isPresented: $showsCompatiblePicker, onDismiss: resolveCompatibleSelection) {
            VideoDocumentPicker { selection in
                compatibleSelection = selection
                showsCompatiblePicker = false
            }
        }
        .overlay(alignment: .center) {
            if diagnosticCopyNotice != nil {
                Text("播放诊断已复制")
                    .foregroundStyle(.white).padding().background(.black.opacity(0.8), in: Capsule())
                    .allowsHitTesting(false)
            }
        }
        .task(id: diagnosticCopyNotice) {
            guard diagnosticCopyNotice != nil else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            diagnosticCopyNotice = nil
        }
        .alert("操作提示", isPresented: Binding(
            get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } }
        )) { Button("确定", role: .cancel) { store.errorMessage = nil } }
        message: { Text(store.errorMessage ?? "") }
        .onChange(of: request.id) { _, _ in
            cancelProgressInteraction()
            if immersive { enterPanorama() }
            controls.resetControlPresses(at: now)
            controls.setPlaying(model.phase == .playing, at: now)
            controls.interacted(at: now)
            if scenePhase != .active { model.pause() }
        }
        .onChange(of: model.phase, initial: true) { _, phase in
            controls.setPlaying(phase == .playing, at: now)
        }
        .onChange(of: hasMessage, initial: true) { _, value in controls.setPresentingAlert(value, at: now) }
        .onChange(of: voiceOverEnabled, initial: true) { _, value in controls.setVoiceOverEnabled(value, at: now) }
        .onChange(of: canInteract) { _, value in
            if !value { cancelProgressInteraction() }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            controls.setSceneActive(phase == .active, at: now)
            if phase != .active { cancelProgressInteraction(); model.pause() }
        }
        .task(id: controls.hideDeadline) {
            guard let deadline = controls.hideDeadline else { return }
            let delay = min(60, max(0, deadline - now))
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { controls.hideIfDue(at: now, deadline: deadline) }
        }
        .onDisappear { closePlayback() }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { controls.surfaceTapped(at: now) }
    }
    private func navigate(_ direction: LocalPlaybackPlaylist.Direction) {
        performTransportAction { playlist.move(direction) }
    }
    private func cancelProgressInteraction() {
        scrubber.cancel()
        controls.setScrubbing(false, at: now)
    }
    private func performTransportAction(_ action: () -> Void) {
        guard canInteract else { return }
        cancelProgressInteraction()
        action()
        revealControls()
    }
    private func navigationButton(_ direction: LocalPlaybackPlaylist.Direction, compact: Bool) -> some View {
        let previous = direction == .previous
        return Button { navigate(direction) } label: {
            if compact {
                Image(systemName: previous ? "backward.end.fill" : "forward.end.fill")
                    .frame(minWidth: 44, maxWidth: .infinity, minHeight: 52)
                    .contentShape(Rectangle())
            } else {
                Label(previous ? "上一个" : "下一个", systemImage: previous ? "backward.end.fill" : "forward.end.fill")
                    .font(.caption).frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
        .disabled(!canInteract || !playlist.canMove(direction))
        .accessibilityLabel(previous ? "上一个视频" : "下一个视频")
        .accessibilityIdentifier(previous ? "previousVideoButton" : "nextVideoButton")
    }
    private var fullscreenHeader: some View {
        HStack(spacing: 12) {
            Text(request.title).font(.headline).lineLimit(1)
            Spacer(minLength: 4)
            Button { closePlayback(); dismiss() } label: {
                Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
            }
                .accessibilityLabel("关闭播放器").accessibilityIdentifier("closeFullscreenPlayer")
        }
        .foregroundStyle(.white).padding(.horizontal, 16)
        .background(LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom))
        .contentShape(Rectangle())
        .buttonStyle(transportButtonStyle)
    }
    private func transportControls(isLandscape: Bool) -> some View {
        VStack(spacing: 4) {
            if immersive && !isLandscape {
                Text("请将手机横放后放入 VR 眼镜").font(.caption)
            }
            if model.phase == .opening { ProgressView("打开本地文件…").tint(.white).font(.caption) }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.suggestsCompatibleCopy {
                Button("打开兼容副本…", systemImage: "folder") {
                    cancelProgressInteraction()
                    resumeAfterCopyPicker = showsPause
                    if resumeAfterCopyPicker { model.pause() }
                    showsCompatiblePicker = true
                }
                .disabled(!canInteract)
                .accessibilityIdentifier("openCompatibleCopy")
            }
            if preparingCompatibleCopy != nil {
                ProgressView("正在打开所选副本…").tint(.white).font(.caption)
            }
            if let notice = playlist.notice ?? store.deletionNotice {
                Text(notice).font(.caption).lineLimit(2)
                    .accessibilityIdentifier("playbackActionNotice")
            }
            HStack(spacing: 8) {
                if isLibraryVideo && !isLandscape { navigationButton(.previous, compact: false) }
                Spacer(minLength: 4)
                if isLibraryVideo {
                    Button { performTransportAction { showsPlaylist = true } } label: {
                        Label(playlist.positionLabel, systemImage: "list.bullet")
                            .font(.caption.monospacedDigit())
                            .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(!canInteract)
                    .accessibilityLabel("本地播放列表 \(playlist.positionLabel)")
                    .accessibilityIdentifier("openLocalPlaylistButton")
                }
                if immersive {
                    Button { camera.recenter(); revealControls() } label: {
                        Image(systemName: "scope").frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel("视角回正").accessibilityIdentifier("vrRecenterButton")
                }
                if !immersive {
                    Button { performTransportAction(enterAfterglow) } label: {
                        Text("Afterglow XR").font(.subheadline.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .disabled(!canInteract)
                    .accessibilityLabel("用 Afterglow XR 播放")
                    .accessibilityIdentifier("afterglowCurrentVideo")
                }
                videoFormatButton
                if !immersive { ordinaryPlaybackOptions }
                Spacer(minLength: 4)
                if isLibraryVideo && !isLandscape { navigationButton(.next, compact: false) }
            }
            PlaybackProgressView(model: model, isEnabled: canInteract, scrubber: scrubber) { editing in
                controls.setScrubbing(editing, at: now)
            }.id(request.id)
            HStack(spacing: 0) {
                if isLibraryVideo && isLandscape {
                    navigationButton(.previous, compact: true).frame(minWidth: 0, maxWidth: .infinity)
                }
                Button { performTransportAction { model.seek(to: model.seconds - 15) } } label: {
                    Image(systemName: "gobackward.15")
                        .frame(minWidth: 44, maxWidth: .infinity, minHeight: 52).contentShape(Rectangle())
                }.disabled(!model.seekable || !canInteract).accessibilityLabel("后退15秒")
                    .frame(minWidth: 0, maxWidth: .infinity)
                Button { performTransportAction { model.toggle() } } label: {
                    Image(systemName: showsPause ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 38))
                        .frame(minWidth: 44, maxWidth: .infinity, minHeight: 52).contentShape(Rectangle())
                }.disabled(model.phase == .failed || model.phase == .idle || !canInteract)
                    .accessibilityLabel(showsPause ? "暂停" : "播放")
                    .accessibilityIdentifier("togglePlaybackButton")
                    .frame(minWidth: 0, maxWidth: .infinity)
                if isLibraryVideo {
                    transportFavoriteButton.frame(minWidth: 0, maxWidth: .infinity)
                    transportDeleteButton.frame(minWidth: 0, maxWidth: .infinity)
                }
                Button { performTransportAction { model.seek(to: model.seconds + 15) } } label: {
                    Image(systemName: "goforward.15")
                        .frame(minWidth: 44, maxWidth: .infinity, minHeight: 52).contentShape(Rectangle())
                }.disabled(!model.seekable || !canInteract).accessibilityLabel("前进15秒")
                    .frame(minWidth: 0, maxWidth: .infinity)
                if isLibraryVideo && isLandscape {
                    navigationButton(.next, compact: true).frame(minWidth: 0, maxWidth: .infinity)
                }
                Button { performTransportAction(toggleFullscreen) } label: {
                    Image(systemName: isFullscreen
                          ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .frame(minWidth: 44, maxWidth: .infinity, minHeight: 52).contentShape(Rectangle())
                }.disabled(!canInteract)
                    .accessibilityLabel(isFullscreen ? "退出全屏" : "全屏播放")
                    .accessibilityValue(isFullscreen ? "全屏" : "普通")
                    .accessibilityIdentifier("toggleFullscreenButton")
                    .frame(minWidth: 0, maxWidth: .infinity)
            }.font(.title2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
        .background {
            // Only the backdrop receives gap taps; no parent gesture competes
            // with Button's own activation or the Slider's tracking.
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .contentShape(Rectangle())
                .onTapGesture { revealControls() }
        }
        .buttonStyle(transportButtonStyle)
        // Keep identifiers on leaf controls. An identifier on this container
        // replaces its descendants' identifiers in SwiftUI's accessibility tree.
    }
    private func toggleFullscreen() {
        if controls.isFullscreen || displayMode == .standard { controls.toggleFullscreen(at: now) }
        leavePanorama()
    }

    private func leavePanorama() {
        if afterglowViewing {
            afterglowViewing = false
            outputOverride = nil
        }
        displayMode = .standard
    }

    private func selectOutput(_ output: MovieOutput, retry: Bool = true) {
        model.prepareOutputChange(to: output, retry: retry)
        outputOverride = output
    }

    private var videoFormatButton: some View {
        Button { performTransportAction {
            if immersive { showsVRSettings = true } else { enterPanorama() }
        } } label: {
            Text(immersive ? "VR 设置" : "VR")
                .font(.subheadline.bold())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .disabled(!canInteract)
        .accessibilityLabel(immersive ? "VR 设置" : "进入全景 VR")
        .accessibilityValue(immersive ? VRMoviePreferences.formatLabel : "普通播放")
        .accessibilityIdentifier("videoFormatButton")
    }

    private var ordinaryPlaybackOptions: some View {
        Button { performTransportAction { showsPlaybackOptions = true } } label: {
            Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44)
        }
        .disabled(!canInteract)
        .accessibilityLabel("播放选项")
        .accessibilityIdentifier("ordinaryPlaybackOptions")
        .confirmationDialog("播放选项", isPresented: $showsPlaybackOptions, titleVisibility: .visible) {
            if activeOutput != .vlcNative {
                Button("普通播放：切换到原生显示") { selectOutput(.vlcNative) }
            }
            if activeOutput != .vlcFrames {
                Button("普通播放：切换到兼容显示") { selectOutput(.vlcFrames) }
            }
            if defaultOutput == .system && activeOutput != .system {
                Button("切换到系统播放器") { selectOutput(.system) }
            }
            Button("复制播放诊断") {
                Task { if await model.copyPlaybackDiagnostics() { diagnosticCopyNotice = UUID() } }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(["当前解码：\(activeOutput.title)。", model.videoDetails].compactMap { $0 }.joined(separator: "\n"))
        }
    }

    private func enterAfterglow() {
        afterglowViewing = true
        selectOutput(.afterglow, retry: false)
        enterPanorama()
    }

    private func enterPanorama() {
        vrProfile = afterglowViewing ? AfterglowPreset.load() : VRMoviePreferences(key: request.key)
        camera.recenter()
        camera.setFOV(vrProfile.fieldOfView)
        displayMode = VRMoviePreferences.mode
        revealControls()
    }

    private func saveCurrentProfile() {
        if afterglowViewing { AfterglowPreset.save(vrProfile) }
        else { vrProfile.save(key: request.key) }
    }

    private func doubleTapped() {
        switch doubleTap {
        case .recenter:
            if immersive { camera.recenter() } else { toggleControls() }
        case .playback: performTransportAction { model.toggle() }
        case .controls: toggleControls()
        }
    }

    private func gamepadCommand(_ command: VRGamepadCommand) {
        guard immersive && canInteract && !hasMessage else { return }
        switch command {
        case .playPause: performTransportAction { model.toggle() }
        case .recenter: if immersive { camera.recenter() }
        case .toggleControls: toggleControls()
        case .backward: performTransportAction { model.seek(to: model.seconds - 15) }
        case .forward: performTransportAction { model.seek(to: model.seconds + 15) }
        }
    }

    private func changeVRDecoder(_ policy: VLCDecoderPolicy) {
        guard vrDecoderPolicy != policy else { return }
        vrDecoderPolicy = policy
        // Returning to automatic is an explicit retry of the preferred path.
        let preferred: MovieOutput = afterglowViewing ? .afterglow : defaultOutput
        model.prepareOutputChange(to: preferred, retry: policy == .automatic)
        outputOverride = afterglowViewing ? .afterglow : nil
    }

    private var immersiveSettings: some View {
        let appleActive = activeOutput == .system || activeOutput == .afterglow
        let retryOutput: MovieOutput = afterglowViewing ? .afterglow : .system
        let retryTitle = afterglowViewing ? "重试 Afterglow XR" : "恢复系统解码"
        let fallback = vrDecoderPolicy == .automatic && outputOverride == .afterglow && activeOutput == .vlcFrames
        var details = model.videoDetails
        if fallback {
            details = "Afterglow XR 已回退到 VLC。" + (details.map { " " + $0 } ?? "")
        }
        let action: String? = appleActive ? "尝试 VLC 解码" :
            (afterglowViewing || defaultOutput == .system ? retryTitle : nil)
        let gyro: Binding<Bool> = afterglowViewing ? $afterglowGyro : $followHead
        return VRViewerSettingsView(followHead: gyro, nativeResolution: $nativeResolution,
                             doubleTap: $doubleTap, pinchResponse: $pinchResponse, wakeGesture: $wakeGesture,
                             decoderPolicy: Binding(get: { vrDecoderPolicy }, set: changeVRDecoder),
                             sensorAvailable: camera.sensorAvailable, decoder: vrDecoderPolicy == .software && model.videoOutput == .vlcFrames
                                ? "VLC 软件解码" : (model.videoOutput?.title ?? "正在打开…"),
                             details: details, decoderAction: vrDecoderPolicy == .automatic ? action : nil,
                             onCopyDiagnostics: model.copyPlaybackDiagnostics,
                             onDecoderChange: { selectOutput(appleActive ? .vlcFrames : retryOutput) },
                             usesAfterglowPreset: afterglowViewing,
                             onOpenAfterglow: { enterAfterglow() },
                             onExit: { leavePanorama(); revealControls() })
    }

    private var transportFavoriteButton: some View {
        let favorite = playlist.currentEntry?.isFavorite == true
        return Button {
            revealControls()
            store.toggleFavorite(request.key)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: favorite ? "star.fill" : "star").font(.title2)
                Text(favorite ? "已收藏" : "收藏").font(.caption2).lineLimit(1)
            }
            .frame(minWidth: 44, maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        // Metadata changes do not seek or switch files; a Slider editing flag
        // (including a late end-editing callback) must not disable these actions.
        .disabled(!canInteract)
        .foregroundStyle(favorite ? Color.yellow : Color.white)
        .accessibilityLabel(favorite ? "取消收藏当前视频" : "收藏当前视频")
        .accessibilityValue(favorite ? "已收藏" : "未收藏")
        .accessibilityIdentifier("favoriteVideoButton")
    }

    private var transportDeleteButton: some View {
        let queued = playlist.currentEntry?.pendingDeletionOrder != nil
        let displayedRequestID = request.id
        return Button {
            revealControls()
            let success = playlist.markCurrentForDeletion(expectedRequestID: displayedRequestID)
            UINotificationFeedbackGenerator().notificationOccurred(success ? .success : .error)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: queued ? "checkmark.circle.fill" : "trash").font(.title2)
                Text(queued ? "待删除" : "删除").font(.caption2).lineLimit(1)
            }
            // Expand the LABEL, not just the outer Button layout, so the entire
            // equal-width slot (including its whitespace) is actually tappable.
            .frame(minWidth: 44, maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .disabled(!canInteract)
        .tint(.orange).foregroundStyle(.orange)
        .accessibilityLabel(queued ? "当前视频已加入待删除列表，点击查看提示" : "将当前视频加入待删除列表")
        .accessibilityValue(queued ? "待删除" : "未标记")
        .accessibilityHint("仅标记；回到本地列表点击删除待删除，确认后才会删除手机副本")
        .accessibilityIdentifier("watchDeleteButton")
    }
    private var playlistSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text("按打开视频时的筛选列表顺序播放，播完自动播放下一条，最后一条播完后停止。也可使用上一个、下一个按钮或点选条目切换。收藏和已看状态的变化不会改变本次播放顺序；缺失或无效的相邻视频会跳过。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(playlist.entries) { record in
                    Button {
                        guard scenePhase == .active else { return }
                        if playlist.select(record.id) { showsPlaylist = false }
                    } label: {
                        HStack {
                            Image(systemName: record.id == request.key ? "play.fill" : "film")
                            Text(record.video.name).lineLimit(2)
                            Spacer(minLength: 4)
                            if record.isFavorite {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                                    .accessibilityLabel("已收藏")
                            }
                            if record.pendingDeletionOrder != nil { Image(systemName: "trash").foregroundStyle(.orange) }
                        }.padding(.vertical, 4)
                    }.accessibilityIdentifier("playlistItem_" + record.id)
                }
                if let notice = playlist.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("本地播放列表")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showsPlaylist = false } } }
        }
    }
    private func revealControls() { controls.interacted(at: now) }
    private func resolveCompatibleSelection() {
        let resume = resumeAfterCopyPicker
        resumeAfterCopyPicker = false
        guard let selection = compatibleSelection else {
            if resume && scenePhase == .active && model.phase == .paused { model.toggle() }
            return
        }
        compatibleSelection = nil
        let old = request
        preparingCompatibleCopy = Task { @MainActor in
            defer { preparingCompatibleCopy = nil }
            do {
                let file = try await PickedVideoFile.open(selection)
                try Task.checkCancellation()
                guard request.id == old.id else { return }
                try store.queueCompatibleCopy(file, replacing: old)
                preparingCompatibleCopy = nil
                closePlayback()
                dismiss()
            } catch {
                guard !Task.isCancelled, request.id == old.id else { return }
                store.errorMessage = error.localizedDescription
                if resume && scenePhase == .active && model.phase == .paused { model.toggle() }
            }
        }
    }

    private func closePlayback() {
        preparingCompatibleCopy?.cancel()
        camera.connect(to: nil, followHead: false)
        cancelProgressInteraction()
        controls.stop()
        playlist.close()
    }
}

#if DEBUG
// The UI-test fixture uses the production player hierarchy and a deterministic
// engine, so real touch tests cover overlays, fullscreen and playlist changes.
@MainActor struct PlaybackUITestPlayerView: View {
    @ObservedObject var playlist: PlaylistPlaybackModel
    var body: some View {
        PlaylistPlayerView(playlist: playlist, model: playlist.player)
    }
}
#endif
