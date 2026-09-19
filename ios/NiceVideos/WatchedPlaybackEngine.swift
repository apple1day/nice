import UIKit

// Decorates the existing engine without changing decoding or seeking. Forward
// the update first: PlaybackModel can reject a late playing event by pausing it.
final class WatchedPlaybackEngine: LocalPlaybackEngine {
    var onUpdate: ((PlaybackSnapshot) -> Void)?
    private let base: LocalPlaybackEngine
    private let didPlay: () -> Void
    private var gate = PlaybackWatchGate()
    private var allowed = false
    private var stopped = false

    init(base: LocalPlaybackEngine, didPlay: @escaping () -> Void) {
        self.base = base
        self.didPlay = didPlay
        base.onUpdate = { [weak self] snapshot in
            guard let self = self, !self.stopped else { return }
            self.onUpdate?(snapshot)
            if self.gate.consume(isPlaying: snapshot.phase == .playing,
                                 hasVideo: snapshot.hasVideo,
                                 allowed: self.allowed && !self.stopped) {
                self.didPlay()
            }
        }
    }
    func attach(to view: UIView) { if !stopped { base.attach(to: view) } }
    func load(fileURL: URL) throws { try base.load(fileURL: fileURL) }
    func play() { guard !stopped else { return }; allowed = true; base.play() }
    func pause() { guard !stopped else { return }; allowed = false; base.pause() }
    func seek(to seconds: Double) { if !stopped { base.seek(to: seconds) } }
    func stop() {
        guard !stopped else { return }
        stopped = true
        allowed = false
        onUpdate = nil
        base.onUpdate = nil
        base.stop()
    }
    deinit { stop() }
}
