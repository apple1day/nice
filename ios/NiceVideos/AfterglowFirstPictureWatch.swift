import Foundation

/// An AVPlayer can advance its audio clock while never returning a video buffer.
/// Count foreground observation time per input. A seek can change media time by
/// minutes and a rebuilt output can reset its PTS sequence; neither is evidence
/// that a video frame arrived.
struct AfterglowFirstPictureWatch {
    enum Failure: String { case unsupportedTrack, startupTimeout }
    private var previous: TimeInterval?
    private var wasPlayingUnsupported = false
    private var foregroundSeconds = 0.0
    private var unsupportedPlayingSeconds = 0.0
    private(set) var trackDecodable: Bool?
    private(set) var delivered = false

    mutating func classifyTrack(decodable: Bool) { trackDecodable = decodable }
    mutating func receivedPicture() { delivered = true }

    mutating func suspend() {
        previous = nil
        wasPlayingUnsupported = false
    }

    mutating func seek() {
        // Give an ordinary, decodable input its normal seek preroll window.
        if trackDecodable != false { foregroundSeconds = 0; suspend() }
    }

    mutating func sample(at now: TimeInterval, active: Bool, playing: Bool) -> Failure? {
        guard active, !delivered, now.isFinite else { suspend(); return nil }
        let unsupported = trackDecodable == false && playing
        defer {
            previous = now
            wasPlayingUnsupported = unsupported
        }
        guard let previous else { return nil }
        let delta = now - previous
        // A suspended process or a blocked main run loop could not issue pulls.
        guard delta > 0, delta <= 1.5 else { return nil }
        foregroundSeconds += delta
        if unsupported && wasPlayingUnsupported { unsupportedPlayingSeconds += delta }
        if unsupportedPlayingSeconds >= 4 { return .unsupportedTrack }
        if foregroundSeconds >= 15 { return .startupTimeout }
        return nil
    }
}
