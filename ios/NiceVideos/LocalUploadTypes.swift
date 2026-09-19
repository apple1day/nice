import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum LocalUploadState: String, Codable {
    case queued, uploading, completed, failed, conflict, cancelled
    var isPending: Bool { self == .queued || self == .uploading }
    var label: String {
        switch self {
        case .queued: return "等待上传"
        case .uploading: return "上传中"
        case .completed: return "已上传"
        case .failed: return "上传失败"
        case .conflict: return "同名未上传"
        case .cancelled: return "已取消"
        }
    }
}

struct LocalUploadSource: Codable, Equatable {
    let id: String
    let taskToken: String
    let name: String
    let size: Int64
}

struct LocalUploadJob: Codable, Identifiable, Equatable {
    let id: UUID
    let source: LocalUploadSource
    let server: URL
    let allowsCellular: Bool
    var state: LocalUploadState = .queued
    var message: String?

    init(source: LocalUploadSource, server: URL, allowsCellular: Bool, id: UUID = UUID()) {
        self.id = id
        self.source = source
        self.server = server
        self.allowsCellular = allowsCellular
    }
    func matches(_ source: LocalUploadSource, server: URL) -> Bool {
        self.source.id == source.id && self.source.taskToken == source.taskToken && self.server == server
    }
}

struct LocalUploadError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

// The wire format is independent of UI, VideoStore and file loading.
enum LocalUploadWire {
    static let maximumBytes: Int64 = 20 * 1024 * 1024 * 1024
    static let responseLimit = 16 * 1024
    private static let queryCharacters = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    private static let extensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "webm", "ogg", "flv", "wmv", "ts"]

    static func request(for job: LocalUploadJob) throws -> URLRequest {
        let name = job.source.name
        guard !name.isEmpty, name.utf8.count <= 240, !name.hasPrefix("."),
              !name.contains("/"), !name.contains("\\"),
              name.rangeOfCharacter(from: .controlCharacters) == nil,
              extensions.contains((name as NSString).pathExtension.lowercased()) else {
            throw LocalUploadError("视频文件名或格式不适合上传。")
        }
        guard job.source.size > 0, job.source.size <= maximumBytes else {
            throw LocalUploadError("单个视频需大于 0 字节且不超过 20 GiB。")
        }
        guard var components = URLComponents(url: job.server, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw LocalUploadError("请先在设置中填写有效的服务器根地址。")
        }
        components.path = "/api/upload-file"
        // Escape + explicitly: Go's query parser treats an unescaped + as a space.
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: queryCharacters) else {
            throw LocalUploadError("无法编码文件名。")
        }
        components.percentEncodedQuery = "name=" + encoded
        guard let url = components.url else { throw LocalUploadError("上传地址无效。") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.allowsCellularAccess = job.allowsCellular
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(job.id.uuidString, forHTTPHeaderField: "X-Nice-Upload-ID")
        request.setValue(String(job.source.size), forHTTPHeaderField: "X-Nice-Upload-Bytes")
        request.setValue(String(job.source.size), forHTTPHeaderField: "Content-Length")
        return request
    }

    static func validateReceipt(_ data: Data, response: URLResponse?, job: LocalUploadJob) throws {
        guard let http = response as? HTTPURLResponse else { throw LocalUploadError("没有收到服务器确认。") }
        guard http.statusCode == 201 else {
            switch http.statusCode {
            case 404, 405: throw LocalUploadError("服务器尚未支持 App 上传，请更新 videos 服务并重启。")
            case 409: throw LocalUploadError("服务器已有同名项目，未覆盖。之前的上传也可能已完成，请核对服务器列表。")
            case 413: throw LocalUploadError("视频超过服务器或反向代理的上传大小限制。")
            case 429: throw LocalUploadError("服务器上传繁忙，请稍后重试。")
            case 507: throw LocalUploadError("服务器空间不足或无法写入，请检查空间和权限。")
            case 300..<400: throw LocalUploadError("上传地址发生重定向，已停止发送。请在设置中填写最终服务器地址。")
            default: throw LocalUploadError("上传未被服务器确认（HTTP \(http.statusCode)），请检查服务。")
            }
        }
        struct Receipt: Decodable { let version: Int; let uploadID: UUID; let name: String; let size: Int64 }
        guard data.count <= responseLimit, http.mimeType == "application/json",
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.version == 1, receipt.uploadID == job.id,
              receipt.name == job.source.name, receipt.size == job.source.size else {
            throw LocalUploadError("服务器确认内容不匹配，不能标记上传成功。请检查服务器列表后再决定是否重试。")
        }
    }
}

// Staged hard links protect an in-flight file without copying/packaging a large
// movie. Deleting the library entry cannot truncate the upload's immutable inode.
final class LocalUploadDisk {
    let root: URL
    private let fileManager = FileManager.default
    private var manifest: URL { root.appendingPathComponent("uploads.json") }
    private var staging: URL { root.appendingPathComponent("Staging", isDirectory: true) }
    private struct Manifest: Codable { let version: Int; let jobs: [LocalUploadJob] }

    init(root: URL) throws {
        self.root = root
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        #if os(iOS)
        var excluded = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        #endif
    }
    func load() throws -> [LocalUploadJob] {
        guard fileManager.fileExists(atPath: manifest.path) else { return [] }
        let value = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifest))
        guard value.version == 1, Set(value.jobs.map(\.id)).count == value.jobs.count else {
            throw LocalUploadError("上传记录版本或标识异常，原文件已保留。")
        }
        return value.jobs
    }
    func save(_ jobs: [LocalUploadJob]) throws {
        try JSONEncoder().encode(Manifest(version: 1, jobs: jobs)).write(to: manifest, options: .atomic)
    }
    func stagedFile(_ id: UUID) -> URL { staging.appendingPathComponent(id.uuidString + ".upload") }
    func prepare(source: URL, id: UUID, expectedBytes: Int64) throws -> URL {
        guard source.isFileURL, source.host == nil || source.host == "" || source.host == "localhost" else {
            throw LocalUploadError("只允许上传 App 内的本地文件。")
        }
        let attributes = try fileManager.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == expectedBytes else {
            throw LocalUploadError("本地视频缺失或大小已变化，请重新下载后上传。")
        }
        let destination = stagedFile(id)
        // Never replace an existing snapshot; every retry uses a new UUID.
        try fileManager.linkItem(at: source, to: destination)
        return destination
    }
    func removeSnapshot(_ id: UUID) throws {
        let url = stagedFile(id)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }
    // Only called on a fresh foreground URLSession process; no background-owned
    // task can still be reading these links. Unknown files are deliberately kept.
    func recoverAfterRelaunch() throws {
        for file in try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
        where file.pathExtension == "upload" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
            try fileManager.removeItem(at: file)
        }
    }
}
