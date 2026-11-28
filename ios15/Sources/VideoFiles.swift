import CryptoKit
import Darwin
import Foundation

struct Video: Codable, Identifiable, Equatable, Sendable {
    let name: String
    let size: Int64
    let contentType: String
    let downloadUrl: String
    var id: String { name }

    private static let extensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "webm", "ogg", "flv", "wmv", "ts"
    ]
    var supported: Bool {
        size > 0 && Self.extensions.contains((name as NSString).pathExtension.lowercased())
            && !contentType.lowercased().contains("mpegurl")
    }
}

struct Envelope: Decodable { let videos: [Video] }

struct CatalogEntry: Identifiable, Equatable, Sendable {
    let video: Video
    let filename: String
    let supported: Bool
    var id: String { video.name }
}

struct LocalVideo: Identifiable, Equatable, Sendable {
    let url: URL
    let size: Int64
    let name: String
    var id: URL { url }

    init(url: URL, size: Int64) {
        self.url = url
        self.size = size
        self.name = url.lastPathComponent
    }
}

struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

actor VideoFiles {
    private let manager = FileManager.default
    private let customFolder: URL?
    private lazy var folder = customFolder ?? manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Downloads", isDirectory: true)
    private var backupExcluded = false
    private static let hexDigits = Array("0123456789abcdef".utf8)

    init(folder: URL? = nil) {
        customFolder = folder
    }

    func catalog(data: Data, base: URL) throws -> [CatalogEntry] {
        let videos = try JSONDecoder().decode(Envelope.self, from: data).videos
        var names = Set<String>()
        return videos.compactMap { video in
            guard names.insert(video.name).inserted else { return nil }
            // Keep the on-disk identity used by previous releases and their saved deletion marks.
            let key = base.absoluteString + "\n" + video.name + "\n" + String(video.size)
            var hex: [UInt8] = []
            hex.reserveCapacity(16)
            for byte in SHA256.hash(data: Data(key.utf8)).prefix(8) {
                hex.append(Self.hexDigits[Int(byte >> 4)])
                hex.append(Self.hexDigits[Int(byte & 0x0f)])
            }
            let prefix = String(decoding: hex, as: UTF8.self)
            let basename = String((video.name as NSString).lastPathComponent.prefix(100))
                .replacingOccurrences(of: "/", with: "_")
            return CatalogEntry(video: video, filename: prefix + "_" + basename, supported: video.supported)
        }
    }

    func scan() throws -> [LocalVideo] {
        try prepareFolder()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let urls = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys),
                                                  options: [.skipsHiddenFiles])
        return try urls.compactMap { url -> LocalVideo? in
            do {
                let values = try url.resourceValues(forKeys: keys)
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize else { return nil }
                return LocalVideo(url: url, size: Int64(size))
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                return nil // A Files app edit may race the directory enumeration.
            }
        }.sorted { $0.name < $1.name }
    }

    func existing(_ entry: CatalogEntry) throws -> LocalVideo? {
        let url = folder.appendingPathComponent(entry.filename, isDirectory: false)
        guard let info = try metadata(at: url), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size == entry.video.size else { return nil }
        return LocalVideo(url: url, size: info.st_size)
    }

    func install(_ temporary: URL, response: URLResponse, entry: CatalogEntry) throws -> LocalVideo {
        defer { try? manager.removeItem(at: temporary) }
        let mime = response.mimeType?.lowercased() ?? ""
        guard (response as? HTTPURLResponse)?.statusCode == 200, let info = try metadata(at: temporary),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size == entry.video.size,
              !mime.hasPrefix("text/"), !mime.contains("json"), !mime.contains("mpegurl") else {
            throw Failure(message: "下载失败或文件大小不一致，请刷新列表重试")
        }
        try prepareFolder()
        let target = folder.appendingPathComponent(entry.filename, isDirectory: false)
        if let old = try metadata(at: target), old.st_mode & mode_t(S_IFMT) != mode_t(S_IFREG) {
            throw Failure(message: "同名位置不是普通文件")
        }
        // URLSession's temporary file and Documents are on the app's data volume.
        // Rename atomically publishes the completed file, including when replacing a partial copy.
        guard Darwin.rename(temporary.path, target.path) == 0 else { throw posixError() }
        return LocalVideo(url: target, size: info.st_size)
    }

    func verified(_ entry: CatalogEntry) throws -> Bool {
        guard entry.supported else { return false }
        let url = folder.appendingPathComponent(entry.filename, isDirectory: false)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT || errno == ELOOP { return false }
            throw posixError()
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size == entry.video.size else { return false }
        let length = Int(min(512, info.st_size))
        guard let header = try handle.read(upToCount: length), header.count == length else { return false }
        let whitespace = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}"))
        let prefix = String(decoding: header, as: UTF8.self).trimmingCharacters(in: whitespace).lowercased()
        return !["#extm3u", "<html", "<!doctype", "<?xml", "<mpd", "{", "["].contains { prefix.hasPrefix($0) }
    }

    func remove(_ items: [LocalVideo]) -> [LocalVideo] {
        // Pin the parent directory for the entire operation. unlinkat without AT_REMOVEDIR
        // never recursively removes a directory that replaced a listed file.
        let directory = Darwin.open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { return errno == ENOENT ? items : [] }
        defer { Darwin.close(directory) }
        let folderPath = folder.standardizedFileURL.path
        return items.filter { item in
            guard item.url.deletingLastPathComponent().standardizedFileURL.path == folderPath else { return false }
            var info = stat()
            guard fstatat(directory, item.name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return errno == ENOENT }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size == item.size else { return false }
            return unlinkat(directory, item.name, 0) == 0 || errno == ENOENT
        }
    }

    private func prepareFolder() throws {
        if let directory = try metadata(at: folder) {
            guard directory.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw Failure(message: "下载目录不可用")
            }
            if backupExcluded { return }
        } else {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        var url = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        backupExcluded = true
    }

    private func metadata(at url: URL) throws -> stat? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return info }
        if errno == ENOENT { return nil }
        throw posixError()
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
