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
    @StateObject private var model: PlaybackModel
    @State private var scrubbing = false
    @State private var draftSeconds: Double = 0
    private let request: PlaybackRequest
    init(request: PlaybackRequest) {
        self.request = request
        _model = StateObject(wrappedValue: PlaybackModel(request: request))
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                VLCVideoSurface(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("offlineVideoSurface")
                    .overlay(alignment: .center) { WatchDeleteButton(videoID: request.key) }
                if model.phase == .opening { ProgressView("打开本地文件…") }
                if let notice = store.deletionNotice {
                    Text(notice).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                }
                if let message = model.message {
                    Text(message).font(.footnote).foregroundStyle(.red).padding(.horizontal)
                }
                VStack(spacing: 10) {
                    Slider(value: Binding(
                        get: { scrubbing ? draftSeconds : model.seconds },
                        set: { draftSeconds = $0 }
                    ), in: 0...max(1, model.duration), onEditingChanged: { editing in
                        if editing { draftSeconds = model.seconds }
                        else { model.seek(to: draftSeconds) }
                        scrubbing = editing
                    })
                    .disabled(!model.seekable)
                    .accessibilityLabel("播放进度")
                    HStack {
                        Text(PlaybackPosition.label(scrubbing ? draftSeconds : model.seconds))
                        Spacer()
                        Text(PlaybackPosition.label(model.duration))
                    }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    HStack(spacing: 44) {
                        Button { model.seek(to: model.seconds - 15) } label: { Image(systemName: "gobackward.15") }
                            .disabled(!model.seekable).accessibilityLabel("后退15秒")
                        Button { model.toggle() } label: {
                            Image(systemName: model.phase == .playing ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 44))
                        }.disabled(model.phase == .failed || model.phase == .idle)
                            .accessibilityLabel(model.phase == .playing ? "暂停" : "播放")
                        Button { model.seek(to: model.seconds + 15) } label: { Image(systemName: "goforward.15") }
                            .disabled(!model.seekable).accessibilityLabel("前进15秒")
                    }.font(.title2)
                    Text("手机本地文件 · VLC · 不使用在线播放")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding([.horizontal, .bottom])
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { closePlayback(); dismiss() }
                }
            }
        }
        .alert("操作提示", isPresented: Binding(
            get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } }
        )) { Button("确定", role: .cancel) { store.errorMessage = nil } }
        message: { Text(store.errorMessage ?? "") }
        .onChange(of: scenePhase) { _, phase in
            // No hidden audio/background video: resuming is an explicit user action.
            if phase != .active { model.pause() }
        }
        .onDisappear { closePlayback() }
    }
    private func closePlayback() {
        model.close()
        store.playbackDidClose(request)
    }
}
