import Combine
import Foundation

@MainActor final class CatalogState: ObservableObject {
    @Published private(set) var entries: [CatalogEntry] = []
    @Published private(set) var downloadedNames = Set<String>()
    private var byFilename: [String: CatalogEntry] = [:]
    private var supportedCount = 0
    private var supportedBytes: Int64 = 0
    private(set) var pendingBytes: Int64 = 0
    var downloadedCount: Int { downloadedNames.count }
    var pendingCount: Int { supportedCount - downloadedCount }

    func replace(_ list: [CatalogEntry], local: [String: LocalVideo]) {
        byFilename.removeAll(keepingCapacity: true)
        supportedCount = 0
        supportedBytes = 0
        for entry in list where entry.supported {
            byFilename[entry.filename] = entry
            supportedCount += 1
            supportedBytes += entry.video.size
        }
        match(local)
        entries = list
    }

    func match(_ local: [String: LocalVideo]) {
        var complete = Set<String>()
        var bytes = supportedBytes
        for (name, item) in local {
            if let entry = byFilename[name], entry.video.size == item.size {
                complete.insert(name)
                bytes -= item.size
            }
        }
        pendingBytes = bytes
        if complete != downloadedNames { downloadedNames = complete }
    }

    func contains(_ entry: CatalogEntry) -> Bool { byFilename[entry.filename] == entry }

    func record(_ item: LocalVideo) {
        guard let entry = byFilename[item.name] else { return }
        if item.size == entry.video.size {
            guard !downloadedNames.contains(item.name) else { return }
            pendingBytes -= item.size
            downloadedNames.insert(item.name)
        } else if downloadedNames.contains(item.name) {
            pendingBytes += entry.video.size
            downloadedNames.remove(item.name)
        }
    }
}

@MainActor final class LibraryState: ObservableObject {
    @Published private(set) var items: [LocalVideo] = []
    private(set) var byName: [String: LocalVideo] = [:]
    private(set) var bytes: Int64 = 0

    func replace(_ sortedItems: [LocalVideo]) {
        byName = Dictionary(sortedItems.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        bytes = sortedItems.reduce(0) { $0 + $1.size }
        items = sortedItems
    }

    func record(_ item: LocalVideo) {
        let previous = byName.updateValue(item, forKey: item.name)
        guard previous != item else { return }
        bytes += item.size - (previous?.size ?? 0)
        var low = 0
        var high = items.count
        while low < high {
            let middle = low + (high - low) / 2
            if items[middle].name < item.name { low = middle + 1 } else { high = middle }
        }
        if previous != nil { items[low] = item } else { items.insert(item, at: low) }
    }
}

// Preserve write order even when successive toggles enqueue tasks in a different order.
private actor MarkPreferences {
    private var lastRevision = 0
    private let defaults: UserDefaults

    init(suiteName: String?) {
        defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    func read() -> Set<String> {
        Set(defaults.stringArray(forKey: "pendingDeletion") ?? [])
    }
    func save(_ names: Set<String>, revision: Int) {
        guard revision > lastRevision else { return }
        lastRevision = revision
        defaults.set(Array(names), forKey: "pendingDeletion")
    }
}

@MainActor final class MarkState: ObservableObject {
    @Published private(set) var names = Set<String>()
    private(set) var bytes: Int64 = 0
    private var revision = 0
    private let preferences: MarkPreferences
    private(set) var restored = false

    init(suiteName: String? = nil) {
        preferences = MarkPreferences(suiteName: suiteName)
    }

    func savedNames() async -> Set<String> { await preferences.read() }

    func reconcile(local: [String: LocalVideo], saved: Set<String>? = nil) {
        let source = saved ?? names
        let valid = source.filter { local[$0] != nil }
        let newBytes = valid.reduce(Int64(0)) { $0 + (local[$1]?.size ?? 0) }
        if newBytes != bytes || valid != names {
            bytes = newBytes
            names = valid
        }
        restored = true
        if source != valid { persist() }
    }

    func toggle(_ item: LocalVideo) {
        if names.contains(item.name) {
            bytes -= item.size
            names.remove(item.name)
        } else {
            bytes += item.size
            names.insert(item.name)
        }
        persist()
    }

    func updateSize(of name: String, delta: Int64) {
        if delta != 0 && names.contains(name) {
            objectWillChange.send()
            bytes += delta
        }
    }

    private func persist() {
        revision += 1
        let snapshot = names
        let version = revision
        Task { await preferences.save(snapshot, revision: version) }
    }
}

@MainActor final class ServerState: ObservableObject {
    @Published var address = UserDefaults.standard.string(forKey: "server") ?? "http://192.168.168.2:8106"

    func base() throws -> URL {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "http://" + text }
        guard var parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { throw Failure(message: "请输入服务器根地址") }
        parts.scheme = scheme
        parts.path = "/"
        guard let url = parts.url else { throw Failure(message: "地址无效") }
        return url
    }
}

enum OperationKind {
    case idle, download, deleteLocal, deleteRemote
}

@MainActor final class GateState: ObservableObject {
    @Published fileprivate(set) var mode = OperationKind.idle
    var busy: Bool { mode != .idle }
    @Published fileprivate(set) var loading = false
}

@MainActor final class ActivityState: ObservableObject {
    @Published fileprivate(set) var mode = OperationKind.idle
    @Published fileprivate(set) var current = ""
    @Published fileprivate(set) var message = ""
    @Published fileprivate(set) var batchTotal = 0
    @Published fileprivate(set) var batchProcessed = 0
    @Published fileprivate(set) var batchFailed = 0
    @Published fileprivate(set) var stopRequested = false
    var busy: Bool { mode != .idle }
    @Published fileprivate(set) var loading = false
    var deletingRemote: Bool { mode == .deleteRemote }
    var deletingLocal: Bool { mode == .deleteLocal }
}

@MainActor final class Store: ObservableObject {
    let catalog = CatalogState()
    let library = LibraryState()
    let marks = MarkState()
    let activity = ActivityState()
    let gate = GateState()
    let server = ServerState()
    private let files = VideoFiles()
    private var catalogBase: URL?
    private var libraryRevision = 0
    private var scanTask: Task<Bool, Never>?

