import Foundation

/// Sampled by the player's clock, independently of the output's display link.
struct AppleVideoFrameWatch {
    enum Action: Equatable { case rebuildOutput, fail }
    private var previousTime: Double?
    private var previousSequence: UInt64?
    private(set) var silentSeconds = 0.0
    private(set) var rebuilt = false

    mutating func interrupt() {
        previousTime = nil
        previousSequence = nil
        silentSeconds = 0
    }

    mutating func sample(clock: Double, expectingVideo: Bool, projected: Bool,
                         hasImage: Bool, sequence: UInt64, fps: Float?) -> Action? {
        guard expectingVideo, clock.isFinite, projected || !hasImage else {
            interrupt()
            return nil
        }
        defer {
            previousTime = clock
            previousSequence = sequence
        }
        guard let previousTime, clock >= previousTime, previousSequence == sequence else {
            silentSeconds = 0
            return nil
        }
        // A delayed observer invocation or an unannounced timeline jump must
        // not be mistaken for a long stretch of continuous playback.
        silentSeconds += min(1, clock - previousTime)
        var grace = hasImage ? 8.0 : 6.0
        if projected {
            if let fps, fps.isFinite, fps > 0 { grace = max(grace, 3 / Double(fps)) }
            else if hasImage { grace = max(grace, 15) }
        }
        guard silentSeconds >= grace else { return nil }
        silentSeconds = 0
        if projected && !rebuilt {
            rebuilt = true
            return .rebuildOutput
        }
        return .fail
    }
}
