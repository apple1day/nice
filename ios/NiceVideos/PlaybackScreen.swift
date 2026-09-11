import SwiftUI
import AVKit
import Combine

final class PlaybackModel: ObservableObject {
    let player: AVPlayer
    @Published var message: String?
    private let key: String
    private var observation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var restoredPosition = false

    init(request: PlaybackRequest) {
        key = "position." + request.key
        let item = AVPlayerItem(url: request.url)
        player = AVPlayer(playerItem: item)
        observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if item.status == .failed {
                    self.message = "播放失败。可能是编码不受设备支持、文件损坏或网络不可用。\n" + (item.error?.localizedDescription ?? "")
                } else if item.status == .readyToPlay && !self.restoredPosition {
                    self.restoredPosition = true
                    let position = UserDefaults.standard.double(forKey: self.key)
                    let duration = item.duration.seconds
                    if position > 1, duration.isFinite, position < duration - 3 {
                        self.player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
                    }
                }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 600),
                                                       queue: .main) { [weak self] _ in self?.savePosition() }
    }

    func start() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            player.play()
        } catch { message = "音频会话启动失败：\(error.localizedDescription)" }
    }

    private func savePosition() {
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds >= 0 else { return }
        UserDefaults.standard.set(seconds, forKey: key)
    }

    func stop() {
        savePosition()
        player.pause()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    deinit {
        observation?.invalidate()
        if let observer = timeObserver { player.removeTimeObserver(observer) }
    }
}

private struct NativePlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.showsPlaybackControls = true
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}

struct PlaybackScreen: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: PlaybackModel
    private let request: PlaybackRequest

    init(request: PlaybackRequest) {
        self.request = request
        _model = StateObject(wrappedValue: PlaybackModel(request: request))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let message = model.message {
                    Text(message).font(.footnote).padding()
                }
                NativePlayer(player: model.player)
                Text(request.url.isFileURL ? "正在播放手机本地文件" : "正在在线播放")
                    .font(.caption).foregroundStyle(.secondary).padding(8)
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } } }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}
