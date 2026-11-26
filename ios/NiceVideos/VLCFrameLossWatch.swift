import Foundation

// Native statistics and the media clock can arrive at different rates.
// Both a moving clock and *new* VLC losses are required before changing an input.
struct VLCFrameLossWatch {
    enum State: String {
        case inactive, unseekable, awaitingFormat = "awaiting-format"
        case nearEnd = "near-end-or-unknown-duration", smallOutput = "small-output"
        case minimum, monitoring

        init(active: Bool, seekable: Bool, remaining: Double, outputEdge: UInt32,
             reducedLimit: UInt32, alreadyReduced: Bool) {
            if !active { self = .inactive }
            else if !seekable { self = .unseekable }
            else if remaining <= 2 { self = .nearEnd }
            else if outputEdge == 0 { self = .awaitingFormat }
            else if alreadyReduced { self = .minimum }
            else if outputEdge <= reducedLimit { self = .smallOutput }
            else { self = .monitoring }
        }
    }

    struct Sample {
        let clock: Double
        let host: TimeInterval
        let decoded: Int32
        let displayed: Int32
        let lost: Int32
        let offered: UInt64
        let delivered: UInt64
        let bufferMisses: UInt64
        let staleSource: UInt64
        let formatSetups: UInt64
    }

    private var anchor: Sample?
    private var previous: Sample?

    var observedMediaSeconds: Double {
        guard let previous, let anchor else { return 0 }
        return max(0, previous.clock - anchor.clock)
    }

    mutating func reset() {
        anchor = nil
        previous = nil
    }

    mutating func needsSmallerOutput(_ current: Sample) -> Bool {
        defer { previous = current }
        guard current.clock.isFinite, current.host.isFinite, current.formatSetups > 0,
              current.decoded >= 0, current.lost >= 0, current.displayed >= 0,
              current.delivered > 0 || (current.offered == 0 && current.displayed == 0),
              let previous, let anchor,
              previous.decoded >= 0, previous.lost >= 0, previous.displayed >= 0,
              current.host > previous.host, current.host - previous.host <= 8,
              current.clock >= previous.clock,
              current.clock - anchor.clock <= current.host - anchor.host + 1.25,
              current.lost >= previous.lost, current.decoded >= previous.decoded,
              current.displayed == anchor.displayed,
              current.offered == anchor.offered, current.delivered == anchor.delivered,
              current.bufferMisses == anchor.bufferMisses, current.staleSource == anchor.staleSource,
              current.formatSetups == anchor.formatSetups else {
            self.anchor = current
            return false
        }
        // Repeated VLC timestamps do not erase evidence; wait for advancement
        // before firing. Explicit app seeks and pauses reset the observation.
        return current.clock > previous.clock && current.clock - anchor.clock >= 4 && current.host - anchor.host >= 4 &&
            current.decoded > anchor.decoded && Int64(current.lost) - Int64(anchor.lost) >= 12
    }
}
