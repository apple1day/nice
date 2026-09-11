import Foundation

// No network/framework dependency: shared by the store, VLC adapter, and tests.
enum OfflineMediaPolicy {
    static let extensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "avi", "webm", "ogg", "flv", "wmv", "ts"
    ]
    static func supports(name: String, size: Int64, contentType: String) -> Bool {
        let mime = contentType.lowercased()
        return size > 0 && extensions.contains((name as NSString).pathExtension.lowercased())
            && !mime.contains("mpegurl") && !mime.contains("dash+xml")
            && !mime.hasPrefix("text/") && !mime.contains("json")
    }

    enum Failure: LocalizedError {
        case remoteURL, unsupported, missingFile, playlist
        var errorDescription: String? {
            switch self {
            case .remoteURL: return "播放器只接受手机本地文件。请先下载，不支持在线播放。"
            case .unsupported: return "此格式不是当前支持的完整视频文件。HLS/DASH 清单不能单独离线播放。"
            case .missingFile: return "本地文件不存在、为空或不是普通文件，请重新下载。"
            case .playlist: return "文件内容是播放清单或错误文本，不是独立视频，已拒绝播放。"
            }
        }
    }

    static func validateLocalFile(_ url: URL) throws {
        // Reject file://remote-host, network URLs, directories and symbolic links.
        guard url.isFileURL, (url.host ?? "").isEmpty || url.host == "localhost" else {
            throw Failure.remoteURL
        }
        guard extensions.contains(url.pathExtension.lowercased()) else { throw Failure.unsupported }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes?[.type] as? FileAttributeType == .typeRegular,
              let size = attributes?[.size] as? NSNumber, size.int64Value > 0 else {
            throw Failure.missingFile
        }
        try rejectTextPayload(at: url)
    }

    // A cheap guard against saved HTML/JSON and playlists disguised as .mp4.
    // It is not a decoder or a cryptographic integrity check.
    static func rejectTextPayload(at url: URL) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let header = try file.read(upToCount: 512) ?? Data()
        let text = String(decoding: header, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
            .lowercased()
        let prefixes = ["#extm3u", "[playlist]", "<?xml", "<mpd", "<asx", "<html", "<!doctype", "{", "["]
        if prefixes.contains(where: { text.hasPrefix($0) }) { throw Failure.playlist }
    }
}

enum PlaybackPosition {
    static func resume(saved: Double, duration: Double) -> Double? {
        guard saved.isFinite, duration.isFinite, saved > 1, duration > 3,
              saved < duration - 3 else { return nil }
        return saved
    }
    static func clamp(_ seconds: Double, duration: Double) -> Double? {
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return nil }
        return min(max(0, seconds), max(0, duration - 0.1))
    }
    static func label(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "00:00" }
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}
