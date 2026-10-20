import Foundation

// A drag is a short-lived transaction. Its token must still match before a
// value can be updated or committed; cancellation invalidates it immediately.
// UIKit tracking, a discrete transport action and view teardown all share this
// state, so a late touch-up cannot restore a cancelled draft or seek a new clip.
struct PlaybackScrubSession {
    private(set) var token: UUID?
    private(set) var draftSeconds: Double?
    var isEditing: Bool { token != nil }

    mutating func begin(at seconds: Double) -> UUID? {
        guard seconds.isFinite else { return nil }
        let next = UUID()
        token = next
        draftSeconds = max(0, seconds)
        return next
    }

    @discardableResult
    mutating func update(_ seconds: Double, token expected: UUID) -> Bool {
        guard token == expected, seconds.isFinite else { return false }
        draftSeconds = max(0, seconds)
        return true
    }

    mutating func finish(token expected: UUID) -> Double? {
        guard token == expected else { return nil }
        let result = draftSeconds
        cancel()
        return result
    }

    @discardableResult
    mutating func cancel() -> Bool {
        let wasEditing = isEditing
        token = nil
        draftSeconds = nil
        return wasEditing
    }
}
