import Foundation
import Combine

// All mutable state is main-queue confined. URLSession uses OperationQueue.main;
// Swift 5 mode is explicit in project.yml. Revisit isolation when adopting Swift 6 mode.
final class VideoStore: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = VideoStore()
    static let sessionID = (Bundle.main.bundleIdentifier ?? "com.anxiong.nicevideos") + ".downloads.v1"

    @Published private(set) var server = UserDefaults.standard.string(forKey: "server") ?? ""
    @Published private(set) var videos: [Video] = []
    @Published private(set) var records: [DownloadRecord] = []
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var loading = false
    @Published private(set) var restoring = true
    @Published private(set) var catalogNotice: String?
    @Published var errorMessage: String?
    @Published var playback: PlaybackRequest?

    var backgroundCompletion: (() -> Void)?
    private var disk: LocalStorage?
    private var catalogs: [String: [Video]] = [:]
    private var active: [String: URLSessionDownloadTask] = [:]
    private var lastProgress: [String: Date] = [:]
    private var refreshTask: Task<Void, Never>?
    private var refreshID = UUID()

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true // Each request captures the user's preference.
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    private override init() {
        super.init()
        do {
            let storage = try LocalStorage()
            records = try storage.loadRecords()
            disk = storage
            do { catalogs = try storage.loadCatalogs() }
            catch { catalogNotice = "列表缓存读取失败；本地下载不受影响。" }
            videos = catalogs[server] ?? []
            reconcileFiles()
        } catch {
            // Do not overwrite an unreadable manifest or delete orphaned media.
            errorMessage = "本地存储读取失败：\(error.localizedDescription)"
        }
        restoreTransfers()
    }

    var completed: [DownloadRecord] { records.filter { $0.state == .complete } }
    var unfinished: [DownloadRecord] { records.filter { $0.state != .complete } }
    var usedBytes: Int64 { completed.reduce(0) { $0 + $1.video.size } }

    func configureServer(_ input: String) {
        do {
            let base = try ServerAddress.normalize(input)
            server = base.absoluteString
            UserDefaults.standard.set(server, forKey: "server")
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
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
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
                // A server switch or a newer refresh superseded this request.
            } catch {
                guard self.refreshID == generation else { return }
                self.catalogNotice = "无法连接服务器，保留上次列表。已下载视频仍可播放。\n\(error.localizedDescription)"
            }
        }
    }

    func record(for video: Video) -> DownloadRecord? {
        guard let base = try? ServerAddress.normalize(server) else { return nil }
        let id = video.storageID(server: base)
        return records.first { $0.id == id }
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
        guard !restoring else { throw ClientError("正在恢复下载任务，请稍后再试；本地播放不受影响。") }
        guard let disk = disk else { throw ClientError("本地存储不可用，无法开始下载。") }
        guard video.supportsOffline else {
            throw ClientError("当前版本仅下载 MP4、M4V、MOV 完整文件；HLS、MKV 等需要另一套下载或解码实现。")
        }
        let id = video.storageID(server: base)
        if let existing = records.first(where: { $0.id == id }) {
            if existing.state == .downloading { return }
            if existing.state == .complete, disk.verifiedFile(for: existing) != nil { return }
        }
        var request = URLRequest(url: try ServerAddress.endpoint(video.downloadUrl, on: base))
        request.allowsCellularAccess = UserDefaults.standard.bool(forKey: "allowCellular")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let record = DownloadRecord(video: video, server: base)
        let previous = records
        records.removeAll { $0.id == id }
        records.append(record)
        do { try disk.saveRecords(records) }
        catch { records = previous; throw error }
        // Persist the identity/attempt BEFORE starting the system-owned task.
        let task = session.downloadTask(with: request)
        task.taskDescription = record.taskToken
        task.countOfBytesClientExpectsToReceive = video.size
        active[id] = task
        progress[id] = 0
        task.resume()
    }

    func cancel(_ record: DownloadRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index].state = .failed
        records[index].message = "已取消。重新下载会从头开始。"
        active.removeValue(forKey: record.id)?.cancel()
        progress.removeValue(forKey: record.id)
        saveRecords()
    }

    func removeFromDevice(_ record: DownloadRecord) {
        do {
            guard let disk = disk else { throw ClientError("本地存储不可用。") }
            try disk.remove(record)
            active.removeValue(forKey: record.id)?.cancel()
            records.removeAll { $0.id == record.id }
            progress.removeValue(forKey: record.id)
            UserDefaults.standard.removeObject(forKey: "position." + record.id)
            saveRecords()
        } catch { errorMessage = "删除本地文件失败：\(error.localizedDescription)" }
    }

    func play(_ video: Video) {
        if let record = record(for: video), record.state == .complete,
           disk?.verifiedFile(for: record) != nil {
            playLocal(record)
            return
        }
        do {
            guard video.supportsStreaming else { throw ClientError("当前原生播放器不支持此容器，请先转为 MP4 或后续接入 VLCKit。") }
            let base = try ServerAddress.normalize(server)
            playback = PlaybackRequest(key: video.storageID(server: base), title: video.name,
                                       url: try ServerAddress.endpoint(video.url, on: base))
        } catch { errorMessage = error.localizedDescription }
    }

    func playLocal(_ record: DownloadRecord) {
        // Never silently fall back to a network URL from the offline library.
        guard let file = disk?.verifiedFile(for: record) else {
            errorMessage = "本地文件缺失或不完整，请重新下载。"
            reconcileFiles()
            return
        }
        playback = PlaybackRequest(key: record.id, title: record.video.name, url: file)
    }

    func reconcileFiles() {
        guard let disk = disk else { return }
        var changed = false
        for i in records.indices {
            if disk.verifiedFile(for: records[i]) != nil {
                // Recover a crash after moving a file but before persisting completion.
                if records[i].state != .complete {
                    records[i].state = .complete
                    records[i].message = nil
                    changed = true
                }
            } else if records[i].state == .complete {
                records[i].state = .failed
                records[i].message = "本地文件缺失或大小异常，请重新下载。"
                changed = true
            }
        }
        if changed { saveRecords() }
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
                          let index = self.index(for: task),
                          self.records[index].state == .downloading else { task.cancel(); continue }
                    let record = self.records[index]
                    live.insert(record.taskToken)
                    self.active[record.id] = download
                    if download.state == .suspended { download.resume() }
                }
                for i in self.records.indices where self.records[i].state == .downloading {
                    if !live.contains(self.records[i].taskToken) {
                        self.records[i].state = .failed
                        self.records[i].message = "系统中已无此下载任务。可能被强制退出中断，可重新下载。"
                    }
                }
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
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let index = index(for: downloadTask), records[index].state == .downloading else { return }
        let id = records[index].id
        let now = Date()
        guard now.timeIntervalSince(lastProgress[id] ?? .distantPast) > 0.25 else { return }
        lastProgress[id] = now
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : records[index].video.size
        progress[id] = min(1, max(0, Double(totalBytesWritten) / Double(max(1, expected))))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let index = index(for: downloadTask), records[index].state == .downloading else { return }
        let record = records[index]
        do {
            guard let disk = disk else { throw ClientError("本地存储不可用。") }
            try disk.finish(temp: location, response: downloadTask.response, record: record)
            records[index].state = .complete
            records[index].message = nil
            progress[record.id] = 1
        } catch {
            records[index].state = .failed
            records[index].message = error.localizedDescription
        }
        active.removeValue(forKey: record.id)
        saveRecords()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let index = index(for: task), records[index].state == .downloading,
              let error = error else { return }
        records[index].state = .failed
        records[index].message = error.localizedDescription + "；可重新下载（从头开始）。"
        active.removeValue(forKey: records[index].id)
        saveRecords()
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // Delegate queue is .main; finish only after all file moves and manifest writes.
        let completion = backgroundCompletion
        backgroundCompletion = nil
        completion?()
    }
}
