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
        if snapshot.phase == .playing && pauseRequested {
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

private struct PageDragState: Equatable {
    var active = false
    var offset: CGFloat = 0
}

private struct PlaylistPlayerView: View {
    @EnvironmentObject private var store: VideoStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @ObservedObject var playlist: PlaylistPlaybackModel
    @ObservedObject var model: PlaybackModel
    @State private var controls = PlaybackControlsState()
    @State private var draftSeconds: Double = 0
    @State private var showsPlaylist = false
    @GestureState private var pageDrag = PageDragState()
    @State private var settledPageOffset: CGFloat = 0
    @State private var pageAnimating = false
    private var request: PlaybackRequest { playlist.current }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var hasMessage: Bool { store.errorMessage != nil || model.message != nil || showsPlaylist }
    private var showsPause: Bool { model.phase == .playing || model.phase == .opening }
    private var canNavigate: Bool {
        scenePhase == .active && !controls.isScrubbing && store.errorMessage == nil &&
        !showsPlaylist && !pageAnimating
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let viewportHeight = max(proxy.size.height, 1)
                let pageOffset = pageAnimating ? settledPageOffset : pageDrag.offset
                ZStack {
                    Color.black.ignoresSafeArea()

                    if let previous = playlist.neighbor(.previous) {
                        pagingPreview(record: previous, label: "上一个视频")
                            .offset(y: -viewportHeight + pageOffset)
                    }
                    if let next = playlist.neighbor(.next) {
                        pagingPreview(record: next, label: "下一个视频")
                            .offset(y: viewportHeight + pageOffset)
                    }

                    VLCVideoSurface(model: model)
                        .id(request.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea(.container, edges: controls.isFullscreen ? .all : [])
                        .offset(y: pageOffset)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("offlineVideoSurface")

                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .gesture(surfaceGesture(viewportHeight: viewportHeight))
                        .accessibilityElement()
                        .accessibilityLabel("视频画面，上滑下一个，下滑上一个")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { toggleControls() }
                        .accessibilityAction(named: Text("上一个视频")) { navigate(.previous) }
                        .accessibilityAction(named: Text("下一个视频")) { navigate(.next) }
                        .accessibilityIdentifier("playbackSurfaceToggle")
                }
                .clipped()
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
            draftSeconds = 0
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                settledPageOffset = 0
                pageAnimating = false
            }
            controls.setScrubbing(false, at: now)
            controls.setNavigating(false, at: now)
            controls.setPlaying(model.phase == .playing, at: now)
            controls.interacted(at: now)
            if scenePhase != .active { model.pause() }
        }
        .onChange(of: model.phase, initial: true) { _, phase in
            controls.setPlaying(phase == .playing, at: now)
        }
        .onChange(of: pageDrag.active) { _, value in controls.setNavigating(value || pageAnimating, at: now) }
        .onChange(of: hasMessage, initial: true) { _, value in controls.setPresentingAlert(value, at: now) }
        .onChange(of: voiceOverEnabled, initial: true) { _, value in controls.setVoiceOverEnabled(value, at: now) }
        .onChange(of: scenePhase, initial: true) { _, phase in
            controls.setSceneActive(phase == .active, at: now)
            if phase != .active {
                model.pause()
                resetPagingImmediately()
            }
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

    private func surfaceGesture(viewportHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($pageDrag) { value, state, _ in
                guard canNavigate else { return }
                state.active = true
                state.offset = CGFloat(PlaylistSwipe.interactiveOffset(
                    horizontal: Double(value.translation.width),
                    vertical: Double(value.translation.height),
                    viewportHeight: Double(viewportHeight),
                    hasPrevious: playlist.canMove(.previous),
                    hasNext: playlist.canMove(.next)
                ))
            }
            .onEnded { value in
                finishPageSwipe(value, viewportHeight: viewportHeight)
            }
            .exclusively(before: TapGesture().onEnded { _ in toggleControls() })
    }

    private func finishPageSwipe(_ value: DragGesture.Value, viewportHeight: CGFloat) {
        controls.setNavigating(false, at: now)
        guard canNavigate else { return }

        let currentOffset = CGFloat(PlaylistSwipe.interactiveOffset(
            horizontal: Double(value.translation.width),
            vertical: Double(value.translation.height),
            viewportHeight: Double(viewportHeight),
            hasPrevious: playlist.canMove(.previous),
            hasNext: playlist.canMove(.next)
        ))
        let direction = PlaylistSwipe.pagingDirection(
            horizontal: Double(value.translation.width),
            vertical: Double(value.translation.height),
            predictedVertical: Double(value.predictedEndTranslation.height),
            viewportHeight: Double(viewportHeight)
        )

        guard let direction else {
            animatePageBack(from: currentOffset)
            return
        }
        guard playlist.canMove(direction) else {
            _ = playlist.move(direction)
            animatePageBack(from: currentOffset)
            return
        }

        pageAnimating = true
        settledPageOffset = currentOffset
        let target = direction == .next ? -viewportHeight : viewportHeight
        controls.setNavigating(true, at: now)
        withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.94, blendDuration: 0.04)) {
            settledPageOffset = target
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            guard pageAnimating else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                _ = playlist.move(direction)
                settledPageOffset = 0
                pageAnimating = false
            }
            controls.setNavigating(false, at: now)
            revealControls()
        }
    }

    private func animatePageBack(from offset: CGFloat) {
        pageAnimating = true
        settledPageOffset = offset
        controls.setNavigating(true, at: now)
        withAnimation(.spring(response: 0.30, dampingFraction: 0.82, blendDuration: 0.05)) {
            settledPageOffset = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            pageAnimating = false
            controls.setNavigating(false, at: now)
            revealControls()
        }
    }

    private func resetPagingImmediately() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            settledPageOffset = 0
            pageAnimating = false
        }
        controls.setNavigating(false, at: now)
    }

    private func pagingPreview(record: DownloadRecord, label: String) -> some View {
        ZStack {
            Color.black
            LinearGradient(
                colors: [.black.opacity(0.3), .secondary.opacity(0.18), .black.opacity(0.75)],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(spacing: 14) {
                Image(systemName: "film.stack")
                    .font(.system(size: 48, weight: .medium))
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(record.video.name)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 32)
            }
            .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { controls.surfaceTapped(at: now) }
    }
    private func navigate(_ direction: LocalPlaybackPlaylist.Direction) {
        guard canNavigate else { return }
        playlist.move(direction)
        revealControls()
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
                Text("上滑下一个 · 下滑上一个").font(.caption2)
                Spacer(minLength: 4)
                Button { revealControls(); showsPlaylist = true } label: {
                    Label(playlist.positionLabel, systemImage: "list.bullet")
                        .font(.caption.monospacedDigit()).padding(.vertical, 8)
                }.accessibilityLabel("本地播放列表 \(playlist.positionLabel)")
                    .accessibilityIdentifier("openLocalPlaylistButton")
            }
            Slider(value: Binding(
                get: { min(max(0, controls.isScrubbing ? draftSeconds : model.seconds), max(1, model.duration)) },
                set: { draftSeconds = $0 }
            ), in: 0...max(1, model.duration), onEditingChanged: { editing in
                if editing { draftSeconds = model.seconds }
                else { model.seek(to: draftSeconds) }
                controls.setScrubbing(editing, at: now)
            })
            .tint(.white).disabled(!model.seekable)
            .accessibilityLabel("播放进度").accessibilityIdentifier("playbackProgressSlider")
            HStack {
                Text(PlaybackPosition.label(controls.isScrubbing ? draftSeconds : model.seconds))
                Spacer()
                Text(PlaybackPosition.label(model.duration))
            }.font(.caption.monospacedDigit())
            HStack(spacing: 0) {
                if isLandscape {
                    Button { navigate(.previous) } label: {
                        Image(systemName: "backward.end.fill").frame(width: 44, height: 52)
                    }
                    .accessibilityLabel("上一个视频")
                    .accessibilityIdentifier("previousVideoButton")
                    .frame(minWidth: 0, maxWidth: .infinity)
                }
                Button { revealControls(); model.seek(to: model.seconds - 15) } label: {
                    Image(systemName: "gobackward.15").frame(width: 44, height: 52)
                }.disabled(!model.seekable).accessibilityLabel("后退15秒")
                    .frame(minWidth: 0, maxWidth: .infinity)
                Button { revealControls(); model.toggle() } label: {
                    Image(systemName: showsPause ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 38)).frame(width: 44, height: 52)
                }.disabled(model.phase == .failed || model.phase == .idle)
                    .accessibilityLabel(showsPause ? "暂停" : "播放")
                    .accessibilityIdentifier("togglePlaybackButton")
                    .frame(minWidth: 0, maxWidth: .infinity)
                transportDeleteButton.frame(minWidth: 0, maxWidth: .infinity)
                Button { revealControls(); model.seek(to: model.seconds + 15) } label: {
                    Image(systemName: "goforward.15").frame(width: 44, height: 52)
                }.disabled(!model.seekable).accessibilityLabel("前进15秒")
                    .frame(minWidth: 0, maxWidth: .infinity)
                if isLandscape {
                    Button { navigate(.next) } label: {
                        Image(systemName: "forward.end.fill").frame(width: 44, height: 52)
                    }
                    .accessibilityLabel("下一个视频")
                    .accessibilityIdentifier("nextVideoButton")
                    .frame(minWidth: 0, maxWidth: .infinity)
                }
                Button { controls.toggleFullscreen(at: now) } label: {
                    Image(systemName: controls.isFullscreen
                          ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .frame(width: 44, height: 52)
                }.accessibilityLabel(controls.isFullscreen ? "退出全屏" : "全屏播放")
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
    private var transportDeleteButton: some View {
        let queued = store.isPendingDeletion(request.key)
        return Button {
            revealControls()
            if !queued { store.markForDeletion(request.key) }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: queued ? "checkmark.circle.fill" : "trash").font(.title2)
                Text("删除").font(.caption2).lineLimit(1)
            }.frame(minWidth: 44, minHeight: 52)
        }
        .disabled(queued)
        .tint(.orange).foregroundStyle(.orange)
        .accessibilityLabel(queued ? "当前视频已加入待删除列表" : "将当前视频加入待删除列表")
        .accessibilityIdentifier("watchDeleteButton")
    }
    private var playlistSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text("本次打开时的全部本地视频，按本地列表顺序播放。上滑下一个，下滑上一个；横屏控制栏也可直接切换上一个和下一个。")
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
                            if store.isPendingDeletion(record.id) { Image(systemName: "trash").foregroundStyle(.orange) }
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
    private func closePlayback() {
        resetPagingImmediately()
        controls.stop()
        playlist.close()
    }
}
