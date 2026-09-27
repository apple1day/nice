import Foundation

enum BatchDeletionScope {
    case localVideos
    case downloadTasks

    func includes(_ record: DownloadRecord) -> Bool {
        switch self {
        case .localVideos: return record.state == .complete
        case .downloadTasks: return record.state != .complete
        }
    }
}

// Capture VALUES at confirmation time, including the download attempt. Never
// recalculate "all" when the user confirms: new jobs were not part of consent.
struct BatchDeletionRequest: Identifiable {
    let id = UUID()
    let scope: BatchDeletionScope
    let records: [DownloadRecord]
    let clearAll: Bool

    init(scope: BatchDeletionScope, records: [DownloadRecord], clearAll: Bool = false) {
        self.scope = scope
        self.clearAll = clearAll
        var seen = Set<String>()
        self.records = records.filter { scope.includes($0) && seen.insert($0.taskToken).inserted }
    }

    var title: String {
        switch scope {
        case .localVideos: return "删除这 \(records.count) 个本地视频？"
        case .downloadTasks:
            return clearAll ? "清空当前 \(records.count) 项下载任务？" : "删除这 \(records.count) 项下载任务？"
        }
    }

    var buttonTitle: String { clearAll ? "确认清空" : "确认删除" }

    var message: String {
        switch scope {
        case .localVideos:
            return "立即删除所选手机文件及播放进度，并移出待删除队列，不会删除服务器原视频。此操作无法撤销。"
        case .downloadTasks:
            return "取消其中正在下载的任务，移除失败/取消记录及残留文件。保留所有已下载完成的视频和服务器原视频。确认期间刚完成的下载会跳过。"
        }
    }

    func currentRecord(for snapshot: DownloadRecord, in current: [DownloadRecord]) -> DownloadRecord? {
        current.first { $0.taskToken == snapshot.taskToken && scope.includes($0) }
    }
}

struct BatchDeletionResult {
    var removedTokens = Set<String>()
    var skipped = 0
    var failures: [String] = []
    // Preserve every transaction notice, including deferred space-reclamation warnings.
    var details: [String] = []

    var summary: String {
        var parts = ["已删除 \(removedTokens.count) 项"]
        if skipped > 0 { parts.append("跳过 \(skipped) 项") }
        if !failures.isEmpty { parts.append("失败 \(failures.count) 项") }
        return parts.joined(separator: "，") + "。"
    }
}

extension VideoStore {
    // Same main-queue confinement as VideoStore and its URLSession delegates.
    // Reuse the existing recoverable transaction, active-playback lease, task
    // cancellation, progress/bookmark cleanup and pending-queue cleanup.
    @discardableResult
    func deleteBatch(_ request: BatchDeletionRequest) -> BatchDeletionResult {
        var result = BatchDeletionResult()
        guard !request.records.isEmpty else { return result }
        guard !restoring else {
            result.failures = request.records.map { "\($0.video.name)：正在恢复下载任务，请稍后重试。" }
            errorMessage = "正在恢复下载任务，未删除任何项目。"
            return result
        }
        for snapshot in request.records {
            guard let current = request.currentRecord(for: snapshot, in: records) else {
                result.skipped += 1
                continue
            }
            errorMessage = nil
            removeFromDevice(current)
            // Success is determined from the committed store, not a UI message.
            // A failed file/index transaction retains its record and can be retried.
            if records.contains(where: { $0.taskToken == current.taskToken }) {
                result.failures.append("\(current.video.name)：\(errorMessage ?? "删除未完成，原记录已保留。")")
            } else {
                result.removedTokens.insert(current.taskToken)
                if let notice = deletionNotice { result.details.append(notice) }
            }
        }
        errorMessage = result.failures.isEmpty ? nil
            : ([result.summary, "未删除的项目已保留，可重试："] + result.failures).joined(separator: "\n")
        return result
    }
}
