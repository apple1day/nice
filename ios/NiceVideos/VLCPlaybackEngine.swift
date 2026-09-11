import Foundation
import UIKit
import MobileVLCKit

enum PlaybackPhase: Equatable { case idle, opening, playing, paused, ended, failed }
struct PlaybackSnapshot {
    var phase: PlaybackPhase
    var seconds: Double = 0
    var duration: Double = 0
    var seekable = false
    var hasVideo = false
    var error: String?
}

// UIKit/VLC details are isolated; state/position/lifecycle tests use a fake engine.
protocol LocalPlaybackEngine: AnyObject {
    var onUpdate: ((PlaybackSnapshot) -> Void)? { get set }
    func attach(to view: UIView)
    func load(fileURL: URL) throws
    func play()
    func pause()
    func seek(to seconds: Double)
    func stop()
}

final class VLCPlaybackEngine: NSObject, LocalPlaybackEngine, VLCMediaPlayerDelegate {
    var onUpdate: ((PlaybackSnapshot) -> Void)?
    private let player = VLCMediaPlayer(options: ["--no-video-title-show", "--no-metadata-network-access"])
    private var stopped = false
    private var loaded = false

    override init() {
        super.init()
        player.delegate = self
    }
    func attach(to view: UIView) {
        guard !stopped else { return }
        player.drawable = view
    }
    func load(fileURL: URL) throws {
        guard !stopped else { throw ClientError("播放器已关闭，请重新打开视频。") }
        // Check again immediately before giving VLC a file, even for non-store callers.
        try OfflineMediaPolicy.validateLocalFile(fileURL)
        player.media = VLCMedia(path: fileURL.path)
        loaded = true
    }
    func play() { if loaded && !stopped { player.play() } }
    func pause() { if loaded && !stopped { player.pause() } }
    func seek(to seconds: Double) {
        let duration = Double(player.media?.length.intValue ?? 0) / 1000
        guard !stopped, player.isSeekable,
              let seconds = PlaybackPosition.clamp(seconds, duration: duration) else { return }
        // Fractional seeking avoids the Int32 millisecond limit for long media.
        player.position = Float(seconds / duration)
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        player.delegate = nil
        onUpdate = nil
        if loaded { player.stop() }
        player.drawable = nil
        player.media = nil
    }
    func mediaPlayerStateChanged(_ aNotification: Notification) { publish() }
    func mediaPlayerTimeChanged(_ aNotification: Notification) { publish() }
    private func publish() {
        // Do not mutate SwiftUI state during UIViewRepresentable updates or off-main.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.stopped else { return }
            let phase: PlaybackPhase
            switch self.player.state {
            case .playing: phase = .playing
            case .paused: phase = .paused
            case .ended: phase = .ended
            case .error: phase = .failed
            case .stopped: phase = .idle
            default: phase = self.player.isPlaying ? .playing : .opening
            }
            self.onUpdate?(PlaybackSnapshot(
                phase: phase,
                seconds: max(0, Double(self.player.time.intValue) / 1000),
                duration: max(0, Double(self.player.media?.length.intValue ?? 0) / 1000),
                seekable: self.player.isSeekable,
                hasVideo: self.player.hasVideoOut,
                error: phase == .failed ? "VLC 无法解码这个本地文件。请检查文件是否损坏、编码是否受支持，必要时重新下载。" : nil
            ))
        }
    }
    deinit { stop() }
}
