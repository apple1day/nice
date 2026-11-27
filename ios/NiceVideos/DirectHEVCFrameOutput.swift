import AVFoundation
import UIKit

/// The AVPlayer audio item owns seeking and playback time. The serial reader
/// decodes references in DTS order; the renderer receives only pictures due now.
final class DirectHEVCFrameOutput: NSObject {
    private let reader: DirectHEVCReader
    private let queue = DispatchQueue(label: "NiceVideos.direct-hevc", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let clock: () -> (seconds: Double, playing: Bool)?
    private let awaitingClock: () -> Bool
    private let deliver: (CVPixelBuffer, Double) -> Void
    private let fail: (String) -> Void
    private var displayLink: CADisplayLink?
    private var busy = false
    private var generation = 0
    private var checkpoint: (seconds: Double, frames: Int)?
    private var noProgressSince: CFTimeInterval?
    private var lastTick: CFTimeInterval?
    private(set) var frameCount = 0
    private(set) var hasFrame = false
    private(set) var deliveredFPS: Double?

    init(track: AVAssetTrack, asset: AVAsset, clock: @escaping () -> (Double, Bool)?,
         awaitingClock: @escaping () -> Bool, deliver: @escaping (CVPixelBuffer, Double) -> Void, fail: @escaping (String) -> Void) {
        reader = DirectHEVCReader(track: track, asset: asset, requireHardware: true)
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
            if now - (noProgressSince ?? now) > 6 {
                stop()
                fail("no fresh picture for six seconds")
                return
            }
            if hasFrame, let checkpoint, t.seconds - checkpoint.seconds >= 8 {
                let fps = Double(frameCount - checkpoint.frames) / (t.seconds - checkpoint.seconds)
                deliveredFPS = fps
                if fps < 8 {
                    stop()
                    fail(String(format: "delivered %.1f fps over eight seconds", fps))
                    return
                }
                self.checkpoint = nil
            }
            if hasFrame && checkpoint == nil { checkpoint = (t.seconds, frameCount) }
        } else {
            suspendWatch()
            if hasFrame { return }
        }
        guard !busy else { return }
        busy = true
        let request = generation
        queue.async { [weak self, reader] in
            let picture = reader.copyPicture(at: t.seconds)
            let error = reader.error
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
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
