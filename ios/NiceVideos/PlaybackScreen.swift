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
    @Published private(set) var message: String?
    private let request: PlaybackRequest
    private let engine: LocalPlaybackEngine
    private let defaults: UserDefaults
    private let manageAudioSession: Bool
    private var started = false
    private var pauseRequested = false
    private var closed = false
    private var restoredPosition = false
    private var lastSave = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private var previousIdleTimer = false
    private var key: String { "position." + request.key }

    init(request: PlaybackRequest, engine: LocalPlaybackEngine? = nil,
         defaults: UserDefaults = .standard, manageAudioSession: Bool = true) {
        self.request = request
        self.engine = engine ?? VLCPlaybackEngine()
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
            if phase == .ended {
                seconds = 0
                restoredPosition = true // Replay must not reapply a saved bookmark.
            }
            engine.play()
        } catch { message = error.localizedDescription }
    }
    func pause() {
        guard !closed else { return }
        pauseRequested = true
        guard started else { return }
        savePosition()
        engine.pause()
        if phase == .playing || phase == .opening { phase = .paused }
        if manageAudioSession { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
    }
    func seek(to value: Double) {
        guard !closed, seekable, let value = PlaybackPosition.clamp(value, duration: duration) else { return }
        restoredPosition = true
        seconds = value
        engine.seek(to: value)
        savePosition()
    }
    private func receive(_ snapshot: PlaybackSnapshot) {
        guard !closed else { return }
        if snapshot.phase == .playing && pauseRequested {
            // A background/interruption pause can arrive while VLC is still opening.
            // Apply it again when the native engine becomes ready instead of leaking audio.
            engine.pause()
            phase = .paused
        } else {
            phase = snapshot.phase
        }
        seconds = snapshot.seconds.isFinite ? max(0, snapshot.seconds) : 0
        duration = snapshot.duration.isFinite ? max(0, snapshot.duration) : 0
        seekable = snapshot.seekable && duration > 0
        message = snapshot.error
        if manageAudioSession {
            UIApplication.shared.isIdleTimerDisabled = phase == .playing ? true : previousIdleTimer
        }
        if phase == .ended {
            defaults.removeObject(forKey: key)
            restoredPosition = true
            return
        }
        // Wait for both duration and seekability. Never overwrite the old bookmark
        // with 0 while VLC is still opening or while a failed file is being closed.
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
    private func savePosition() {
        guard restoredPosition, phase != .ended, phase != .failed,
              seconds.isFinite, seconds >= 0 else { return }
        defaults.set(seconds, forKey: key)
        lastSave = Date()
    }
    func close() {
        guard !closed else { return }
        savePosition()
        closed = true // Drop late VLC events before stopping native output.
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

private struct VLCVideoSurface: UIViewRepresentable {
    let model: PlaybackModel
    func makeCoordinator() -> PlaybackModel { model }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        // SwiftUI must finish mounting the drawable before playback begins.
        DispatchQueue.main.async { [weak model, weak view] in
            if let view = view { model?.attach(to: view) }
        }
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
    static func dismantleUIView(_ view: UIView, coordinator: PlaybackModel) { coordinator.close() }
}

struct PlaybackScreen: View {
    @EnvironmentObject private var store: VideoStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @StateObject private var model: PlaybackModel
    @State private var controls = PlaybackControlsState()
    @State private var draftSeconds: Double = 0
    private let request: PlaybackRequest
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var hasMessage: Bool { store.errorMessage != nil || model.message != nil }
    private var showsPause: Bool { model.phase == .playing || model.phase == .opening }

    init(request: PlaybackRequest) {
        self.request = request
        _model = StateObject(wrappedValue: PlaybackModel(request: request))
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                // Keep ONE drawable at the same structural position. Fullscreen and
                // auto-hide only change layout/overlays: never close or reload VLC.
                ZStack {
                    Color.black.ignoresSafeArea()
                    VLCVideoSurface(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea(.container, edges: controls.isFullscreen ? .all : [])
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("offlineVideoSurface")
                    // Sibling below the controls, not a parent gesture: pressing a
                    // button/dragging the slider cannot also toggle the whole HUD.
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { controls.surfaceTapped(at: now) }
                    } label: {
                        Rectangle().fill(Color.clear).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(controls.isVisible ? "隐藏播放控制" : "显示播放控制")
                    .accessibilityIdentifier("playbackSurfaceToggle")
                    WatchDeleteButton(videoID: request.key, compact: geometry.size.height < 420,
                                      onInteraction: revealControls)
                        .opacity(controls.isVisible ? 1 : 0)
                        .allowsHitTesting(controls.isVisible)
                        .accessibilityHidden(!controls.isVisible)
                }
                .overlay(alignment: .top) {
                    if controls.isFullscreen {
                        fullscreenHeader
                            .opacity(controls.isVisible ? 1 : 0)
                            .allowsHitTesting(controls.isVisible)
                            .accessibilityHidden(!controls.isVisible)
                    }
                }
                .overlay(alignment: .bottom) {
                    transportControls
                        .opacity(controls.isVisible ? 1 : 0)
                        .allowsHitTesting(controls.isVisible)
                        .accessibilityHidden(!controls.isVisible)
                }
            }
            .background(.black)
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(controls.isFullscreen ? .hidden : .visible, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { closePlayback(); dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(controls.isFullscreen)
        .persistentSystemOverlays(controls.isFullscreen && !controls.isVisible ? .hidden : .automatic)
        .alert("操作提示", isPresented: Binding(
            get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } }
        )) { Button("确定", role: .cancel) { store.errorMessage = nil } }
        message: { Text(store.errorMessage ?? "") }
        .onChange(of: model.phase, initial: true) { _, phase in
            controls.setPlaying(phase == .playing, at: now)
        }
        .onChange(of: hasMessage, initial: true) { _, value in
            controls.setPresentingAlert(value, at: now)
        }
        .onChange(of: voiceOverEnabled, initial: true) { _, value in
            controls.setVoiceOverEnabled(value, at: now)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            controls.setSceneActive(phase == .active, at: now)
            // No hidden audio/background video: resuming is an explicit action.
            if phase != .active { model.pause() }
        }
        .task(id: controls.hideDeadline) {
            guard let deadline = controls.hideDeadline else { return }
            let delay = min(60, max(0, deadline - now))
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                controls.hideIfDue(at: now, deadline: deadline)
            }
        }
        .onDisappear { closePlayback() }
    }

    private var fullscreenHeader: some View {
        HStack(spacing: 12) {
            Text(request.title).font(.headline).lineLimit(1)
            Spacer(minLength: 4)
            Button { closePlayback(); dismiss() } label: {
                Image(systemName: "xmark").frame(width: 44, height: 44)
            }.accessibilityLabel("关闭播放器").accessibilityIdentifier("closeFullscreenPlayer")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .background(LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var transportControls: some View {
        VStack(spacing: 4) {
            if model.phase == .opening {
                ProgressView("打开本地文件…").tint(.white).font(.caption)
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            if let notice = store.deletionNotice {
                Text(notice).font(.caption2).lineLimit(2)
            }
            Slider(value: Binding(
                get: { min(max(0, controls.isScrubbing ? draftSeconds : model.seconds), max(1, model.duration)) },
                set: { draftSeconds = $0 }
            ), in: 0...max(1, model.duration), onEditingChanged: { editing in
                if editing { draftSeconds = model.seconds }
                else { model.seek(to: draftSeconds) }
                controls.setScrubbing(editing, at: now)
            })
            .tint(.white)
            .disabled(!model.seekable)
            .accessibilityLabel("播放进度")
            .accessibilityIdentifier("playbackProgressSlider")
            HStack {
                Text(PlaybackPosition.label(controls.isScrubbing ? draftSeconds : model.seconds))
                Spacer()
                Text(PlaybackPosition.label(model.duration))
            }.font(.caption.monospacedDigit())
            HStack(spacing: 16) {
                Button { revealControls(); model.seek(to: model.seconds - 15) } label: {
                    Image(systemName: "gobackward.15").frame(width: 44, height: 44)
                }.disabled(!model.seekable).accessibilityLabel("后退15秒")
                Button { revealControls(); model.toggle() } label: {
                    Image(systemName: showsPause ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 40)).frame(width: 48, height: 48)
                }.disabled(model.phase == .failed || model.phase == .idle)
                    .accessibilityLabel(showsPause ? "暂停" : "播放")
                    .accessibilityIdentifier("togglePlaybackButton")
                Button { revealControls(); model.seek(to: model.seconds + 15) } label: {
                    Image(systemName: "goforward.15").frame(width: 44, height: 44)
                }.disabled(!model.seekable).accessibilityLabel("前进15秒")
                Spacer(minLength: 0)
                Button { controls.toggleFullscreen(at: now) } label: {
                    Image(systemName: controls.isFullscreen
                          ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(controls.isFullscreen ? "退出全屏" : "全屏播放")
                .accessibilityValue(controls.isFullscreen ? "全屏" : "普通")
                .accessibilityIdentifier("toggleFullscreenButton")
            }.font(.title2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 4)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
        .accessibilityIdentifier("playbackTransportControls")
    }

    private func revealControls() { controls.interacted(at: now) }
    private func closePlayback() {
        controls.stop()
        model.close()
        store.playbackDidClose(request)
    }
}
