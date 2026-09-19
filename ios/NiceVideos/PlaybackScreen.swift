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
                restoredPosition = true
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
        let nextPhase: PlaybackPhase
        if snapshot.phase == .playing && pauseRequested {
            engine.pause()
            nextPhase = .paused
        } else {
            nextPhase = snapshot.phase
        }
        // Avoid publishing unchanged phase/duration/flags on every time callback.
        if phase != nextPhase { phase = nextPhase }
        let nextSeconds = snapshot.seconds.isFinite ? max(0, snapshot.seconds) : 0
        let nextDuration = snapshot.duration.isFinite ? max(0, snapshot.duration) : 0
        let nextSeekable = snapshot.seekable && nextDuration > 0
        if seconds != nextSeconds { seconds = nextSeconds }
        if duration != nextDuration { duration = nextDuration }
        if seekable != nextSeekable { seekable = nextSeekable }
        if message != snapshot.error { message = snapshot.error }
        if manageAudioSession {
            let disabled = phase == .playing ? true : previousIdleTimer
            if UIApplication.shared.isIdleTimerDisabled != disabled {
                UIApplication.shared.isIdleTimerDisabled = disabled
            }
        }
        if phase == .ended {
            defaults.removeObject(forKey: key)
            restoredPosition = true
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
        DispatchQueue.main.async { [weak model, weak view] in
            if let view = view { model?.attach(to: view) }
        }
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
    static func dismantleUIView(_ view: UIView, coordinator: PlaybackModel) { coordinator.close() }
}

// The drag draft belongs to this small view, not the whole player. No store,
// playlist traversal or file validation is reachable from the Slider binding.
private struct PlaybackProgressView: View {
    @ObservedObject var model: PlaybackModel
    let isEnabled: Bool
    let onEditingChanged: (Bool) -> Void
    @State private var draftSeconds: Double?
    private var displayedSeconds: Double { draftSeconds ?? model.seconds }

    var body: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(
                get: { min(max(0, displayedSeconds), max(1, model.duration)) },
                set: { draftSeconds = $0 }
            ), in: 0...max(1, model.duration), onEditingChanged: { editing in
                if !editing {
                    if isEnabled, let target = draftSeconds { model.seek(to: target) }
                    draftSeconds = nil
                }
                onEditingChanged(editing && isEnabled)
            })
            .tint(.white).disabled(!isEnabled || !model.seekable)
            .accessibilityLabel("播放进度").accessibilityIdentifier("playbackProgressSlider")
            HStack {
                Text(PlaybackPosition.label(displayedSeconds))
                Spacer()
                Text(PlaybackPosition.label(model.duration))
            }.font(.caption.monospacedDigit())
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { draftSeconds = nil; onEditingChanged(false) }
        }
        .onDisappear { draftSeconds = nil; onEditingChanged(false) }
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

