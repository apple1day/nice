import Foundation

// Native statistics and the media clock can arrive at different rates.
// Both a moving clock and *new* VLC losses are required before changing an input.
struct VLCFrameLossWatch {
    enum Gate: String {
        case open, preview = "paused-preview", paused = "paused-intent", seek, notPlaying = "not-playing", background

        init(requested: Bool, preview: Bool, seeking: Bool, playing: Bool, background: Bool) {
            if preview { self = .preview }
            else if !requested { self = .paused }
            else if seeking { self = .seek }
            else if !playing { self = .notPlaying }
            else if background { self = .background }
            else { self = .open }
        }
    }

    enum State: String {
        case inactive, unseekable, awaitingFormat = "awaiting-format"
        case nearEnd = "near-end-or-unknown-duration", smallOutput = "small-output"
        case minimum, monitoring

        init(active: Bool, seekable: Bool, remaining: Double, outputEdge: UInt32,
             reducedLimit: UInt32, alreadyReduced: Bool) {
            if !active { self = .inactive }
            else if !seekable { self = .unseekable }
            // The last two seconds block a decoder reopen. At the minimum
            // there is nothing to reopen; keep measuring the current input.
            else if alreadyReduced && outputEdge > 0 { self = .minimum }
            else if remaining <= 2 { self = .nearEnd }
            else if outputEdge == 0 { self = .awaitingFormat }
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

    enum Pattern: String {
        case none, frozen, sparse
    }

    private var frozenStart: Sample?
    private var rateStart: Sample?
    private var slowSince: Sample?
    private var sustainedSparse = false
    private var previous: Sample?
    private(set) var pattern = Pattern.none

    var observedMediaSeconds: Double {
        guard let previous, let start = slowSince ?? frozenStart else { return 0 }
        return max(0, previous.clock - start.clock)
    }

    mutating func reset() { self = Self() }

    mutating func needsSmallerOutput(_ current: Sample, nominalFrameRate: Double = 0) -> Bool {
        defer { previous = current }
        guard current.clock.isFinite, current.host.isFinite, current.formatSetups > 0,
              current.decoded >= 0, current.lost >= 0, current.displayed >= 0,
              current.delivered > 0 || (current.offered == 0 && current.displayed == 0),
              let previous, let frozenStart, let rateStart,
              previous.decoded >= 0, previous.lost >= 0, previous.displayed >= 0,
              current.host > previous.host, current.host - previous.host <= 8,
              current.clock >= previous.clock,
              current.clock - rateStart.clock <= current.host - rateStart.host + 1.25,
              current.lost >= previous.lost, current.decoded >= previous.decoded,
              current.displayed >= previous.displayed, current.offered >= previous.offered,
              current.delivered >= previous.delivered, current.bufferMisses == previous.bufferMisses,
              current.staleSource == previous.staleSource, current.formatSetups == previous.formatSetups else {
            reset()
            self.frozenStart = current
            self.rateStart = current
            return false
        }

        let unchanged = current.displayed == frozenStart.displayed && current.offered == frozenStart.offered &&
            current.delivered == frozenStart.delivered
        if !unchanged { self.frozenStart = current }
        let frozen = unchanged && current.clock - frozenStart.clock >= 4 && current.host - frozenStart.host >= 4 &&
            current.decoded > frozenStart.decoded && Int64(current.lost) - Int64(frozenStart.lost) >= 12

        let mediaTime = current.clock - rateStart.clock, hostTime = current.host - rateStart.host
        if mediaTime >= 3 && hostTime >= 3 {
            // Require two consecutive windows of heavy *native* loss and low
            // throughput at both ends of the bridge. Queue coalescing alone or
            // a genuinely low-rate track cannot qualify.
            let displayed = Int64(current.displayed) - Int64(rateStart.displayed)
            let lost = Int64(current.lost) - Int64(rateStart.lost)
            let pictures = max(Double(displayed), Double(current.offered - rateStart.offered),
                               Double(current.delivered - rateStart.delivered))
            let severe = nominalFrameRate.isFinite && nominalFrameRate >= 24 && mediaTime >= 0.7 * hostTime &&
                current.decoded > rateStart.decoded && pictures / mediaTime <= min(8, nominalFrameRate / 4) &&
                Double(lost) >= max(4 * mediaTime, pictures)
            sustainedSparse = severe && slowSince != nil
            slowSince = severe ? (slowSince ?? rateStart) : nil
            self.rateStart = current
        }
        pattern = frozen ? .frozen : (sustainedSparse ? .sparse : .none)
        return current.clock > previous.clock && pattern != .none
    }
}
