import Foundation

// No filesystem metadata is consulted to order the library. New downloads have
// a completion timestamp; legacy entries retain their saved order, reversed.
enum LocalLibraryOrder {
    static func newestFirst<Element>(_ items: [Element], completedAt: (Element) -> Date?) -> [Element] {
        items.enumerated().sorted { left, right in
            let lhs = completedAt(left.element)?.timeIntervalSinceReferenceDate
            let rhs = completedAt(right.element)?.timeIntervalSinceReferenceDate
            let a = lhs.flatMap { $0.isFinite ? $0 : nil }
            let b = rhs.flatMap { $0.isFinite ? $0 : nil }
            switch (a, b) {
            case let (.some(a), .some(b)) where a != b: return a > b
            case (.some, .none): return true
            case (.none, .some): return false
            default: return left.offset > right.offset
            }
        }.map(\.element)
    }
}

// A click/open/seek is not evidence of watching. Require playing + video output;
// a successful mark is emitted once, not on every playback time notification.
struct PlaybackWatchGate {
    private(set) var recorded = false
    mutating func consume(isPlaying: Bool, hasVideo: Bool, allowed: Bool) -> Bool {
        guard !recorded, allowed, isPlaying, hasVideo else { return false }
        recorded = true
        return true
    }
}
