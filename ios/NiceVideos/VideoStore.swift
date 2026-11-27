import Foundation
import Combine

private extension DownloadRecord {
    mutating func failTransfer(_ reason: String) {
        state = retryingMissingDownload == true ? .missing : .failed
        retryingMissingDownload = nil
        message = reason
    }
}

// Main-queue confined, including URLSession delegate callbacks. Swift 5 mode.
final class VideoStore: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = VideoStore()
    static let sessionID = (Bundle.main.bundleIdentifier ?? "com.anxiong.nicevideos") + ".downloads.v1"
    @Published private(set) var server: String
    @Published private(set) var servers: [String]
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
    private var queuedCompatibleCopy: PickedVideoFile?
    private var catalogs: [String: [Video]] = [:]
    private var active: [String: URLSessionDownloadTask] = [:]
    private var lastProgress: [String: Date] = [:]
    private var refreshTask: Task<Void, Never>?
    private var refreshID = UUID()
    private var fileRefreshID = UUID()
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
        let currentServer = defaults.string(forKey: "server") ?? ""
        let storedServers = defaults.stringArray(forKey: "servers") ?? []
        var normalizedServers: [String] = []
        for candidate in storedServers + (currentServer.isEmpty ? [] : [currentServer]) {
            guard let normalized = try? ServerAddress.normalize(candidate).absoluteString,
                  !normalizedServers.contains(normalized) else { continue }
            normalizedServers.append(normalized)
        }
        server = (try? ServerAddress.normalize(currentServer).absoluteString) ?? ""
        servers = normalizedServers
        super.init()
        defaults.set(servers, forKey: "servers")
        do {
            let storage = try storage ?? LocalStorage()
            records = try storage.loadRecords()
            try storage.recoverRemovals(records: records) { id in
                defaults.removeObject(forKey: "position." + id)
            }
            records = try storage.migrateLegacyDownloads(records)
            disk = storage
            migrateLegacyWatchFlags()
            do { catalogs = try storage.loadCatalogs() }
            catch { catalogNotice = "列表缓存读取失败；本地下载不受影响。" }
            videos = catalogs[server] ?? []
            // Restore interrupted transfers before URLSession callbacks. The active
            // scene checks the shared folder asynchronously for changes made in Files.
            reconcileFiles(ids: Set(unfinishedCache.map(\.id)), includeDownloading: !restoreDownloads)
        } catch { errorMessage = "本地存储读取失败：\(error.localizedDescription)" }
        if restoreDownloads { restoreTransfers() } else { restoring = false }
    }

    private func rebuildRecordCache() {
        recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        completedCache = records.filter { $0.state == .complete }
        unfinishedCache = records.filter { $0.state == .downloading || $0.state == .failed }
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

    @discardableResult
    func addServer(_ input: String) -> Bool {
        do {
            let normalized = try ServerAddress.normalize(input).absoluteString
            if !servers.contains(normalized) {
                servers.append(normalized)
                defaults.set(servers, forKey: "servers")
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // Remove only the saved connection. Downloads own their source addresses and
    // remain available (including retries) after a server is removed from this list.
    func removeServer(_ input: String) {
        guard let normalized = try? ServerAddress.normalize(input).absoluteString,
              servers.contains(normalized) else { return }
        servers.removeAll { $0 == normalized }
        defaults.set(servers, forKey: "servers")

        guard server == normalized else { return }
        refreshTask?.cancel()
        refreshTask = nil
        // Invalidate late responses as well as cancelling the request itself.
        refreshID = UUID()
        loading = false
        server = ""
        defaults.removeObject(forKey: "server")
        videos = []
        catalogNotice = nil
    }

    func connectServer(_ input: String) {
        do {
            let normalized = try ServerAddress.normalize(input).absoluteString
            if !servers.contains(normalized) {
                servers.append(normalized)
                defaults.set(servers, forKey: "servers")
            }
            guard server != normalized else {
                refresh()
                return
            }
            refreshTask?.cancel()
            refreshID = UUID()
            server = normalized
            defaults.set(server, forKey: "server")
            videos = catalogs[server] ?? []
            catalogNotice = nil
            refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    // Compatibility for older call sites: save the address and make it active.
    func configureServer(_ input: String) {
        guard addServer(input) else { return }
        connectServer(input)
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
        var retryingMissing = false
        if let existing = existing {
            if existing.state == .downloading { return }
            switch disk.fileStatus(for: existing) {
            case .available:
                if existing.state != .complete { reconcileFiles(ids: [id]) }
                return
            case .unavailable:
                throw ClientError("视频文件暂时无法访问，请解锁设备后重试。")
            case .absent:
                retryingMissing = wasDownloaded(existing)
            case .invalid:
                break
            }
        }
        guard !isPlaybackProtected(id) else {
            throw ClientError("请先关闭正在播放的视频，再重新下载。")
        }
        var request = URLRequest(url: try ServerAddress.endpoint(video.downloadUrl, on: base))
        request.allowsCellularAccess = defaults.bool(forKey: "allowCellular")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        var record = DownloadRecord(video: video, server: base)
        record.publicFileName = existing?.publicFileName
        record.publicFileName = try disk.availableFileName(for: record, among: records)
        if retryingMissing {
            record.retryingMissingDownload = true
            record.downloadedAt = existing?.downloadedAt
        }
        record.favorite = existing?.favorite ?? false
        record.watched = existing?.watched ?? false
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
    }
    func cancel(_ record: DownloadRecord) {
        guard let index = records.firstIndex(where: { $0.taskToken == record.taskToken }),
              records[index].state == .downloading else { return }
        var next = records
        next[index].failTransfer("已取消。重新下载会从头开始。")
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
    func playLocal(_ record: DownloadRecord, playlistIDs: [String]? = nil, startMode: PlaybackStartMode = .standard) {
        guard playbackSession == nil && playback == nil else { return }
        do {
            // Freeze the caller's search/filter order before the player opens.
            // Legacy callers still get the complete local library in list order.
            let ids = playlistIDs ?? LocalLibraryOrder.newestFirst(completedCache,
                completedAt: { $0.downloadedAt }).map(\.id)
            let request = try localPlaybackRequest(for: record.id, playlistIDs: ids, startMode: startMode)
            presentPlayback(request)
        } catch {
            errorMessage = error.localizedDescription
            reconcileFiles(ids: [record.id])
        }
    }
    func playPickedFile(_ file: PickedVideoFile, startMode: PlaybackStartMode = .standard) throws {
        guard playbackSession == nil && playback == nil else {
            throw ClientError("已有视频正在播放，请先关闭播放器。")
        }
        presentPlayback(PlaybackRequest(pickedFile: file, startMode: startMode))
    }

    // The picker holds its security-scoped grant and open descriptor across the
    // animation. Present the validated file only after the old player has closed.
    func queueCompatibleCopy(_ file: PickedVideoFile, replacing request: PlaybackRequest) throws {
        guard playback != nil, playbackSession?.id == request.id else {
            throw ClientError("播放器已切换，请重新选择兼容副本。")
        }
        queuedCompatibleCopy = file
    }

    func openQueuedCompatibleCopy() {
        guard let file = queuedCompatibleCopy else { return }
        queuedCompatibleCopy = nil
        do { try playPickedFile(file, startMode: .afterglow) }
        catch { errorMessage = error.localizedDescription }
    }

    private func presentPlayback(_ request: PlaybackRequest) {
        playbackSession = request
        deletionNotice = nil
        playback = request
    }

    // Compatibility accessor: metadata only; opening a target still validates it.
    var localPlaylistRecords: [DownloadRecord] { completedCache }
    func localPlaybackRequest(for id: String, playlistIDs: [String]? = nil,
                              startMode: PlaybackStartMode = .standard) throws -> PlaybackRequest {
        guard let record = recordsByID[id],
              record.state == .complete, let file = disk?.verifiedFile(for: record) else {
            throw ClientError("本地文件缺失或下载未完成，请重新下载。")
        }
        return try PlaybackRequest(key: record.id, title: record.video.name, url: file, playlistIDs: playlistIDs, startMode: startMode)
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
    // Older builds moved absent and invalid completed downloads into the failed
    // transfer list. Only that specific failure is evidence of a former download.
    private static let legacyMissingMessage = "本地文件缺失或大小异常，请重新下载。"
    private static let invalidFileMessage = "本地文件大小或类型已改变，请放回原文件或重新下载。"
    private func wasDownloaded(_ record: DownloadRecord) -> Bool {
        record.state == .complete || record.state == .missing ||
            (record.state == .failed &&
                (record.message == Self.legacyMissingMessage || record.message == Self.invalidFileMessage))
    }

    // Files can move a multi-GB movie while the app is suspended. Enumerate
    // directory metadata off the main queue; never read movie bytes for the list.
    @MainActor func refreshDownloadedFiles() async {
        let generation = UUID()
        fileRefreshID = generation
        guard let disk else { return }
        let snapshot = records.filter(wasDownloaded)
        guard !snapshot.isEmpty else { return }
        let statuses = await Task.detached(priority: .utility) {
            disk.fileStatuses(for: snapshot)
        }.value
        guard fileRefreshID == generation, !Task.isCancelled else { return }
        applyFileStatuses(statuses, snapshot: snapshot, disk: disk)
    }

    func reconcileFiles(ids: Set<String>? = nil, includeDownloading: Bool = true) {
        guard let disk else { return }
        let snapshot = records.filter { record in
            (ids?.contains(record.id) ?? true) &&
                (record.state != .downloading || (includeDownloading && active[record.id] == nil))
        }
        let statuses = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, disk.fileStatus(for: $0)) })
        applyFileStatuses(statuses, snapshot: snapshot, disk: disk)
    }

    private func applyFileStatuses(_ statuses: [String: LocalDownloadFileStatus],
                                   snapshot: [DownloadRecord], disk: LocalStorage) {
        let inspected = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })
        var next = records
        for index in next.indices {
            let record = next[index]
            // A retry, deletion or fresh download can finish while the folder is
            // being read. Update only the same input and keep newer watch/favorite flags.
            guard let original = inspected[record.id], original.taskToken == record.taskToken,
                  original.state == record.state, original.publicFileName == record.publicFileName,
                  let status = statuses[record.id] else { continue }
            switch status {
            case .available where record.state != .complete:
                next[index].state = .complete
                next[index].message = nil
                next[index].retryingMissingDownload = nil
                if !wasDownloaded(record), record.downloadedAt == nil { next[index].downloadedAt = Date() }
            case .absent where wasDownloaded(record):
                next[index].state = .missing
                if record.state != .missing { next[index].message = nil }
                next[index].pendingDeletionOrder = nil
            case .invalid where wasDownloaded(record):
                next[index].state = .failed
                next[index].message = Self.invalidFileMessage
                next[index].pendingDeletionOrder = nil
            default:
                break
            }
        }
        guard next != records else { return }
        do { try disk.saveRecords(next); records = next }
        catch { errorMessage = "更新本地文件状态失败：\(error.localizedDescription)" }
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
                // A same-name file can be added externally while a background
                // download runs. Only absent tasks can need crash recovery.
                let interrupted = self.records.filter { $0.state == .downloading && !live.contains($0.taskToken) }
                self.reconcileFiles(ids: Set(interrupted.map(\.id)))
                var next = self.records
                for i in next.indices where next[i].state == .downloading {
                    if !live.contains(next[i].taskToken) {
                        next[i].failTransfer("系统中已无此下载任务，可能被强制退出中断，可重新下载。")
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
        var record = records[index]
        var next = records
        do {
            guard let disk = disk else { throw ClientError("本地存储不可用。") }
            // Files may have created a namesake during a long download. Commit
            // the new destination before publishing the completed movie.
            let name = try disk.availableFileName(for: record, among: records)
            if name != record.publicFileName {
                record.publicFileName = name
                next[index] = record
                try disk.saveRecords(next)
            }
            try disk.finish(temp: location, response: downloadTask.response, record: record)
            next[index].state = .complete
            next[index].message = nil
            next[index].retryingMissingDownload = nil
            next[index].downloadedAt = Date()
            progress[record.id] = 1
        } catch {
            next[index].failTransfer(error.localizedDescription)
        }
        records = next
        active.removeValue(forKey: record.id)
        lastProgress.removeValue(forKey: record.id)
        saveRecords()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let index = index(for: task), records[index].state == .downloading, let error = error else { return }
        var next = records
        next[index].failTransfer(error.localizedDescription + "；可重新下载（从头开始）。")
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
    // A confirmed history cleanup may only change the private index. In particular,
    // never invoke a file removal if Files restores or replaces an item mid-action.
    func forgetMissingDownloads(_ request: BatchDeletionRequest) -> BatchDeletionResult {
        var outcome = BatchDeletionResult(recordsOnly: true)
        guard request.scope == .missingHistory, !restoring else { return outcome }
        guard let disk else {
            outcome.failures = request.records.map { "\($0.video.name)：本地存储不可用，原记录已保留。" }
            return outcome
        }
        let current = request.records.compactMap { snapshot -> DownloadRecord? in
            guard let record = recordsByID[snapshot.id], record.taskToken == snapshot.taskToken,
                  record.publicFileName == snapshot.publicFileName, record.state == .missing,
                  !isPlaybackProtected(record.id) else { return nil }
            return record
        }
        // Check only the records confirmed by the user. A single-row removal
        // should cost one lookup even in a large downloads folder.
        var ids = Set<String>()
        var changed = Set<String>()
        outcome.skipped = request.records.count - current.count
        for record in current {
            switch disk.fileStatus(for: record) {
            case .absent:
                ids.insert(record.id)
            case .available, .invalid:
                changed.insert(record.id)
                outcome.skipped += 1
            case .unavailable:
                outcome.failures.append("\(record.video.name)：文件夹暂时无法访问，记录已保留。")
            }
        }
        if !ids.isEmpty {
            let next = records.filter { !ids.contains($0.id) }
            do {
                try disk.saveRecords(next)
                records = next
                for record in current where ids.contains(record.id) {
                    defaults.removeObject(forKey: "position." + record.id)
                    outcome.removedTokens.insert(record.taskToken)
                }
                deletionNotice = nil
            } catch {
                let message = error.localizedDescription
                outcome.failures += current.filter { ids.contains($0.id) }.map { "\($0.video.name)：保存失败，\(message)" }
            }
        }
        if !changed.isEmpty { reconcileFiles(ids: changed) }
        return outcome
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
