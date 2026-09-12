import Foundation

extension ServerAddress {
    static func deleteEndpoint(for video: Video, on server: URL) throws -> URL {
        // Reuse the API-provided encoded filename instead of encoding `name`
        // again. This keeps Chinese, spaces, +, %, and # consistent with the
        // existing Go server's url.PathEscape output.
        let prefix = "/api/download/"
        guard video.downloadUrl.hasPrefix(prefix) else {
            throw ClientError("服务器返回的视频下载地址格式异常，无法安全生成删除地址。")
        }
        let encodedName = String(video.downloadUrl.dropFirst(prefix.count))
        guard !encodedName.isEmpty,
              !encodedName.contains("/"),
              !encodedName.contains("?"),
              !encodedName.contains("#") else {
            throw ClientError("服务器返回的视频文件名格式异常，已取消删除。")
        }
        return try endpoint("/api/videos/" + encodedName, on: server)
    }
}

extension VideoStore {
    @MainActor
    func deleteServerVideo(_ video: Video) async throws {
        guard !server.isEmpty else { throw ClientError("请先配置视频服务器。") }
        if let record = record(for: video), record.state == .downloading {
            throw ClientError("这个视频正在下载。请先在“下载任务”中取消下载，再删除服务器源文件。")
        }

        let selectedServer = server
        let base = try ServerAddress.normalize(selectedServer)
        var request = URLRequest(url: try ServerAddress.deleteEndpoint(for: video, on: base))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError("删除失败：服务器响应无效。")
        }
        guard (200..<300).contains(http.statusCode) else {
            let serverMessage = (try? JSONSerialization.jsonObject(with: data))
                .flatMap { $0 as? [String: Any] }?["error"] as? String
            if http.statusCode == 404 {
                throw ClientError("服务器视频已经不存在，请刷新列表。")
            }
            throw ClientError(serverMessage.map { "删除失败：\($0)" } ?? "删除失败：HTTP \(http.statusCode)。")
        }

        // The local DownloadRecord/file is deliberately untouched. Refresh only
        // the remote catalog, and only if the user has not switched servers.
        if server == selectedServer {
            refresh()
        }
    }
}
