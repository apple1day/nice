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

enum DownloadState: String, Codable { case downloading, complete, failed, missing }
struct DownloadRecord: Codable, Identifiable, Equatable {
    let id: String
    let video: Video
    let server: String
    var attempt: String
    var state: DownloadState
    var retryingMissingDownload: Bool?
    var message: String?
    // Optional fields keep old downloads.json files backward-compatible.
    // No timestamp is invented for existing downloads: their saved order is used.
    var pendingDeletionOrder: Int?
    var favorite: Bool?
    var downloadedAt: Date?
    // Relative to Documents/下载. A missing key identifies the private v1 layout.
    var publicFileName: String?
    var watched: Bool?
    var isFavorite: Bool { favorite == true }
    var hasWatched: Bool { watched == true }
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
        favorite = false
        downloadedAt = nil
        publicFileName = LocalStorage.suggestedFileName(for: video)
        watched = false
    }
}
struct DownloadManifest: Codable {
    var version = 1
    var records: [DownloadRecord]
}

enum PlaybackStartMode {
    case standard, panorama, afterglow
}

struct PlaybackRequest: Identifiable {
    let id = UUID()
    let key: String
    let title: String
    let url: URL
    let pickedFile: PickedVideoFile?
    let startMode: PlaybackStartMode
    // The visible list captured at the tap, before playback can change watched
    // flags. nil keeps compatibility with standalone callers of this request.
    let playlistIDs: [String]?
    init(key: String, title: String, url: URL, playlistIDs: [String]? = nil,
         startMode: PlaybackStartMode = .standard) throws {
        try OfflineMediaPolicy.validateLocalFile(url)
        self.key = key
        self.title = title
        self.url = url
        self.playlistIDs = playlistIDs
        pickedFile = nil
        self.startMode = startMode
    }

    // The Files picker already opened and validated this exact file. A provider
    // URL can move later; decoding uses the retained file instead of reopening it.
    init(pickedFile: PickedVideoFile, startMode: PlaybackStartMode = .standard) {
        self.startMode = startMode
        self.pickedFile = pickedFile
        url = pickedFile.url
        title = pickedFile.url.lastPathComponent
        let identity = pickedFile.url.standardizedFileURL.absoluteString + "\n" + String(pickedFile.byteCount)
        key = "files." + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        playlistIDs = [key]
    }
}

enum LocalDownloadFileStatus: Equatable { case available, absent, invalid, unavailable }

