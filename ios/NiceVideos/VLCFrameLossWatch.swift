import Foundation

// Sample the native output and the app's memory callbacks together, once a second.
// Both a moving clock and *new* VLC losses are required before changing an input.
struct VLCFrameLossWatch {
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

    mutating func reset() {
        anchor = nil
        previous = nil
    }

    mutating func needsSmallerOutput(_ current: Sample) -> Bool {
        defer { previous = current }
        guard current.delivered > 0, current.clock.isFinite, current.host.isFinite,
              current.decoded >= 0, current.lost >= 0, current.displayed >= 0,
              let previous, let anchor,
              current.host > previous.host, current.host - previous.host <= 3,
              current.clock > previous.clock, current.clock - previous.clock <= 3,
              current.lost >= previous.lost, current.decoded >= previous.decoded,
              current.displayed == anchor.displayed,
              current.offered == anchor.offered, current.delivered == anchor.delivered,
              current.bufferMisses == anchor.bufferMisses, current.staleSource == anchor.staleSource,
              current.formatSetups == anchor.formatSetups else {
            self.anchor = current
            return false
        }
        return current.clock - anchor.clock >= 4 && current.host - anchor.host >= 4 &&
            current.decoded > anchor.decoded && Int64(current.lost) - Int64(anchor.lost) >= 12
    }
}
