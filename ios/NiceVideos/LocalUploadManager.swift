import Foundation
import Combine

// Separate object: upload byte ticks never publish VideoStore/library changes.
final class LocalUploadProgress: ObservableObject {
    @Published private(set) var fractions: [UUID: Double] = [:]
    func set(_ value: Double, for id: UUID) { fractions[id] = value }
    func remove(_ id: UUID) { fractions.removeValue(forKey: id) }
}

// Foreground, serial file uploads. No background-transfer promise: a process
// restart marks unconfirmed work failed and requires explicit user retry.
// All state and URLSession delegate callbacks are main-queue confined.
final class LocalUploadManager: NSObject, ObservableObject, URLSessionDataDelegate {
    static let shared = LocalUploadManager(store: .shared)
    @Published private(set) var jobs: [LocalUploadJob] = []
    @Published var errorMessage: String?
    let progress = LocalUploadProgress()
    private let resolveSource: (LocalUploadJob) throws -> URL
    private let queueFinished: (Set<URL>) -> Void
    private let configuration: URLSessionConfiguration
    private var disk: LocalUploadDisk?
    private var activeTask: URLSessionUploadTask?
    private var activeID: UUID?
    private var responseData = Data()
    private var responseOverflow = false
    private var lastProgress = Date.distantPast
    private var completedServers = Set<URL>()
    private lazy var session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)

    convenience init(store: VideoStore) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NiceVideoUploads", isDirectory: true)
        self.init(root: root, resolveSource: { job in
            guard let record = store.records.first(where: { $0.id == job.source.id }),
                  record.taskToken == job.source.taskToken, record.state == .complete else {
                throw LocalUploadError("原本地下载已删除或已变成新的下载批次，未上传替换后的文件。")
            }
            return try store.localPlaybackRequest(for: job.source.id).url
        }, queueFinished: { servers in
            // Refresh only after the batch drains, and only the currently selected server.
            if let current = try? ServerAddress.normalize(store.server), servers.contains(current) { store.refresh() }
        })
    }

    init(root: URL, configuration: URLSessionConfiguration = .ephemeral,
         resolveSource: @escaping (LocalUploadJob) throws -> URL,
         queueFinished: @escaping (Set<URL>) -> Void = { _ in }) {
        self.resolveSource = resolveSource
        self.queueFinished = queueFinished
        self.configuration = configuration
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        super.init()
        do {
            let disk = try LocalUploadDisk(root: root)
            var restored = try disk.load()
            for i in restored.indices where restored[i].state.isPending {
                restored[i].state = .failed
                restored[i].message = "上次上传没有完成确认。可能已保存到服务器，请核对后重新上传。"
            }
            try disk.save(restored)
            try disk.recoverAfterRelaunch()
            self.disk = disk
            jobs = restored
        } catch { errorMessage = "上传记录恢复失败：\(error.localizedDescription)" }
    }

    @discardableResult func enqueue(_ sources: [LocalUploadSource], server: URL, allowsCellular: Bool) -> Bool {
        do {
            var next = jobs
            for source in sources {
                guard !next.contains(where: { $0.state.isPending && $0.matches(source, server: server) }) else { continue }
                let job = LocalUploadJob(source: source, server: server, allowsCellular: allowsCellular)
                _ = try LocalUploadWire.request(for: job) // Metadata only; do not touch all video files.
                next.append(job)
            }
            try replace(next)
            pump()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].state.isPending, activeID != id else { return }
        let old = jobs[index]
        guard !jobs.contains(where: { $0.state.isPending && $0.matches(old.source, server: old.server) }) else { return }
        var next = jobs
        next[index] = LocalUploadJob(source: old.source, server: old.server, allowsCellular: old.allowsCellular)
        do { try replace(next); pump() }
        catch { errorMessage = error.localizedDescription }
    }
    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state.isPending else { return }
        var next = jobs
        next[index].state = .cancelled
        next[index].message = activeID == id ? "已请求取消。取消不会撤销已经在服务器保存的文件，请核对服务器列表。" : "已取消等待上传。"
        do {
            try replace(next)
        } catch { errorMessage = error.localizedDescription }
        // User cancellation must reach the task even when saving metadata fails.
        if activeID == id { activeTask?.cancel() } else { pump() }
    }
    func clearFinished() {
        let removed = jobs.filter { !$0.state.isPending && $0.id != activeID }.map(\.id)
        do {
            try replace(jobs.filter { $0.state.isPending || $0.id == activeID })
            removed.forEach { progress.remove($0) }
        } catch { errorMessage = error.localizedDescription }
    }
    private func replace(_ next: [LocalUploadJob]) throws {
        guard let disk else { throw LocalUploadError("上传存储不可用，已停止上传。") }
        try disk.save(next)
        jobs = next
    }
    private func pump() {
        guard activeTask == nil, let disk else { return }
        while let index = jobs.firstIndex(where: { $0.state == .queued }) {
            let job = jobs[index]
            do {
                let request = try LocalUploadWire.request(for: job)
                // Only the next item is validated/snapshotted, never the entire queue.
                let file = try disk.prepare(source: resolveSource(job), id: job.id, expectedBytes: job.source.size)
                var next = jobs
                next[index].state = .uploading
                next[index].message = nil
                try replace(next)
                let task = session.uploadTask(with: request, fromFile: file)
                task.taskDescription = job.id.uuidString
                task.countOfBytesClientExpectsToSend = job.source.size
                activeID = job.id
                activeTask = task
                responseData.removeAll(keepingCapacity: true)
                responseOverflow = false
                lastProgress = .distantPast
                progress.set(0, for: job.id)
                task.resume()
                return
            } catch {
                var next = jobs
                next[index].state = .failed
                next[index].message = error.localizedDescription
                do { try replace(next); try disk.removeSnapshot(job.id) }
                catch { errorMessage = error.localizedDescription; return }
            }
        }
        if !completedServers.isEmpty {
            let servers = completedServers
            completedServers.removeAll()
            queueFinished(servers)
        }
    }
    private func currentJob(for task: URLSessionTask) -> LocalUploadJob? {
        guard let id = activeID, task.taskIdentifier == activeTask?.taskIdentifier,
              task.taskDescription == id.uuidString else { return nil }
        return jobs.first { $0.id == id }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let job = currentJob(for: task), job.state == .uploading else { return }
        let now = Date()
        guard now.timeIntervalSince(lastProgress) >= 0.25 || totalBytesSent >= job.source.size else { return }
        lastProgress = now
        // 100% bytes sent is NOT success. A matching receipt is still required.
        progress.set(min(1, max(0, Double(totalBytesSent) / Double(job.source.size))), for: job.id)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard currentJob(for: dataTask) != nil, !responseOverflow else { return }
        guard responseData.count + data.count <= LocalUploadWire.responseLimit else {
            responseOverflow = true
            dataTask.cancel()
            return
        }
        responseData.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never send the user's movie to a redirected origin or downgrade HTTPS.
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let job = currentJob(for: task), let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        var next = jobs
        do {
            if responseOverflow { throw LocalUploadError("服务器返回内容异常大，已停止上传确认。") }
            // Prefer actionable HTTP errors over a secondary connection-close error.
            if let http = task.response as? HTTPURLResponse, http.statusCode != 201 {
                try LocalUploadWire.validateReceipt(responseData, response: http, job: job)
            }
            if let error { throw error }
            try LocalUploadWire.validateReceipt(responseData, response: task.response, job: job)
            next[index].state = .completed
            next[index].message = "服务器已确认保存；手机视频、收藏和观看记录均保留。"
            completedServers.insert(job.server)
            progress.set(1, for: job.id)
        } catch {
            if job.state != .cancelled {
                next[index].state = (task.response as? HTTPURLResponse)?.statusCode == 409 ? .conflict : .failed
                next[index].message = error.localizedDescription
            }
        }
        activeID = nil
        activeTask = nil
        responseData.removeAll(keepingCapacity: true)
        do {
            try replace(next)
            try disk?.removeSnapshot(job.id)
        } catch {
            errorMessage = "上传结果或暂存清理失败：\(error.localizedDescription)。原视频未删除。"
            return // Do not continue a queue whose result could not be persisted.
        }
        pump()
    }
    // Tests can explicitly release the delegate-owned session after completion.
    func invalidate() { session.invalidateAndCancel() }
}