    private func begin(_ mode: OperationKind) -> Bool {
        guard gate.mode == .idle, !gate.loading || mode == .deleteLocal else { return false }
        gate.mode = mode
        activity.mode = mode
        activity.message = ""
        return true
    }

    private func finish() {
        activity.current = ""
        activity.batchTotal = 0
        activity.stopRequested = false
        activity.mode = .idle
        gate.mode = .idle
    }

    func scan() async { _ = await reconcileFiles() }

    private func reconcileFiles() async -> Bool {
        if let scanTask = scanTask { return await scanTask.value }
        let work = Task { @MainActor in
            defer { scanTask = nil }
            do {
                let saved = marks.restored ? nil : await marks.savedNames()
                // A scan can finish just before a download or deletion is committed.
                // Discard that snapshot if the main actor has already published a newer change.
                while true {
                    let revision = libraryRevision
                    let items = try await files.scan()
                    guard revision == libraryRevision else { continue }
                    if items != library.items {
                        library.replace(items)
                        catalog.match(library.byName)
                        marks.reconcile(local: library.byName, saved: saved)
                    } else if !marks.restored {
                        marks.reconcile(local: library.byName, saved: saved)
                    }
                    return true
                }
            } catch {
                activity.message = error.localizedDescription
                return false
            }
        }
        scanTask = work
        return await work.value
    }

