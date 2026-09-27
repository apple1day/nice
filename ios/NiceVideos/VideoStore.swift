import Foundation
import Combine

// Main-queue confined, including URLSession delegate callbacks. Swift 5 mode.
final class VideoStore: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = VideoStore()
    static let sessionID = (Bundle.main.bundleIdentifier ?? "com.anxiong.nicevideos") + ".downloads.v1"
    @Published private(set) var server: String
    @Published private(set) var videos: [Video] = []
    @Published private(set) var records: [DownloadRecord] = [] {
        didSet { rebuildRecordCache() }
    }
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var loading = false
    @Published private(set) var restoring = true
    @Published private(set) var catalogNotice: String?
    @Published private(set) var deletionNotice: String?
    @Published var errorMessage: String?
    @Published var playback: PlaybackRequest?
    var backgroundCompletion: (() -> Void)?
    private let defaults: UserDefaults
    private var disk: LocalStorage?
    private var recordsByID: [String: DownloadRecord] = [:]
    private var completedCache: [DownloadRecord] = []
    private var unfinishedCache: [DownloadRecord] = []
    private var pendingCache: [DownloadRecord] = []
    private var usedBytesCache: Int64 = 0
    // Keep the lease until the engine closes, including cover dismissal.
    private var playbackSession: PlaybackRequest?
    private var catalogs: [String: [Video]] = [:]
    private var active: [String: URLSessionDownloadTask] = [:]
    private var lastProgress: [String: Date] = [:]
    private var refreshTask: Task<Void, Never>?
    private var refreshID = UUID()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.allowsCellularAccess = true
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    init(storage: LocalStorage? = nil, defaults: UserDefaults = .standard, restoreDownloads: Bool = true) {
        self.defaults = defaults
        server = defaults.string(forKey: "server") ?? ""
        super.init()
        do {
            let storage = try storage ?? LocalStorage()
            records = try storage.loadRecords()
            try storage.recoverRemovals(records: records) { id in
                defaults.removeObject(forKey: "position." + id)
            }
            disk = storage
            migrateLegacyWatchFlags()
            do { catalogs = try storage.loadCatalogs() }
            catch { catalogNotice = "列表缓存读取失败；本地下载不受影响。" }
            videos = catalogs[server] ?? []
            // A completed manifest entry is displayed without stat/open. Only
            // interrupted transfers need startup recovery. Explicit play validates
            // its target; the active root never rescans all files on foreground.
            reconcileFiles(ids: Set(unfinishedCache.map(\.id)))
        } catch { errorMessage = "本地存储读取失败：\(error.localizedDescription)" }
        if restoreDownloads { restoreTransfers() } else { restoring = false }
    }

    private func rebuildRecordCache() {
        recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        completedCache = records.filter { $0.state == .complete }
        unfinishedCache = records.filter { $0.state != .complete }
        usedBytesCache = completedCache.reduce(0) { $0 + $1.video.size }
        pendingCache = records.filter { $0.pendingDeletionOrder != nil }.sorted {
            let a = $0.pendingDeletionOrder ?? 0
            let b = $1.pendingDeletionOrder ?? 0
            return a == b ? $0.id < $1.id : a < b
        }
    }
    var completed: [DownloadRecord] { completedCache }
    var unfinished: [DownloadRecord] { unfinishedCache }
    var usedBytes: Int64 { usedBytesCache }

    private func migrateLegacyWatchFlags() {
        guard let disk = disk else { return }
        var next = records
        for index in next.indices where next[index].watched == nil {
            let position = defaults.double(forKey: "position." + next[index].id)
            if position.isFinite && position > 0 { next[index].watched = true }
        }
        guard next != records else { return }
        do { try disk.saveRecords(next); records = next }
        catch { errorMessage = "旧观看标记保存失败，原索引已保留：\(error.localizedDescription)" }
    }
    // Called only by a live engine after playing with video output, once per clip.
    // No video-file checks, no changes to download order, favorites or deletion.
    func markWatched(_ id: String) {
        guard playbackSession?.key == id,
              let index = records.firstIndex(where: { $0.id == id }),
              records[index].state == .complete, !records[index].hasWatched,
              let disk = disk else { return }
        var next = records
        next[index].watched = true
        do { try disk.saveRecords(next); records = next }
        catch { errorMessage = "观看标记保存失败：\(error.localizedDescription)" }
    }

    func configureServer(_ input: String) {
        do {
            let base = try ServerAddress.normalize(input)
            server = base.absoluteString
            defaults.set(server, forKey: "server")
            videos = catalogs[server] ?? []
            refresh()
        } catch { errorMessage = error.localizedDescription }
    }
    func refresh() {
        guard !server.isEmpty else { return }
        refreshTask?.cancel()
        let generation = UUID()
        refreshID = generation
        let selectedServer = server
        loading = true
        refreshTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            defer { if self.refreshID == generation { self.loading = false } }
            do {
                let base = try ServerAddress.normalize(selectedServer)
                var request = URLRequest(url: try ServerAddress.endpoint("/api/videos", on: base))
                request.timeoutInterval = 15
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, response) = try await URLSession.shared.data(for: request)
                try Task.checkCancellation()
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw ClientError("列表请求失败：HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)。")
                }
                let result = try JSONDecoder().decode(VideoEnvelope.self, from: data)
                guard Set(result.videos.map(\.name)).count == result.videos.count else {
                    throw ClientError("服务器返回重复文件名，无法安全建立下载索引。")
                }
                guard self.refreshID == generation, self.server == selectedServer else { return }
                self.videos = result.videos
                self.catalogs[selectedServer] = result.videos
                self.catalogNotice = nil
                do { try self.disk?.saveCatalogs(self.catalogs) }
                catch { self.catalogNotice = "列表已更新，但缓存写入失败：\(error.localizedDescription)" }
            } catch is CancellationError {
                // Superseded by a server switch or a newer request.
            } catch {
                guard self.refreshID == generation else { return }
                self.catalogNotice = "无法连接服务器，保留上次列表。本地播放不受影响。\n\(error.localizedDescription)"
            }
        }
    }
    func record(for video: Video) -> DownloadRecord? {
        guard let base = try? ServerAddress.normalize(server) else { return nil }
        // Hash once, not once for every record in a linear search.
        return recordsByID[video.storageID(server: base)]
    }
    func download(_ video: Video) {
        do { try begin(video, from: ServerAddress.normalize(server)) }
        catch { errorMessage = error.localizedDescription }
    }
    func downloadAll() {
        do {
            let base = try ServerAddress.normalize(server)
            for video in videos where video.supportsOffline { try begin(video, from: base) }
        } catch { errorMessage = "部分下载未能加入队列：\(error.localizedDescription)" }
    }
    func retry(_ record: DownloadRecord) {
        do { try begin(record.video, from: ServerAddress.normalize(record.server)) }
        catch { errorMessage = error.localizedDescription }
    }
    private func begin(_ video: Video, from base: URL) throws {
        guard !restoring else { throw ClientError("正在恢复下载任务；本地播放不受影响。") }
        guard let disk = disk else { throw ClientError("本地存储不可用，无法开始下载。") }
        guard video.supportsOffline else { throw OfflineMediaPolicy.Failure.unsupported }
        try disk.recoverRemovals(records: records) { id in
            defaults.removeObject(forKey: "position." + id)
        }
        let id = video.storageID(server: base)
        let existing = recordsByID[id]
        if let existing = existing {
            if existing.state == .downloading { return }
            if existing.state == .complete, disk.verifiedFile(for: existing) != nil { return }
        }
        guard !isPlaybackProtected(id) else {
            throw ClientError("请先关闭正在播放的视频，再重新下载。")
        }
        var request = URLRequest(url: try ServerAddress.endpoint(video.downloadUrl, on: base))
        request.allowsCellularAccess = defaults.bool(forKey: "allowCellular")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        var record = DownloadRecord(video: video, server: base)
        record.favorite = existing?.favorite ?? false
        record.watched = existing?.watched ?? false
        let previous = records
        var next = records.filter { $0.id != id }
        next.append(record)
        try disk.saveRecords(next)
        records = next
        let task = session.downloadTask(with: request)
        task.taskDescription = record.taskToken
        task.countOfBytesClientExpectsToReceive = video.size
        active[id] = task
        progress[id] = 0
        task.resume()
        _ = previous // The prior manifest is never published away before a successful save.
    }
    func cancel(_ record: DownloadRecord) {
        guard let index = records.firstIndex(where: { $0.taskToken == record.taskToken }),
              records[index].state == .downloading else { return }
        var next = records
        next[index].state = .failed
        next[index].message = "已取消。重新下载会从头开始。"
        records = next
        active.removeValue(forKey: record.id)?.cancel()
        progress.removeValue(forKey: record.id)
        lastProgress.removeValue(forKey: record.id)
        saveRecords()
    }
    func removeFromDevice(_ record: DownloadRecord) {
        guard let current = recordsByID[record.id], current.taskToken == record.taskToken else { return }
        do {
            let warning = try deleteLocally(current, saving: records.filter { $0.id != current.id })
            deletionNotice = warning ?? "已删除手机副本：\(current.video.name)"
        } catch { errorMessage = "删除本地文件失败：\(error.localizedDescription)" }
    }
    func isFavorite(_ id: String) -> Bool { recordsByID[id]?.isFavorite == true }
    @discardableResult func toggleFavorite(_ id: String) -> Bool {
        do {
            guard let disk = disk else { throw ClientError("本地存储不可用。") }
            guard let index = records.firstIndex(where: { $0.id == id }),
                  records[index].state == .complete,
                  disk.verifiedFile(for: records[index]) != nil else {
                throw ClientError("只能收藏已经下载完成且存在的本地视频。")
            }
            var next = records
            next[index].favorite = !next[index].isFavorite
            let result = next[index].isFavorite
            try disk.saveRecords(next)
            records = next
            return result
        } catch {
            errorMessage = "更新收藏状态失败：\(error.localizedDescription)"
            return isFavorite(id)
        }
    }
    func play(_ video: Video) {
        guard let record = record(for: video), record.state == .complete else {
            errorMessage = "请先下载视频，下载完成后才能本地播放。"
            return
        }
        playLocal(record)
    }
    func playLocal(_ record: DownloadRecord) {
        guard playbackSession == nil && playback == nil else { return }
        do {
            let request = try localPlaybackRequest(for: record.id)
            playbackSession = request
            deletionNotice = nil
            playback = request
        } catch {
            errorMessage = error.localizedDescription
            reconcileFiles(ids: [record.id])
        }
    }
    // Compatibility accessor: metadata only; opening a target still validates it.
    var localPlaylistRecords: [DownloadRecord] { completedCache }
    func localPlaybackRequest(for id: String) throws -> PlaybackRequest {
        guard let record = recordsByID[id],
              record.state == .complete, let file = disk?.verifiedFile(for: record) else {
            throw ClientError("本地文件缺失或下载未完成，请重新下载。")
        }
        return try PlaybackRequest(key: record.id, title: record.video.name, url: file)
    }
    func transitionPlayback(from old: PlaybackRequest, to next: PlaybackRequest,
                            stopCurrent: () -> Void) throws {
        guard playback != nil, playbackSession?.id == old.id else {
            throw ClientError("播放会话已结束，请重新打开本地视频。")
        }
        let verified = try localPlaybackRequest(for: next.key)
        guard verified.url == next.url else { throw ClientError("播放文件与本地索引不一致。") }
        stopCurrent()
        playbackSession = next
        deletionNotice = nil
    }
    private func isPlaybackProtected(_ id: String) -> Bool {
        if let current = playbackSession { return current.key == id }
        return playback?.key == id
    }
    func playbackDidClose(_ request: PlaybackRequest) {
        if playbackSession?.id == request.id {
            playbackSession = nil
            playback = nil
        } else if playbackSession == nil && playback?.id == request.id {
            playback = nil
        }
    }
    // Explicit maintenance only when ids is nil. Playback/list rendering never
    // calls this with all records. Mutations are published once, not per file.
    func reconcileFiles(ids: Set<String>? = nil) {
        guard let disk = disk else { return }
        var next = records
        for i in next.indices where ids?.contains(next[i].id) ?? true {
            if disk.verifiedFile(for: next[i]) != nil {
                if next[i].state != .complete {
                    next[i].state = .complete
                    next[i].message = nil
                    if next[i].downloadedAt == nil { next[i].downloadedAt = Date() }
                }
            } else if next[i].state == .complete {
                next[i].state = .failed
                next[i].message = "本地文件缺失或大小异常，请重新下载。"
            }
        }
        if next != records { records = next; saveRecords() }
    }
    private func saveRecords() {
        do { try disk?.saveRecords(records) }
        catch { errorMessage = "下载索引保存失败：\(error.localizedDescription)" }
    }
    private func restoreTransfers() {
        session.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                guard let self = self else { return }
                var live = Set<String>()
                for task in tasks {
                    guard let download = task as? URLSessionDownloadTask,
                          let index = self.index(for: task), self.records[index].state == .downloading else {
                        task.cancel(); continue
                    }
                    let record = self.records[index]
                    live.insert(record.taskToken)
                    self.active[record.id] = download
                    if download.state == .suspended { download.resume() }
                }
                var next = self.records
                for i in next.indices where next[i].state == .downloading {
                    if !live.contains(next[i].taskToken) {
                        next[i].state = .failed
                        next[i].message = "系统中已无此下载任务，可能被强制退出中断，可重新下载。"
                    }
                }
                if next != self.records { self.records = next }
                self.restoring = false
                self.saveRecords()
            }
        }
    }
    private func index(for task: URLSessionTask) -> Int? {
        guard let token = task.taskDescription else { return nil }
        return records.firstIndex { $0.taskToken == token }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let index = index(for: downloadTask), records[index].state == .downloading else { return }
        let id = records[index].id
        let now = Date()
        guard now.timeIntervalSince(lastProgress[id] ?? .distantPast) > 0.25 else { return }
        lastProgress[id] = now
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : records[index].video.size
        progress[id] = min(1, max(0, Double(totalBytesWritten) / Double(max(1, expected))))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let index = index(for: downloadTask), records[index].state == .downloading else { return }
        let record = records[index]
        var next = records
        do {
            guard let disk = disk else { throw ClientError("本地存储不可用。") }
            try disk.finish(temp: location, response: downloadTask.response, record: record)
            next[index].state = .complete
            next[index].message = nil
            next[index].downloadedAt = Date()
            progress[record.id] = 1
        } catch {
            next[index].state = .failed
            next[index].message = error.localizedDescription
        }
        records = next
        active.removeValue(forKey: record.id)
        lastProgress.removeValue(forKey: record.id)
        saveRecords()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let index = index(for: task), records[index].state == .downloading, let error = error else { return }
        var next = records
        next[index].state = .failed
        next[index].message = error.localizedDescription + "；可重新下载（从头开始）。"
        let id = next[index].id
        records = next
        active.removeValue(forKey: id)
        progress.removeValue(forKey: id)
        lastProgress.removeValue(forKey: id)
        saveRecords()
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = backgroundCompletion
        backgroundCompletion = nil
        completion?()
    }
}

