import Foundation
import CryptoKit

struct ClientError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// Server `downloaded` is historical data, NEVER device state.
struct Video: Codable, Identifiable, Hashable {
    let name: String
    let size: Int64
    let contentType: String
    let url: String // Kept for compatibility with the API; never used for playback.
    let downloadUrl: String
    var id: String { name }
    var fileExtension: String { (name as NSString).pathExtension.lowercased() }
    var isHLS: Bool { fileExtension == "m3u8" || contentType.lowercased().contains("mpegurl") }
    var supportsOffline: Bool { OfflineMediaPolicy.supports(name: name, size: size, contentType: contentType) }
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
    func storageID(server: URL) -> String {
        // Keep the v1 identity so existing downloads and positions survive the upgrade.
        let identity = server.absoluteString + "\n" + name + "\n" + String(size)
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct VideoEnvelope: Codable { let videos: [Video] }

enum ServerAddress {
    static func normalize(_ input: String) throws -> URL {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClientError("请先填写服务器地址。") }
        if !text.contains("://") { text = "http://" + text }
        guard var parts = URLComponents(string: text),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else {
            throw ClientError("请填写服务器根地址，例如 http://192.168.19.70:8106，不要带 /api/videos、账号或查询参数。")
        }
        parts.scheme = scheme
        parts.host = host.lowercased()
        if (scheme == "http" && parts.port == 80) || (scheme == "https" && parts.port == 443) { parts.port = nil }
        parts.path = "/"
        guard let result = parts.url else { throw ClientError("服务器地址无效。") }
        return result
    }
    static func endpoint(_ path: String, on server: URL) throws -> URL {
        guard path.hasPrefix("/api/"),
              let result = URL(string: path, relativeTo: server)?.absoluteURL,
              result.scheme == server.scheme, result.host == server.host,
              result.port == server.port, result.fragment == nil,
              result.user == nil, result.password == nil else {
            throw ClientError("服务器返回了无效或非同源的 API 地址。")
        }
        return result
    }
}

enum DownloadState: String, Codable { case downloading, complete, failed }
struct DownloadRecord: Codable, Identifiable, Equatable {
    let id: String
    let video: Video
    let server: String
    var attempt: String
    var state: DownloadState
    var message: String?
    // Optional for backwards-compatible decoding of v1 downloads.json.
    // Persist queue order with the records, never in a separate, drifting index.
    var pendingDeletionOrder: Int?
    var taskToken: String { id + "|" + attempt }
    var fileName: String { id + "." + video.fileExtension }
    init(video: Video, server: URL) {
        id = video.storageID(server: server)
        self.video = video
        self.server = server.absoluteString
        attempt = UUID().uuidString
        state = .downloading
        message = nil
        pendingDeletionOrder = nil
    }
}
struct DownloadManifest: Codable {
    var version = 1
    var records: [DownloadRecord]
}

struct PlaybackRequest: Identifiable {
    let id = UUID()
    let key: String
    let title: String
    let url: URL
    init(key: String, title: String, url: URL) throws {
        try OfflineMediaPolicy.validateLocalFile(url)
        self.key = key
        self.title = title
        self.url = url
    }
}

final class LocalStorage {
    let root: URL
    private let media: URL
    private let fm = FileManager.default
    init(root: URL? = nil) throws {
        self.root = try root ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("NiceVideos", isDirectory: true)
        media = self.root.appendingPathComponent("Media", isDirectory: true)
        try fm.createDirectory(at: media, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var excluded = self.root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }
    func loadRecords() throws -> [DownloadRecord] {
        let url = root.appendingPathComponent("downloads.json")
        guard fm.fileExists(atPath: url.path) else { return [] }
        let manifest = try JSONDecoder().decode(DownloadManifest.self, from: Data(contentsOf: url))
        guard manifest.version == 1, Set(manifest.records.map(\.id)).count == manifest.records.count else {
            throw ClientError("下载索引版本不兼容或包含重复记录；原文件已保留，请勿卸载 App。")
        }
        return manifest.records
    }
    func saveRecords(_ records: [DownloadRecord]) throws {
        try JSONEncoder().encode(DownloadManifest(records: records))
            .write(to: root.appendingPathComponent("downloads.json"), options: .atomic)
    }
    func loadCatalogs() throws -> [String: [Video]] {
        let url = root.appendingPathComponent("catalogs.json")
        guard fm.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: [Video]].self, from: Data(contentsOf: url))
    }
    func saveCatalogs(_ catalogs: [String: [Video]]) throws {
        try JSONEncoder().encode(catalogs)
            .write(to: root.appendingPathComponent("catalogs.json"), options: .atomic)
    }
    func destination(for record: DownloadRecord) throws -> URL {
        guard record.id.count == 64, record.id.allSatisfy({ "0123456789abcdef".contains($0) }),
              record.video.supportsOffline else { throw ClientError("本地文件标识或格式无效。") }
        return media.appendingPathComponent(record.fileName, isDirectory: false)
    }
    func verifiedFile(for record: DownloadRecord) -> URL? {
        guard let file = try? destination(for: record),
              let attrs = try? fm.attributesOfItem(atPath: file.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber, size.int64Value == record.video.size else { return nil }
        return file
    }
    static func validateDownload(response: URLResponse?, actualSize: Int64, expectedSize: Int64) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ClientError("下载失败：HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)。")
        }
        let mime = http.mimeType?.lowercased() ?? ""
        guard !mime.hasPrefix("text/"), !mime.contains("json"), !mime.contains("mpegurl"), !mime.contains("dash+xml") else {
            throw ClientError("服务器返回了文本、错误页面或播放清单，不是完整视频。")
        }
        guard expectedSize > 0, actualSize == expectedSize else {
            throw ClientError("下载文件大小与列表不一致。请刷新列表后重试，可能是视频已更换或下载不完整。")
        }
    }
    func finish(temp: URL, response: URLResponse?, record: DownloadRecord) throws {
        let attrs = try fm.attributesOfItem(atPath: temp.path)
        let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? -1
        try Self.validateDownload(response: response, actualSize: bytes, expectedSize: record.video.size)
        try OfflineMediaPolicy.rejectTextPayload(at: temp)
        let file = try destination(for: record)
        if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        // URLSession owns `temp`: move it synchronously before its delegate returns.
        try fm.moveItem(at: temp, to: file)
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
    }
    func remove(_ record: DownloadRecord) throws {
        let file = try destination(for: record)
        if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
    }

    // Returns only after the prospective records/queue have committed. A failed
    // write rolls the video back. Never delete a file first and then hope to save.
    func removeAndSave(_ record: DownloadRecord, records: [DownloadRecord]) throws -> String? {
        guard !records.contains(where: { $0.id == record.id }) else {
            throw ClientError("删除事务仍然引用原视频，已停止删除。")
        }
        return try LocalRemovalTransaction.commit(
            file: destination(for: record),
            staged: root.appendingPathComponent("RemovalStaging", isDirectory: true)
                .appendingPathComponent(record.fileName)
        ) { try self.saveRecords(records) }
    }

    // Run before reconciliation and before accepting re-downloads, so an old
    // staged deletion can never resurrect itself as a new download of the same ID.
    func recoverRemovals(records: [DownloadRecord], onCommittedRemoval: (String) -> Void = { _ in }) throws {
        let directory = root.appendingPathComponent("RemovalStaging", isDirectory: true)
        guard let type = try LocalRemovalTransaction.itemType(at: directory) else { return }
        guard type == .typeDirectory else { throw ClientError("删除暂存目录异常，已保留文件。") }
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard files.isEmpty || fm.fileExists(atPath: root.appendingPathComponent("downloads.json").path) else {
            throw ClientError("下载索引缺失，无法确定删除是否提交；暂存视频已保留，请勿卸载 App。")
        }
        let referenced = Set(records.map(\.fileName))
        for staged in files {
            let id = staged.deletingPathExtension().lastPathComponent
            guard id.count == 64, id.allSatisfy({ "0123456789abcdef".contains($0) }),
                  OfflineMediaPolicy.extensions.contains(staged.pathExtension) else {
                throw ClientError("删除暂存目录存在未知文件，已保留并停止自动处理。")
            }
            let keep = referenced.contains(staged.lastPathComponent)
            try LocalRemovalTransaction.recover(
                file: media.appendingPathComponent(staged.lastPathComponent),
                staged: staged, isReferenced: keep
            )
            if !keep { onCommittedRemoval(id) }
        }
    }
}
