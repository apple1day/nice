import Foundation

// Snapshot the current local-library order when opening a player. Availability
// is refreshed separately so FIFO deletion never shifts an index onto a wrong ID.
struct LocalPlaybackPlaylist {
    enum Direction: Equatable { case previous, next }
    let ids: [String]
    private(set) var currentID: String

    init(ids: [String], currentID: String) {
        var seen = Set<String>()
        var unique = ids.filter { seen.insert($0).inserted }
        if !seen.contains(currentID) { unique.append(currentID) }
        self.ids = unique
        self.currentID = currentID
    }

    func visibleIDs(available: Set<String>) -> [String] {
        ids.filter { available.contains($0) }
    }

    func candidates(_ direction: Direction, available: Set<String>) -> [String] {
        guard let index = ids.firstIndex(of: currentID) else { return [] }
        let neighbors: [String]
        switch direction {
        case .previous: neighbors = Array(ids[..<index].reversed())
        case .next: neighbors = Array(ids.dropFirst(index + 1))
        }
        return neighbors.filter { available.contains($0) }
    }

    @discardableResult mutating func select(_ id: String) -> Bool {
        guard ids.contains(id) else { return false }
        currentID = id
        return true
    }
}

// User-requested direction, deliberately NOT the usual short-video convention:
// swipe UP -> previous; swipe DOWN -> next. No predicted-distance shortcuts.
enum PlaylistSwipe {
    static let minimumDistance: Double = 64
    static let verticalDominance: Double = 1.35
    static func direction(horizontal: Double, vertical: Double) -> LocalPlaybackPlaylist.Direction? {
        guard horizontal.isFinite, vertical.isFinite,
              abs(vertical) >= minimumDistance,
              abs(vertical) > abs(horizontal) * verticalDominance else { return nil }
        return vertical < 0 ? .previous : .next
    }
}