extension VideoStore {
    var pendingDeletionRecords: [DownloadRecord] { pendingCache }
    func isPendingDeletion(_ id: String) -> Bool { recordsByID[id]?.pendingDeletionOrder != nil }
    @discardableResult func markForDeletion(_ id: String) -> Bool {
        do {
            guard let disk = disk else { throw ClientError("本地存储不可用。") }
            guard let record = recordsByID[id], record.state == .complete,
                  disk.verifiedFile(for: record) != nil else {
                throw ClientError("只能把下载完成且存在的本地视频加入待删除列表。")
            }
            if isPendingDeletion(id) { return true }
            let ids = pendingDeletionRecords.map(\.id) + [id]
            let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
            var next = records
            for index in next.indices { next[index].pendingDeletionOrder = order[next[index].id] }
            try disk.saveRecords(next)
            records = next
            deletionNotice = "已加入待删除列表（\(ids.count) 个），请在列表顶部点击“删除待删除”。"
            return true
        } catch {
            errorMessage = "未加入待删除列表，原列表保留：\(error.localizedDescription)"
            return false
        }
    }
    @discardableResult func unmarkForDeletion(_ id: String) -> Bool {
        guard isPendingDeletion(id) else { return true }
        do {
            guard let disk = disk else { throw ClientError("本地存储不可用。") }
            let ids = pendingDeletionRecords.map(\.id).filter { $0 != id }
            let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
            var next = records
            for index in next.indices { next[index].pendingDeletionOrder = order[next[index].id] }
            try disk.saveRecords(next)
            records = next
            deletionNotice = "已撤销待删除，手机文件保留。"
            return true
        } catch {
            errorMessage = "撤销待删除失败：\(error.localizedDescription)"
            return false
        }
    }
    // A stale confirmation must not delete a fresh re-download of the same ID.
    @discardableResult func deletePendingVideos(_ snapshot: [DownloadRecord]) -> Int {
        let tokens = Set(snapshot.map(\.taskToken))
        let ids = pendingDeletionRecords.filter { tokens.contains($0.taskToken) }.map(\.id)
        return deleteAllPendingVideos(ids: ids)
    }
    @discardableResult func deleteAllPendingVideos(ids: [String]? = nil) -> Int {
        let selected = ids.map { Set($0) }
        let queue = pendingDeletionRecords.filter { selected?.contains($0.id) ?? true }
        guard !queue.isEmpty else { return 0 }
        var deleted = 0
        var failures: [String] = []
        var warnings: [String] = []
        for record in queue {
            do {
                if let warning = try deleteLocally(record, saving: records.filter { $0.id != record.id }) {
                    warnings.append(warning)
                }
                deleted += 1
            } catch { failures.append("\(record.video.name)：\(error.localizedDescription)") }
        }
        deletionNotice = "已删除 \(deleted) 个待删除手机副本，剩余 \(pendingDeletionRecords.count) 个。"
        if !failures.isEmpty || !warnings.isEmpty {
            errorMessage = (["部分项目未删除或空间回收未完成，详情如下："] + failures + warnings).joined(separator: "\n")
        }
        return deleted
    }
    private func deleteLocally(_ record: DownloadRecord, saving next: [DownloadRecord]) throws -> String? {
        guard !isPlaybackProtected(record.id) else {
            throw ClientError("此视频仍在播放，请先关闭播放器后重试。")
        }
        guard let disk = disk else { throw ClientError("本地存储不可用。") }
        try disk.recoverRemovals(records: records) { id in
            defaults.removeObject(forKey: "position." + id)
        }
        let warning = try disk.removeAndSave(record, records: next)
        records = next
        active.removeValue(forKey: record.id)?.cancel()
        progress.removeValue(forKey: record.id)
        lastProgress.removeValue(forKey: record.id)
        defaults.removeObject(forKey: "position." + record.id)
        return warning
    }
}
