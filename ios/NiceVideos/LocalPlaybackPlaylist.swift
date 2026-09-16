import Foundation

// Snapshot the current local-library order when opening a player. Availability
// is refreshed separately so queued deletion never shifts an index onto a wrong ID.
struct LocalPlaybackPlaylist {
    enum Direction: Equatable, Hashable { case previous, next }
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

// Paging keeps the user-requested direction: swipe UP -> previous, DOWN -> next.
// Unlike the original binary 64pt recognizer, the new path lets the page follow
// the finger, accepts a quick flick through predictedEndTranslation and applies
// rubber-band resistance at the first/last item.
enum PlaylistSwipe {
    static let minimumDistance: Double = 64
    static let verticalDominance: Double = 1.35
    static let pagingVerticalDominance: Double = 1.08
    static let boundaryResistance: Double = 0.18

    // Legacy deterministic recognizer retained for accessibility/tests and any
    // call site that does not have viewport/predicted-end information.
    static func direction(horizontal: Double, vertical: Double) -> LocalPlaybackPlaylist.Direction? {
        guard horizontal.isFinite, vertical.isFinite,
              abs(vertical) >= minimumDistance,
              abs(vertical) > abs(horizontal) * verticalDominance else { return nil }
        return vertical < 0 ? .previous : .next
    }

    static func pagingDirection(horizontal: Double, vertical: Double,
                                predictedVertical: Double, viewportHeight: Double)
        -> LocalPlaybackPlaylist.Direction? {
        guard horizontal.isFinite, vertical.isFinite, predictedVertical.isFinite,
              viewportHeight.isFinite, viewportHeight > 0,
              abs(vertical) > abs(horizontal) * pagingVerticalDominance else { return nil }

        // About one sixth of a page feels deliberate, while a quick flick may
        // commit earlier. Cap thresholds so landscape remains easy to operate.
        let distanceThreshold = min(140, max(54, viewportHeight * 0.16))
        let flickThreshold = min(180, max(82, viewportHeight * 0.24))
        let distanceCommit = abs(vertical) >= distanceThreshold
        let sameDirection = (vertical < 0) == (predictedVertical < 0)
        let flickCommit = sameDirection && abs(predictedVertical) >= flickThreshold &&
            abs(predictedVertical) > abs(vertical) * 1.18
        guard distanceCommit || flickCommit else { return nil }

        let decidingValue = flickCommit ? predictedVertical : vertical
        return decidingValue < 0 ? .previous : .next
    }

    static func interactiveOffset(horizontal: Double, vertical: Double,
                                  viewportHeight: Double,
                                  hasPrevious: Bool, hasNext: Bool) -> Double {
        guard horizontal.isFinite, vertical.isFinite, viewportHeight.isFinite,
              viewportHeight > 0,
              abs(vertical) > abs(horizontal) * pagingVerticalDominance else { return 0 }

        let bounded = min(viewportHeight, max(-viewportHeight, vertical))
        if bounded < 0, !hasPrevious { return bounded * boundaryResistance }
        if bounded > 0, !hasNext { return bounded * boundaryResistance }
        return bounded
    }
}
