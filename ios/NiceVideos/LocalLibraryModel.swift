import Foundation
import Combine

struct LocalLibraryRow: Identifiable, Equatable {
    let record: DownloadRecord
    let subtitle: String
    var id: String { record.id }
}

// The local List deliberately does not observe VideoStore.objectWillChange or
// download progress. Only manifest changes rebuild rows/formatters/search data.
final class LocalLibraryModel: ObservableObject {
    @Published private(set) var visibleRows: [LocalLibraryRow] = []
    @Published private(set) var visibleTokens: [String] = []
    @Published private(set) var pendingRecords: [DownloadRecord] = []
    @Published private(set) var summary = "0 个视频 · 0 KB"
    @Published private(set) var restoring = false
    @Published private(set) var notice: String?
    private(set) var metadataBuildCount = 0
    private var allRows: [LocalLibraryRow] = []
    private var subtitles: [String: String] = [:]
    private var search = ""
    private var summaryBytes: Int64 = -1
    private var summaryCount = -1
    private var subscriptions = Set<AnyCancellable>()

    init(store: VideoStore) {
        store.$records.removeDuplicates().sink { [weak self] in self?.rebuild($0) }
            .store(in: &subscriptions)
        store.$restoring.removeDuplicates().sink { [weak self] in self?.restoring = $0 }
            .store(in: &subscriptions)
        store.$deletionNotice.removeDuplicates().sink { [weak self] in self?.notice = $0 }
            .store(in: &subscriptions)
    }
    func setSearch(_ value: String) {
        guard search != value else { return }
        search = value
        filterRows()
    }
    private func rebuild(_ records: [DownloadRecord]) {
        metadataBuildCount += 1
        let completed = LocalLibraryOrder.newestFirst(records.filter { $0.state == .complete },
                                                       completedAt: { $0.downloadedAt })
        let ids = Set(completed.map(\.id))
        subtitles = subtitles.filter { ids.contains($0.key) }
        allRows = completed.map { record in
            let text: String
            if let cached = subtitles[record.id] { text = cached }
            else {
                text = "\(record.video.fileExtension.uppercased()) · \(record.video.sizeLabel)"
                subtitles[record.id] = text
            }
            return LocalLibraryRow(record: record, subtitle: text)
        }
        let pending = records.filter { $0.pendingDeletionOrder != nil }.sorted {
            let left = $0.pendingDeletionOrder ?? 0
            let right = $1.pendingDeletionOrder ?? 0
            return left == right ? $0.id < $1.id : left < right
        }
        if pendingRecords != pending { pendingRecords = pending }
        let bytes = completed.reduce(Int64(0)) { $0 + $1.video.size }
        if summaryBytes != bytes || summaryCount != completed.count {
            summaryBytes = bytes
            summaryCount = completed.count
            summary = "\(completed.count) 个视频 · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
        }
        filterRows()
    }
    private func filterRows() {
        let next = search.isEmpty ? allRows : allRows.filter {
            $0.record.video.name.localizedCaseInsensitiveContains(search)
        }
        if visibleRows != next { visibleRows = next }
        let tokens = next.map { $0.record.taskToken }
        if visibleTokens != tokens { visibleTokens = tokens }
    }
}
