import Foundation

// UI selection uses attempt tokens, not filenames/row offsets: retrying a
// download must never transfer a selection to the new task.
struct BatchSelection: Equatable {
    private(set) var isSelecting = false
    private(set) var tokens: Set<String> = []

    mutating func begin() { isSelecting = true; tokens.removeAll() }
    mutating func end() { isSelecting = false; tokens.removeAll() }

    mutating func toggle(_ token: String) {
        guard isSelecting else { return }
        if tokens.contains(token) { tokens.remove(token) } else { tokens.insert(token) }
    }

    func allSelected(in visible: Set<String>) -> Bool {
        !visible.isEmpty && visible.isSubset(of: tokens)
    }

    mutating func toggleAll(in visible: Set<String>) {
        guard isSelecting else { return }
        tokens = allSelected(in: visible) ? [] : visible
    }

    // Search changes, completions, retries and deletions prune invisible entries.
    // Newly arriving rows are intentionally NOT selected automatically.
    mutating func reconcile(with visible: Set<String>) {
        tokens.formIntersection(visible)
    }
}
