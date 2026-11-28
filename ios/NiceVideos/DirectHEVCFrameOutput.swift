import AVFoundation
import UIKit

// Display ticks and completions run on the main queue. Keep one pending
// request, so a decode that finishes just after vsync can start its successor
// immediately with the current audio time.
enum DirectHEVCReadDemand {
    case idle, reading, readingWithPendingTick

    mutating func beginRead() -> Bool {
        let idle = self == .idle
        self = idle ? .reading : .readingWithPendingTick
        return idle
    }

    mutating func finishRead() -> Bool {
        let pending = self == .readingWithPendingTick
        self = .idle
        return pending
    }
}

/// The AVPlayer audio item owns seeking and playback time. The serial reader
/// decodes references in DTS order; the renderer receives only pictures due now.
final class DirectHEVCFrameOutput: NSObject {
    private let reader: DirectHEVCReader
    private let queue = DispatchQueue(label: "NiceVideos.direct-hevc", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let clock: () -> (seconds: Double, playing: Bool)?
    private let minimumFPS: Double
    private let pictureTimeout: TimeInterval
    private let awaitingClock: () -> Bool
    private let deliver: (CVPixelBuffer, Double) -> Void
    private let fail: (String) -> Void
    private var displayLink: CADisplayLink?
    private var demand = DirectHEVCReadDemand.idle
    private var generation = 0
    private var checkpoint: (seconds: Double, frames: Int)?
    private var noProgressSince: CFTimeInterval?
    private var lastTick: CFTimeInterval?
    private(set) var frameCount = 0
    private(set) var hasFrame = false
    private(set) var deliveredFPS: Double?

    init(track: AVAssetTrack, asset: AVAsset, frameRate: Float?, clock: @escaping () -> (Double, Bool)?,
         awaitingClock: @escaping () -> Bool, deliver: @escaping (CVPixelBuffer, Double) -> Void, fail: @escaping (String) -> Void) {
        reader = DirectHEVCReader(track: track, asset: asset, requireHardware: true)
        let fps = Double(frameRate ?? 0)
        minimumFPS = fps.isFinite && fps > 0 ? min(8, fps / 2) : 8
        pictureTimeout = fps.isFinite && fps > 0 ? max(6, 3 / fps) : 6
        self.clock = clock
        self.awaitingClock = awaitingClock
        self.deliver = deliver
        self.fail = fail
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFramesPerSecond = 30
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func seek() {
        generation += 1
        hasFrame = false
        deliveredFPS = nil
        suspendWatch()
        queue.async { [reader] in reader.close() }
    }

    func suspendWatch() {
        checkpoint = nil
        noProgressSince = nil
        lastTick = nil
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        seek()
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        // A foreground playback request can stall while waiting for the audio
        // item or an exact seek. Pause, background, and user seeks reset it.
        guard let t = clock(), t.seconds.isFinite, t.seconds >= 0 else {
            if !awaitingClock() { suspendWatch(); return }
            if let lastTick, now - lastTick > 1 { suspendWatch() }
            lastTick = now
            checkpoint = nil
            if noProgressSince == nil { noProgressSince = now }
            if now - (noProgressSince ?? now) > 10 { stop(); fail("audio clock unavailable") }
            return
        }
        if t.playing {
            if let lastTick, now - lastTick > 1 { suspendWatch() }
            lastTick = now
            if noProgressSince == nil { noProgressSince = now }
            let deadline = hasFrame ? pictureTimeout : 6
            if now - (noProgressSince ?? now) > deadline {
                stop()
                fail(String(format: "no fresh picture for %.1f seconds", deadline))
                return
            }
            if hasFrame, let checkpoint, t.seconds - checkpoint.seconds >= max(8, pictureTimeout) {
                let fps = Double(frameCount - checkpoint.frames) / (t.seconds - checkpoint.seconds)
                deliveredFPS = fps
                if fps < minimumFPS {
                    stop()
                    fail(String(format: "delivered %.1f fps over %.1f seconds", fps, t.seconds - checkpoint.seconds))
                    return
                }
                self.checkpoint = nil
            }
            if hasFrame && checkpoint == nil { checkpoint = (t.seconds, frameCount) }
        } else {
            suspendWatch()
            if hasFrame { return }
        }
        guard demand.beginRead() else { return }
        let request = generation
        queue.async { [weak self, reader] in
            let picture = reader.copyPicture(at: t.seconds)
            let error = reader.error
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let readAgain = self.demand.finishRead()
                defer {
                    // Recheck play/pause, visibility and the audio clock after
                    // delivery. Never restart an old seek or a failed output.
                    if readAgain, self.displayLink != nil, self.generation == request { self.tick() }
                }
                guard self.displayLink != nil, self.generation == request else { return }
                if let error {
                    self.stop()
                    self.fail(error.localizedDescription)
                    return
                }
                guard let picture, let image = CMSampleBufferGetImageBuffer(picture),
                      let clock = self.clock() else { return }
                let pts = CMSampleBufferGetPresentationTimeStamp(picture).seconds
                guard pts.isFinite, abs(clock.seconds - pts) <= 0.30 else { return }
                self.frameCount += 1
                self.hasFrame = true
                self.noProgressSince = CACurrentMediaTime()
                self.deliver(image, pts)
            }
        }
    }
}