final class LocalStorage {
    let root: URL
    private let media: URL
    private let fm = FileManager.default
    // Optional instrumentation for regression tests; no file I/O or logging.
    private let onVerify: ((String) -> Void)?
    init(root: URL? = nil, documents: URL? = nil, onVerify: ((String) -> Void)? = nil) throws {
        self.onVerify = onVerify
        self.root = try root ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("NiceVideos", isDirectory: true)
        // Test stores keep their own Documents tree. The production location is
        // the app container's user-visible Documents directory, on the same volume.
        let documents = try documents ?? root?.appendingPathComponent("Documents", isDirectory: true)
            ?? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true)
        media = documents.appendingPathComponent("下载", isDirectory: true)
        try Self.createDirectory(self.root)
        // Files may have removed or temporarily blocked the downloads folder.
        // Keep the private manifest accessible. A new transfer retries creation
        // and surfaces the concrete error if the folder is still inaccessible.
        try? ensureMediaDirectory()
        var excluded = self.root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }

    private static func createDirectory(_ directory: URL) throws {
        if let type = try LocalRemovalTransaction.itemType(at: directory) {
            guard type == .typeDirectory else { throw ClientError("下载目录被其他文件占用。") }
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    }

    private func ensureMediaDirectory() throws {
        try Self.createDirectory(media)
        // Downloads can be fetched again. Keep their former backup policy after the move.
        var directory = media
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }

    static func suggestedFileName(for video: Video, number: Int = 1) -> String {
        let leaf = video.name.replacingOccurrences(of: "\\", with: "/") as NSString
        let stem = (leaf.lastPathComponent as NSString).deletingPathExtension
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: ":"))
        let clean = stem.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let suffix = (number == 1 ? "" : " (\(number))") + "." + video.fileExtension
        let budget = 255 - suffix.utf8.count
        var prefix = ""
        var bytes = 0
        for character in clean {
            let count = String(character).utf8.count
            guard bytes + count <= budget else { break }
            prefix.append(character)
            bytes += count
        }
        return (prefix.isEmpty ? "视频" : prefix) + suffix
    }

    private func checkedName(_ record: DownloadRecord) throws -> String {
        guard record.id.utf8.count == 64, record.id.allSatisfy({ "0123456789abcdef".contains($0) }),
              record.video.supportsOffline, let name = record.publicFileName,
              !name.hasPrefix("."), name.utf8.count <= 255,
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              name.rangeOfCharacter(from: .controlCharacters) == nil,
              (name as NSString).pathExtension.lowercased() == record.video.fileExtension else {
            throw ClientError("本地视频文件名或标识无效。")
        }
        return name
    }
    private static func nameKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive,
                                                           locale: Locale(identifier: "en_US_POSIX"))
    }
    private func unusedName(for record: DownloadRecord, reserved: Set<String>) -> String {
        if let name = try? checkedName(record), !reserved.contains(Self.nameKey(name)) { return name }
        var number = 1
        var name = Self.suggestedFileName(for: record.video)
        while reserved.contains(Self.nameKey(name)) {
            number += 1
            name = Self.suggestedFileName(for: record.video, number: number)
        }
        return name
    }
    func availableFileName(for record: DownloadRecord, among records: [DownloadRecord]) throws -> String {
        try ensureMediaDirectory()
        let occupied = try fm.contentsOfDirectory(atPath: media.path)
        let names = records.filter { $0.id != record.id }.compactMap(\.publicFileName)
        return unusedName(for: record, reserved: Set((occupied + names).map(Self.nameKey)))
    }

    // Write the entire filename assignment before renaming any payload. If the
    // app stops anywhere, public-only files are already indexed; the remaining
    // private files can be moved on the next launch. A user-created collision
    // gets a new destination even when it has exactly the expected byte count.
    func migrateLegacyDownloads(_ records: [DownloadRecord]) throws -> [DownloadRecord] {
        let legacy = root.appendingPathComponent("Media", isDirectory: true)
        var privateFiles = Set<String>()
        if let type = try LocalRemovalTransaction.itemType(at: legacy) {
            guard type == .typeDirectory else { throw ClientError("旧版视频目录异常，文件已保留。") }
            privateFiles = Set(try fm.contentsOfDirectory(atPath: legacy.path))
        }
        let indexes = records.indices.filter { records[$0].publicFileName == nil || privateFiles.contains(records[$0].fileName) }
        guard !indexes.isEmpty else { return records }
        try ensureMediaDirectory()
        let occupied = Set(try fm.contentsOfDirectory(atPath: media.path).map(Self.nameKey))
        var reserved = occupied.union(records.compactMap(\.publicFileName).map(Self.nameKey))
        var next = records
        var moves: [(URL, URL)] = []
        for i in indexes {
            var completedSource: URL?
            if privateFiles.contains(next[i].fileName) {
                let source = legacy.appendingPathComponent(next[i].fileName)
                let attrs = try fm.attributesOfItem(atPath: source.path)
                guard attrs[.type] as? FileAttributeType == .typeRegular else {
                    throw ClientError("旧版视频不是普通文件，已保留原件。")
                }
                // Older apps could leave truncated data behind. Keep it private
                // until the task is removed or its replacement finishes.
                if (attrs[.size] as? NSNumber)?.int64Value == next[i].video.size {
                    completedSource = source
                }
            }
            let nameOccupied = next[i].publicFileName.map { occupied.contains(Self.nameKey($0)) } ?? false
            if next[i].publicFileName == nil || (completedSource != nil && nameOccupied) {
                let name = unusedName(for: next[i], reserved: reserved)
                next[i].publicFileName = name
                reserved.insert(Self.nameKey(name))
            }
            let target = try destination(for: next[i])
            if let completedSource { moves.append((completedSource, target)) }
        }
        if next != records { try saveRecords(next) }
        for (source, target) in moves { try fm.moveItem(at: source, to: target) }
        return next
    }
    func loadRecords() throws -> [DownloadRecord] {
        let url = root.appendingPathComponent("downloads.json")
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            if Self.status(for: error) == .absent { return [] }
            throw error
        }
        let manifest = try JSONDecoder().decode(DownloadManifest.self, from: data)
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
        do { return try JSONDecoder().decode([String: [Video]].self, from: Data(contentsOf: url)) }
        catch {
            if Self.status(for: error) == .absent { return [:] }
            throw error
        }
    }
    func saveCatalogs(_ catalogs: [String: [Video]]) throws {
        try JSONEncoder().encode(catalogs)
            .write(to: root.appendingPathComponent("catalogs.json"), options: .atomic)
    }
    func destination(for record: DownloadRecord) throws -> URL {
        media.appendingPathComponent(try checkedName(record), isDirectory: false)
    }

    private static func status(for error: Error) -> LocalDownloadFileStatus {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            return .absent
        }
        if error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return .absent }
        return .unavailable
    }
    private static let mediaKeys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    private func status(at file: URL, size: Int64) -> LocalDownloadFileStatus {
        do {
            let values = try file.resourceValues(forKeys: Self.mediaKeys)
            guard let regular = values.isRegularFile else { return .unavailable }
            guard regular && values.isSymbolicLink != true else { return .invalid }
            guard let bytes = values.fileSize else { return .unavailable }
            return Int64(bytes) == size ? .available : .invalid
        } catch { return Self.status(for: error) }
    }
    func fileStatus(for record: DownloadRecord) -> LocalDownloadFileStatus {
        guard let url = try? destination(for: record) else { return .invalid }
        do {
            guard let type = try LocalRemovalTransaction.itemType(at: media) else { return .absent }
            guard type == .typeDirectory else { return .unavailable }
            return status(at: url, size: record.video.size)
        } catch { return Self.status(for: error) }
    }
    // Enumerate once, prefetching only file attributes. No movie payload is
    // opened and no completed-file verification is performed during row rendering.
    func fileStatuses(for records: [DownloadRecord]) -> [String: LocalDownloadFileStatus] {
        guard !records.isEmpty else { return [:] }
        do {
            guard let type = try LocalRemovalTransaction.itemType(at: media) else {
                return Dictionary(uniqueKeysWithValues: records.map { ($0.id, .absent) })
            }
            guard type == .typeDirectory else { throw ClientError("下载目录暂不可用。") }
            let files = try fm.contentsOfDirectory(at: media, includingPropertiesForKeys: Array(Self.mediaKeys))
            let byName = Dictionary(files.map { ($0.lastPathComponent, $0) },
                                    uniquingKeysWith: { first, _ in first })
            let spellings = Set(files.map { Self.nameKey($0.lastPathComponent) })
            return Dictionary(uniqueKeysWithValues: records.map { record in
                guard let name = try? checkedName(record) else { return (record.id, .invalid) }
                if let exact = byName[name] { return (record.id, status(at: exact, size: record.video.size)) }
                // A case-only rename may still resolve on a case-insensitive
                // volume; always verify the same path that playback would open.
                guard spellings.contains(Self.nameKey(name)) else { return (record.id, .absent) }
                return (record.id, status(at: media.appendingPathComponent(name), size: record.video.size))
            })
        } catch {
            let state = Self.status(for: error)
            return Dictionary(uniqueKeysWithValues: records.map { ($0.id, state) })
        }
    }
    func verifiedFile(for record: DownloadRecord) -> URL? {
        onVerify?(record.id)
        guard fileStatus(for: record) == .available else { return nil }
        return try? destination(for: record)
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
        try ensureMediaDirectory()
        // Apply protection before publication. Never replace a file the user
        // moved into the reserved path while the background transfer was active.
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temp.path)
        // URLSession owns `temp`: move it synchronously before its delegate returns.
        try fm.moveItem(at: temp, to: file)
        // Only old builds wrote partial downloads to this private location.
        let partial = legacyFile(for: record)
        if (try? LocalRemovalTransaction.itemType(at: partial)) == .typeRegular {
            try? fm.removeItem(at: partial)
        }
    }
    private func legacyFile(for record: DownloadRecord) -> URL {
        root.appendingPathComponent("Media", isDirectory: true).appendingPathComponent(record.fileName)
    }
    func remove(_ record: DownloadRecord) throws {
        let file = try destination(for: record)
        guard let type = try LocalRemovalTransaction.itemType(at: media) else { return }
        guard type == .typeDirectory else { throw ClientError("下载目录异常。") }
        guard let item = try LocalRemovalTransaction.itemType(at: file) else { return }
        guard item == .typeRegular else { throw ClientError("视频路径不是普通文件。") }
        try fm.removeItem(at: file)
    }

    // Returns only after the prospective records/queue have committed. A failed
    // write rolls the video back. Never delete a file first and then hope to save.
    func removeAndSave(_ record: DownloadRecord, records: [DownloadRecord]) throws -> String? {
        guard !records.contains(where: { $0.id == record.id }) else {
            throw ClientError("删除事务仍然引用原视频，已停止删除。")
        }
        if let type = try LocalRemovalTransaction.itemType(at: media), type != .typeDirectory {
            throw ClientError("下载目录异常，已停止删除。")
        }
        let publicFile = try destination(for: record)
        var fileToStage = legacyFile(for: record)
        var keptPublicFile = false
        if let type = try LocalRemovalTransaction.itemType(at: publicFile) {
            guard type == .typeRegular else { throw ClientError("视频路径不是普通文件，已停止删除。") }
            // URLSession never writes partial downloads to the shared directory.
            // An occupied path for an unfinished task, or a changed-size file,
            // may belong to the user. Only remove the private task in that case.
            let size = try fm.attributesOfItem(atPath: publicFile.path)[.size] as? NSNumber
            if record.state == .complete && size?.int64Value == record.video.size {
                fileToStage = publicFile
            } else { keptPublicFile = true }
        }
        let warning = try LocalRemovalTransaction.commit(file: fileToStage,
            staged: root.appendingPathComponent("RemovalStaging", isDirectory: true)
                .appendingPathComponent(record.fileName)
        ) { try self.saveRecords(records) }
        return warning ?? (keptPublicFile ? "下载记录已移除，目录中已有的文件已保留。" : nil)
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
        let referenced = Dictionary(uniqueKeysWithValues: records.map { ($0.fileName, $0) })
        for staged in files {
            let id = staged.deletingPathExtension().lastPathComponent
            guard id.count == 64, id.allSatisfy({ "0123456789abcdef".contains($0) }),
                  OfflineMediaPolicy.extensions.contains(staged.pathExtension) else {
                throw ClientError("删除暂存目录存在未知文件，已保留并停止自动处理。")
            }
            let record = referenced[staged.lastPathComponent]
            // A build-20 deletion could have staged the private file before its
            // index was committed. Restore that transaction before public migration.
            var file = root.appendingPathComponent("Media", isDirectory: true)
                .appendingPathComponent(staged.lastPathComponent)
            let size = try fm.attributesOfItem(atPath: staged.path)[.size] as? NSNumber
            if let record, record.publicFileName != nil, size?.int64Value == record.video.size {
                try ensureMediaDirectory()
                file = try destination(for: record)
            } else if record != nil {
                try Self.createDirectory(file.deletingLastPathComponent())
            }
            try LocalRemovalTransaction.recover(file: file, staged: staged, isReferenced: record != nil)
            if record == nil { onCommittedRemoval(id) }
        }
    }
}
