import Foundation

// Selection is keyed by taskToken (ID + download attempt), not row index or name.
// A retry must never silently inherit the selection of an older download.
struct BatchSelection: Equatable {
    private(set) var isSelecting = false
    private(set) var tokens = Set<String>()

    mutating func begin() {
        isSelecting = true
        tokens.removeAll()
    }

    mutating func cancel() {
        isSelecting = false
        tokens.removeAll()
    }

    mutating func toggle(_ token: String) {
        guard isSelecting else { return }
        if tokens.contains(token) { tokens.remove(token) }
        else { tokens.insert(token) }
    }

    func contains(_ token: String) -> Bool { tokens.contains(token) }

    func allSelected(in visible: [String]) -> Bool {
        !visible.isEmpty && Set(visible).isSubset(of: tokens)
    }

    mutating func toggleAll(in visible: [String]) {
        guard isSelecting else { return }
        let candidates = Set(visible)
        if allSelected(in: visible) { tokens.removeAll() }
        else { tokens = candidates }
    }

    // Search changes, completion, removal and retries all prune hidden/stale rows.
    mutating func retainVisible(_ visible: [String]) {
        tokens.formIntersection(Set(visible))
        if visible.isEmpty { cancel() }
    }
}
