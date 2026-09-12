import Foundation

enum BatchRemovalScope {
    case localVideos
    case downloadTasks

    func includes(_ record: DownloadRecord) -> Bool {
        switch self {
        case .localVideos: return record.state == .complete
        case .downloadTasks: return record.state != .complete
        }
    }
}

// Freeze the exact scope when opening confirmation. Never recalculate "all"
// when the user confirms: new tasks and new attempts must survive an old dialog.
struct BatchRemovalRequest {
    let scope: BatchRemovalScope
    let records: [DownloadRecord]
    let clearAll: Bool

    init(scope: BatchRemovalScope, records: [DownloadRecord], clearAll: Bool = false) {
        self.scope = scope
        self.clearAll = clearAll
        var seen = Set<String>()
        self.records = records.filter { scope.includes($0) && seen.insert($0.taskToken).inserted }
    }

    func currentRecord(for snapshot: DownloadRecord, in current: [DownloadRecord]) -> DownloadRecord? {
        current.first { $0.taskToken == snapshot.taskToken && scope.includes($0) }
    }

    var title: String {
        switch scope {
        case .localVideos: return "删除 \(records.count) 个本地视频？"
        case .downloadTasks:
            return clearAll ? "清空当前 \(records.count) 个下载任务？" : "删除 \(records.count) 个下载任务？"
        }
    }

    var confirmLabel: String { clearAll ? "确认清空" : "确认删除（\(records.count)）" }
    var explanation: String {
        switch scope {
        case .localVideos:
            return "立即删除选中的手机文件及播放进度，不加入待删除队列。不会删除服务器视频；正在播放的文件会保留并提示。"
        case .downloadTasks:
            return "取消选中的进行中下载，并移除失败、已取消的任务记录。不会删除已下载完成的本地视频或服务器视频。确认期间刚完成、重试或新增的任务会保留。"
        }
    }
}

struct BatchRemovalResult {
    var removedCount = 0
    var skippedCount = 0
    var failures: [String] = []
    var warnings: [String] = []

    func summary(for scope: BatchRemovalScope) -> String {
        let noun = scope == .localVideos ? "个手机视频" : "个下载任务"
        var text = "已删除 \(removedCount) \(noun)"
        if skippedCount > 0 { text += "，跳过 \(skippedCount) 个状态已变化或已移除的项目" }
        if !failures.isEmpty { text += "，\(failures.count) 项未能删除" }
        return text + "。"
    }
}