private struct PlaylistPlayerView: View {
    @EnvironmentObject private var store: VideoStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @ObservedObject var playlist: PlaylistPlaybackModel
    @ObservedObject var model: PlaybackModel
    @State private var controls = PlaybackControlsState()
    @State private var showsPlaylist = false
    private var request: PlaybackRequest { playlist.current }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var hasMessage: Bool { store.errorMessage != nil || model.message != nil || showsPlaylist }
    private var showsPause: Bool { model.phase == .playing || model.phase == .opening }
    private var canInteract: Bool { scenePhase == .active && store.errorMessage == nil && !showsPlaylist }
    private var canNavigate: Bool { canInteract && !controls.isScrubbing }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ZStack {
                    Color.black.ignoresSafeArea()
                    VLCVideoSurface(model: model)
                        .id(request.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea(.container, edges: controls.isFullscreen ? .all : [])
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("offlineVideoSurface")
                    // Tap-only surface: no vertical paging, previews or delayed switches.
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .onTapGesture { toggleControls() }
                        .accessibilityElement()
                        .accessibilityLabel("视频画面，轻点显示或隐藏控制栏")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { toggleControls() }
                        .accessibilityAction(named: Text("上一个视频")) { navigate(.previous) }
                        .accessibilityAction(named: Text("下一个视频")) { navigate(.next) }
                        .accessibilityIdentifier("playbackSurfaceToggle")
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
                    transportControls(isLandscape: proxy.size.width > proxy.size.height)
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
        .sheet(isPresented: $showsPlaylist) { playlistSheet }
        .alert("操作提示", isPresented: Binding(
            get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } }
        )) { Button("确定", role: .cancel) { store.errorMessage = nil } }
        message: { Text(store.errorMessage ?? "") }
        .onChange(of: request.id) { _, _ in
            controls.setScrubbing(false, at: now)
            controls.setPlaying(model.phase == .playing, at: now)
            controls.interacted(at: now)
            if scenePhase != .active { model.pause() }
        }
        .onChange(of: model.phase, initial: true) { _, phase in
            controls.setPlaying(phase == .playing, at: now)
        }
        .onChange(of: hasMessage, initial: true) { _, value in controls.setPresentingAlert(value, at: now) }
        .onChange(of: voiceOverEnabled, initial: true) { _, value in controls.setVoiceOverEnabled(value, at: now) }
        .onChange(of: scenePhase, initial: true) { _, phase in
            controls.setSceneActive(phase == .active, at: now)
            if phase != .active { model.pause() }
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
        guard canNavigate else { return }
        playlist.move(direction)
        revealControls()
    }
    private func navigationButton(_ direction: LocalPlaybackPlaylist.Direction, compact: Bool) -> some View {
        let previous = direction == .previous
        return Button { navigate(direction) } label: {
            if compact {
                Image(systemName: previous ? "backward.end.fill" : "forward.end.fill")
                    .frame(width: 44, height: 52)
            } else {
                Label(previous ? "上一个" : "下一个", systemImage: previous ? "backward.end.fill" : "forward.end.fill")
                    .font(.caption).frame(minHeight: 44)
            }
        }
        .disabled(!canNavigate || !playlist.canMove(direction))
        .accessibilityLabel(previous ? "上一个视频" : "下一个视频")
        .accessibilityIdentifier(previous ? "previousVideoButton" : "nextVideoButton")
    }
    private var fullscreenHeader: some View {
        HStack(spacing: 12) {
            Text(request.title).font(.headline).lineLimit(1)
            Spacer(minLength: 4)
            Button { closePlayback(); dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                .accessibilityLabel("关闭播放器").accessibilityIdentifier("closeFullscreenPlayer")
        }
        .foregroundStyle(.white).padding(.horizontal, 16)
        .background(LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom))
        .contentShape(Rectangle())
    }
    private func transportControls(isLandscape: Bool) -> some View {
        VStack(spacing: 4) {
            if model.phase == .opening { ProgressView("打开本地文件…").tint(.white).font(.caption) }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.red).lineLimit(2) }
            if let notice = playlist.notice { Text(notice).font(.caption).lineLimit(2) }
            if let notice = store.deletionNotice { Text(notice).font(.caption2).lineLimit(2) }
            HStack(spacing: 8) {
                if !isLandscape { navigationButton(.previous, compact: false) }
                Spacer(minLength: 4)
                Button { revealControls(); showsPlaylist = true } label: {
                    Label(playlist.positionLabel, systemImage: "list.bullet")
                        .font(.caption.monospacedDigit()).padding(.vertical, 8)
                }
                .disabled(!canNavigate)
                .accessibilityLabel("本地播放列表 \(playlist.positionLabel)")
                .accessibilityIdentifier("openLocalPlaylistButton")
                Spacer(minLength: 4)
                if !isLandscape { navigationButton(.next, compact: false) }
            }
            PlaybackProgressView(model: model, isEnabled: canInteract) { editing in
                controls.setScrubbing(editing, at: now)
            }.id(request.id)
            HStack(spacing: 0) {
                if isLandscape {
                    navigationButton(.previous, compact: true).frame(minWidth: 0, maxWidth: .infinity)
                }
                Button { revealControls(); model.seek(to: model.seconds - 15) } label: {
                    Image(systemName: "gobackward.15").frame(width: 44, height: 52)
                }.disabled(!model.seekable || !canNavigate).accessibilityLabel("后退15秒")
                    .frame(minWidth: 0, maxWidth: .infinity)
                Button { revealControls(); model.toggle() } label: {
                    Image(systemName: showsPause ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 38)).frame(width: 44, height: 52)
                }.disabled(model.phase == .failed || model.phase == .idle || !canNavigate)
                    .accessibilityLabel(showsPause ? "暂停" : "播放")
                    .accessibilityIdentifier("togglePlaybackButton")
                    .frame(minWidth: 0, maxWidth: .infinity)
                transportFavoriteButton.frame(minWidth: 0, maxWidth: .infinity)
                transportDeleteButton.frame(minWidth: 0, maxWidth: .infinity)
                Button { revealControls(); model.seek(to: model.seconds + 15) } label: {
                    Image(systemName: "goforward.15").frame(width: 44, height: 52)
                }.disabled(!model.seekable || !canNavigate).accessibilityLabel("前进15秒")
                    .frame(minWidth: 0, maxWidth: .infinity)
                if isLandscape {
                    navigationButton(.next, compact: true).frame(minWidth: 0, maxWidth: .infinity)
                }
                Button { controls.toggleFullscreen(at: now) } label: {
                    Image(systemName: controls.isFullscreen
                          ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .frame(width: 44, height: 52)
                }.disabled(!canNavigate)
                    .accessibilityLabel(controls.isFullscreen ? "退出全屏" : "全屏播放")
                    .accessibilityValue(controls.isFullscreen ? "全屏" : "普通")
                    .accessibilityIdentifier("toggleFullscreenButton")
                    .frame(minWidth: 0, maxWidth: .infinity)
            }.font(.title2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
        .contentShape(Rectangle())
        .onTapGesture { revealControls() }
        .accessibilityIdentifier("playbackTransportControls")
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
            }.frame(minWidth: 44, minHeight: 52)
        }
        .disabled(!canNavigate)
        .foregroundStyle(favorite ? Color.yellow : Color.white)
        .accessibilityLabel(favorite ? "取消收藏当前视频" : "收藏当前视频")
        .accessibilityValue(favorite ? "已收藏" : "未收藏")
        .accessibilityIdentifier("favoriteVideoButton")
    }

    private var transportDeleteButton: some View {
        let queued = playlist.currentEntry?.pendingDeletionOrder != nil
        return Button {
            revealControls()
            if !queued { store.markForDeletion(request.key) }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: queued ? "checkmark.circle.fill" : "trash").font(.title2)
                Text("删除").font(.caption2).lineLimit(1)
            }.frame(minWidth: 44, minHeight: 52)
        }
        .disabled(queued || !canNavigate)
        .tint(.orange).foregroundStyle(.orange)
        .accessibilityLabel(queued ? "当前视频已加入待删除列表" : "将当前视频加入待删除列表")
        .accessibilityIdentifier("watchDeleteButton")
    }
    private var playlistSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text("按本地列表顺序播放。使用上一个、下一个按钮或点选条目切换；上下滑不再切换视频。只有切换时才检查目标文件，缺失或无效的相邻视频会跳过。")
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
    private func closePlayback() { controls.stop(); playlist.close() }
}