    func refresh() async {
        guard !gate.busy, !gate.loading else { return }
        gate.loading = true
        activity.loading = true
        activity.message = ""
        defer {
            activity.loading = false
            gate.loading = false
        }
        async let localReady = reconcileFiles()
        do {
            let base = try server.base()
            if base != catalogBase {
                catalogBase = nil
                catalog.replace([], local: library.byName)
            }
            let (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent("api/videos"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(message: "列表请求失败") }
            let entries = try await files.catalog(data: data, base: base)
            _ = await localReady
            catalogBase = base
            catalog.replace(entries, local: library.byName)
            UserDefaults.standard.set(base.absoluteString, forKey: "server")
        } catch { activity.message = error.localizedDescription }
    }

    private func connectedBase() throws -> URL {
        guard let base = catalogBase, (try? server.base()) == base else {
            throw Failure(message: "请先连接当前服务器并刷新列表")
        }
        return base
    }

    private func record(_ item: LocalVideo) {
        libraryRevision += 1
        let oldSize = library.byName[item.name]?.size ?? 0
        library.record(item)
        marks.updateSize(of: item.name, delta: item.size - oldSize)
        catalog.record(item)
    }

    private func transfer(_ entry: CatalogEntry, base: URL) async throws {
        if let existing = try await files.existing(entry) {
            record(existing)
            return
        }
        let route = entry.video.downloadUrl
        guard route.hasPrefix("/api/"), let url = URL(string: route, relativeTo: base)?.absoluteURL,
              url.scheme == base.scheme, url.host == base.host, url.port == base.port,
              url.user == nil, url.password == nil, url.fragment == nil else { throw Failure(message: "下载地址无效") }
        let (temp, response) = try await URLSession.shared.download(from: url)
        let item = try await files.install(temp, response: response, entry: entry)
        record(item)
    }

    func download(_ entry: CatalogEntry) async {
        guard catalog.contains(entry), begin(.download) else { return }
        defer { finish() }
        activity.current = entry.video.name
        do {
            try await transfer(entry, base: connectedBase())
            activity.message = "下载完成"
        } catch { activity.message = error.localizedDescription }
    }

    func downloadAll() async {
        guard begin(.download) else { return }
        defer { finish() }
        do {
            let base = try connectedBase()
            guard await reconcileFiles() else { return }
            let queue = catalog.entries.filter { $0.supported && !catalog.downloadedNames.contains($0.filename) }
            guard !queue.isEmpty else { activity.message = "所有支持的视频均已下载"; return }
            activity.batchTotal = queue.count
            activity.batchProcessed = 0
            activity.batchFailed = 0
            var failures: [String] = []
            for entry in queue {
                if activity.stopRequested { break }
                activity.current = entry.video.name
                do { try await transfer(entry, base: base) }
                catch {
                    activity.batchFailed += 1
                    failures.append(entry.video.name + "：" + error.localizedDescription)
                }
                activity.batchProcessed += 1
            }
            let processed = activity.batchProcessed
            let failed = activity.batchFailed
            let status = activity.stopRequested ? "批量下载已停止" : "批量下载结束"
            activity.message = (["\(status)：成功或已存在 \(processed - failed)，失败 \(failed)，未处理 \(queue.count - processed)"] + failures).joined(separator: "\n")
        } catch { activity.message = error.localizedDescription }
    }

    func requestStop() {
        if gate.mode == .download && activity.batchTotal > 0 { activity.stopRequested = true }
    }

    func toggleMark(_ item: LocalVideo) {
        guard gate.mode != .deleteLocal, let current = library.byName[item.name] else { return }
        marks.toggle(current)
    }

    private func remoteDeleteRequest(_ video: Video, base: URL) throws -> URLRequest {
        let route = "/api/download/"
        guard video.downloadUrl.hasPrefix(route) else { throw Failure(message: "下载路径不符合删除接口") }
        let encoded = String(video.downloadUrl.dropFirst(route.count))
        guard !encoded.isEmpty, !encoded.contains("/"), !encoded.contains("?"), !encoded.contains("#"),
              encoded.removingPercentEncoding == video.name, video.name != ".", video.name != "..",
              !video.name.contains("/"), let url = URL(string: "/api/videos/" + encoded, relativeTo: base)?.absoluteURL,
              url.scheme == base.scheme, url.host == base.host, url.port == base.port else {
            throw Failure(message: "删除地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 15
        return request
    }

    func deleteDownloadedRemote(confirmedNames: Set<String>) async {
        guard begin(.deleteRemote) else { return }
        defer { finish() }
        do {
            let base = try connectedBase()
            let queue = catalog.entries.filter {
                confirmedNames.contains($0.filename) && catalog.downloadedNames.contains($0.filename)
            }
            var deleted = Set<String>()
            var skipped = 0
            var failures: [String] = []
            for entry in queue {
                activity.current = entry.video.name
                do {
                    let request = try remoteDeleteRequest(entry.video, base: base)
                    guard try await files.verified(entry) else { skipped += 1; continue }
                    let (_, response) = try await URLSession.shared.data(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else { throw Failure(message: "HTTP \(status)") }
                    deleted.insert(entry.filename)
                } catch { failures.append(entry.video.name + "：" + error.localizedDescription) }
            }
            if !deleted.isEmpty {
                catalog.replace(catalog.entries.filter { !deleted.contains($0.filename) }, local: library.byName)
            }
            if skipped > 0 || !failures.isEmpty { _ = await reconcileFiles() }
            activity.message = (["远程删除成功 \(deleted.count) 个，跳过 \(skipped) 个，失败 \(failures.count) 个。本地副本保留。"] + failures).joined(separator: "\n")
        } catch { activity.message = error.localizedDescription }
    }

    func deleteMarked() async { await deleteLocal(onlyMarked: true) }
    func deleteAll() async { await deleteLocal(onlyMarked: false) }

    private func deleteLocal(onlyMarked: Bool) async {
        guard begin(.deleteLocal) else { return }
        defer { finish() }
        let items = onlyMarked ? marks.names.compactMap { library.byName[$0] } : library.items
        let removed = await files.remove(items)
        libraryRevision += 1
        let names = Set(removed.map(\.name))
        if !names.isEmpty {
            library.replace(library.items.filter { !names.contains($0.name) })
            catalog.match(library.byName)
            marks.reconcile(local: library.byName)
        }
        let failed = items.count - removed.count
        if failed > 0 { _ = await reconcileFiles() }
        if onlyMarked {
            activity.message = "已删除待删除视频 \(removed.count) 个，失败 \(failed) 个"
        } else {
            activity.message = failed == 0 ? "已清理本地下载" : "部分文件删除失败：\(failed)"
        }
    }
}
