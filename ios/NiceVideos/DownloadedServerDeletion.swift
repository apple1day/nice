import Foundation

/// Metadata-only snapshot. Opening the server list never scans local video files.
struct DownloadedServerDeletionPlan {
    let server: String
    let records: [DownloadRecord]

    init(server: String, videos: [Video], records: [DownloadRecord]) {
        self.server = server
        guard let base = try? ServerAddress.normalize(server) else {
            self.records = []
            return
        }
        let visibleIDs = Set(videos.map { $0.storageID(server: base) })
        var seen = Set<String>()
        self.records = records.filter {
            $0.state == .complete && $0.server == base.absoluteString &&
            visibleIDs.contains($0.id) && $0.id == $0.video.storageID(server: base) &&
            seen.insert($0.id).inserted
        }
    }
}

struct DownloadedServerDeletionResult {
    var deleted = 0
    var skipped = 0
    var failures: [String] = []
    var details: [String] = []

    var summary: String {
        "已删除服务器视频 \(deleted) 个，跳过 \(skipped) 个，失败 \(failures.count) 个。手机本地副本保留。"
    }
}

enum DownloadedServerDeletion {
    /// Revalidate each download attempt and local file immediately before DELETE.
    /// Dependencies are explicit so safety rules can be tested without real servers.
    @MainActor
    static func run(
        _ plan: DownloadedServerDeletionPlan,
        currentServer: () -> String,
        currentRecord: (DownloadRecord) -> DownloadRecord?,
        verifyLocalFile: (DownloadRecord) throws -> Void,
        deleteRemote: @MainActor (Video) async throws -> Void
    ) async -> DownloadedServerDeletionResult {
        var result = DownloadedServerDeletionResult()
        for (index, snapshot) in plan.records.enumerated() {
            guard !Task.isCancelled, currentServer() == plan.server else {
                result.skipped += plan.records.count - index
                result.details.append("服务器已切换或操作已取消，剩余项目未删除。")
                break
            }
            guard let record = currentRecord(snapshot),
                  record.id == snapshot.id, record.taskToken == snapshot.taskToken,
                  record.state == .complete, record.server == snapshot.server else {
                result.skipped += 1
                result.details.append("\(snapshot.video.name)：本地副本已移除或下载状态已变化，保留服务器文件。")
                continue
            }
            do {
                try verifyLocalFile(record)
            } catch {
                result.skipped += 1
                result.details.append("\(snapshot.video.name)：本地文件无法验证，保留服务器文件。\(error.localizedDescription)")
                continue
            }
            do {
                try await deleteRemote(snapshot.video)
                result.deleted += 1
            } catch {
                result.failures.append("\(snapshot.video.name)：\(error.localizedDescription)")
            }
        }
        return result
    }
}
