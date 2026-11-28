import SwiftUI
import Foundation
import CryptoKit
import AVKit

struct Video: Codable, Identifiable {
    let name: String
    let size: Int64
    let contentType: String
    let downloadUrl: String
    var id: String { name }
    var ext: String { (name as NSString).pathExtension.lowercased() }
    var supported: Bool {
        size > 0 && ["mp4","mov","m4v","mkv","avi","webm","ogg","flv","wmv","ts"].contains(ext)
        && !contentType.lowercased().contains("mpegurl")
    }
}
struct Envelope: Decodable { let videos: [Video] }
struct LocalVideo: Identifiable {
    let url: URL
    let size: Int64
    var id: URL { url }
    var name: String { url.lastPathComponent }
}
struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
@MainActor final class Store: ObservableObject {
    @Published var address = UserDefaults.standard.string(forKey: "server") ?? "http://192.168.168.2:8106"
    @Published var videos: [Video] = []
    @Published var local: [LocalVideo] = []
    @Published var busy = false
    @Published var loading = false
    @Published var message = ""
    @Published var current = ""
    @Published var deletingRemote = false
    @Published var marked = Set(UserDefaults.standard.stringArray(forKey: "pendingDeletion") ?? [])
    var markedItems: [LocalVideo] { local.filter { marked.contains($0.name) } }
    var markedBytes: Int64 { markedItems.reduce(Int64(0)) { $0 + $1.size } }
    var remoteCandidates: [Video] { videos.filter { $0.supported && downloaded($0) } }
    private func saveMarks() { UserDefaults.standard.set(Array(marked), forKey: "pendingDeletion") }
    func toggleMark(_ item: LocalVideo) {
        guard local.contains(where: { $0.id == item.id }) else { return }
        if marked.contains(item.name) { marked.remove(item.name) } else { marked.insert(item.name) }
        saveMarks()
    }
    @Published var batchTotal = 0
    @Published var batchProcessed = 0
    @Published var batchFailed = 0
    @Published var stopRequested = false
    var localBytes: Int64 { local.reduce(Int64(0)) { $0 + $1.size } }
    var storageLabel: String { ByteCountFormatter.string(fromByteCount: localBytes, countStyle: .file) }
    var pending: [Video] { videos.filter { $0.supported && !downloaded($0) } }
    var pendingBytes: Int64 { pending.reduce(Int64(0)) { $0 + $1.size } }
    private let fm = FileManager.default
    private var catalogBase: URL?
    private var folder: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
    }
    init() { scan() }
    private func prepare() throws {
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    func scan() {
        do {
            try prepare()
            local = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey,.fileSizeKey], options: [.skipsHiddenFiles]).compactMap {
                guard let v = try? $0.resourceValues(forKeys: [.isRegularFileKey,.fileSizeKey]), v.isRegularFile == true else { return nil }
                return LocalVideo(url: $0, size: Int64(v.fileSize ?? 0))
            }.sorted { $0.name < $1.name }
            marked.formIntersection(Set(local.map(\.name)))
            saveMarks()
        } catch { message = error.localizedDescription }
    }
    func base() throws -> URL {
        var s = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "http://" + s }
        guard var c = URLComponents(string: s), let scheme = c.scheme?.lowercased(),
              ["http","https"].contains(scheme), let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/" else { throw Failure(message: "请输入服务器根地址") }
        c.scheme = scheme
        c.path = "/"
        guard let u = c.url else { throw Failure(message: "地址无效") }
        return u
    }
    func refresh() async {
        guard !loading, !busy else { return }
        loading = true
        defer { loading = false }
        videos = []; catalogBase = nil
        do {
            let b = try base()
            let (data, response) = try await URLSession.shared.data(from: b.appendingPathComponent("api/videos"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(message: "列表请求失败") }
            videos = try JSONDecoder().decode(Envelope.self, from: data).videos
            catalogBase = b
            UserDefaults.standard.set(b.absoluteString, forKey: "server")
            message = ""
        } catch { message = error.localizedDescription }
    }
    private func destination(_ v: Video, _ b: URL) -> URL {
        let hash = SHA256.hash(data: Data((b.absoluteString + "\n" + v.name + "\n" + String(v.size)).utf8)).map { String(format: "%02x", $0) }.joined()
        let safe = String((v.name as NSString).lastPathComponent.prefix(100)).replacingOccurrences(of: "/", with: "_")
        return folder.appendingPathComponent(String(hash.prefix(16)) + "_" + safe)
    }
    func downloaded(_ v: Video) -> Bool {
        guard let b = catalogBase else { return false }
        return local.contains { $0.url == destination(v,b) && $0.size == v.size }
    }
    func download(_ v: Video) async {
        guard !busy, !loading, let b = catalogBase else { return }
        scan()
        guard v.supported, !downloaded(v) else { return }
        busy = true; current = v.name; message = ""; batchTotal = 0
        defer { busy = false; current = ""; scan() }
        do { try await transfer(v, base: b); message = "下载完成" }
        catch { message = error.localizedDescription }
    }
    func downloadAll() async {
        guard !busy, !loading, let b = catalogBase else { return }
        scan()
        let queue = pending
        guard !queue.isEmpty else { return }
        busy = true; stopRequested = false; batchTotal = queue.count
        batchProcessed = 0; batchFailed = 0; message = ""
        var failures: [String] = []
        defer { busy = false; current = ""; batchTotal = 0; scan() }
        for video in queue {
            if stopRequested { break }
            current = video.name
            if !downloaded(video) {
                do { try await transfer(video, base: b) }
                catch {
                    batchFailed += 1
                    failures.append(video.name + "：" + error.localizedDescription)
                }
            }
            batchProcessed += 1
            scan()
        }
        let status = stopRequested ? "批量下载已停止" : "批量下载结束"
        message = "\(status)：成功或已存在 \(batchProcessed - batchFailed)，失败 \(batchFailed)，未处理 \(batchTotal - batchProcessed)"
        if !failures.isEmpty { message += "\n" + failures.joined(separator: "\n") }
    }
    private func transfer(_ v: Video, base b: URL) async throws {
        guard v.downloadUrl.hasPrefix("/api/"), let u = URL(string: v.downloadUrl, relativeTo: b)?.absoluteURL,
              u.scheme == b.scheme, u.host == b.host, u.port == b.port,
              u.user == nil, u.password == nil, u.fragment == nil else { throw Failure(message: "下载地址无效") }
        try prepare()
        let (tmp, response) = try await URLSession.shared.download(from: u)
        defer { try? fm.removeItem(at: tmp) }
        let mime = response.mimeType?.lowercased() ?? ""
        let size = (try fm.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.int64Value
        guard (response as? HTTPURLResponse)?.statusCode == 200, size == v.size,
              !mime.hasPrefix("text/"), !mime.contains("json"), !mime.contains("mpegurl") else {
            throw Failure(message: "下载失败或文件大小不一致，请刷新列表重试")
        }
        let target = destination(v,b)
        if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: tmp) }
        else { try fm.moveItem(at: tmp, to: target) }
    }
    func deleteDownloadedRemote() async {
        guard !busy, !loading, let b = catalogBase, (try? base()) == b else {
            message = "请先连接当前服务器并刷新列表"; return
        }
        scan()
        let queue = remoteCandidates
        guard !queue.isEmpty else { return }
        busy = true; deletingRemote = true; batchTotal = 0
        defer { busy = false; deletingRemote = false; current = "" }
        var deleted = 0, skipped = 0
        var failures: [String] = []
        for video in queue {
            current = video.name
            let file = destination(video,b)
            do {
                let attrs = try fm.attributesOfItem(atPath: file.path)
                guard attrs[.type] as? FileAttributeType == .typeRegular,
                      (attrs[.size] as? NSNumber)?.int64Value == video.size else { skipped += 1; continue }
                let handle = try FileHandle(forReadingFrom: file)
                let header: Data
                do { header = try handle.read(upToCount: 512) ?? Data() }
                catch { try? handle.close(); throw error }
                try? handle.close()
                let prefix = String(decoding: header, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}"))).lowercased()
                guard !["#extm3u","<html","<!doctype","<?xml","<mpd","{","["].contains(where: { prefix.hasPrefix($0) }) else { skipped += 1; continue }
                let route = "/api/download/"
                guard video.downloadUrl.hasPrefix(route) else { throw Failure(message: "下载路径不符合删除接口") }
                let encoded = String(video.downloadUrl.dropFirst(route.count))
                guard !encoded.isEmpty, !encoded.contains("/"), !encoded.contains("?"), !encoded.contains("#"),
                      encoded.removingPercentEncoding == video.name,
                      video.name != ".", video.name != "..", !video.name.contains("/"),
                      let url = URL(string: "/api/videos/" + encoded, relativeTo: b)?.absoluteURL,
                      url.scheme == b.scheme, url.host == b.host, url.port == b.port else {
                    throw Failure(message: "删除地址无效")
                }
                var request = URLRequest(url: url)
                request.httpMethod = "DELETE"
                request.timeoutInterval = 15
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw Failure(message: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                }
                deleted += 1
                videos.removeAll { $0.name == video.name && $0.size == video.size }
            } catch { failures.append(video.name + "：" + error.localizedDescription) }
        }
        message = "远程删除成功 \(deleted) 个，跳过 \(skipped) 个，失败 \(failures.count) 个。本地副本保留。"
        if !failures.isEmpty { message += "\n" + failures.joined(separator: "\n") }
        scan()
    }
    func deleteMarked() {
        guard !busy else { return }
        scan()
        let items = markedItems
        var failed = 0
        for item in items {
            do { try fm.removeItem(at: item.url); marked.remove(item.name) }
            catch { failed += 1 }
        }
        saveMarks(); scan()
        message = "已删除待删除视频 \(items.count - failed) 个，失败 \(failed) 个"
    }
    func deleteAll() {
        guard !busy else { return }
        scan()
        var failed = 0
        for item in local {
            do { try fm.removeItem(at: item.url) } catch { failed += 1 }
        }
        scan()
        message = failed == 0 ? "已清理本地下载" : "部分文件删除失败：\(failed)"
    }
}
@main struct NiceVideos15App: App {
    @StateObject private var store = Store()
    var body: some Scene { WindowGroup { Home(store: store) } }
}
struct Home: View {
    @ObservedObject var store: Store
    @State private var confirm = false
    @State private var confirmDownloadAll = false
    @State private var confirmRemote = false
    @State private var confirmMarked = false
    @State private var selected: LocalVideo?
    @State private var search = ""
    var body: some View {
        TabView {
            NavigationView {
                List {
                    Section(header: Text("服务器")) {
                        TextField("服务器地址", text: $store.address).autocapitalization(.none).disableAutocorrection(true).keyboardType(.URL).disabled(store.busy || store.loading)
                        Button("连接 / 刷新") { Task { await store.refresh() } }.disabled(store.busy || store.loading)
                        if store.loading { ProgressView() }
                        if store.busy { ProgressView(store.deletingRemote ? "正在删除远程：\(store.current)" : "正在下载：\(store.current)") }
                        if store.busy && store.batchTotal > 0 {
                            ProgressView(value: Double(store.batchProcessed), total: Double(store.batchTotal))
                            Text("已处理 \(store.batchProcessed)/\(store.batchTotal)，失败 \(store.batchFailed)")
                            Button(store.stopRequested ? "等待当前文件完成" : "停止后续下载") { store.stopRequested = true }.disabled(store.stopRequested)
                        }
                        Button("一键下载全部视频") { confirmDownloadAll = true }
                            .disabled(store.busy || store.loading || store.pending.isEmpty)
                        Button(role: .destructive) { confirmRemote = true } label: { Text("删除已经下载的远程视频（\(store.remoteCandidates.count)）") }
                            .disabled(store.busy || store.loading || store.remoteCandidates.isEmpty)
                        Text("待下载：\(store.pending.count) 个 · \(ByteCountFormatter.string(fromByteCount: store.pendingBytes, countStyle: .file))")
                            .font(.footnote)
                        Text("本地已下载：\(store.local.count) 个 · 占用 \(store.storageLabel)")
                            .font(.headline)
                        if !store.message.isEmpty { Text(store.message).font(.footnote) }
                    }
                    Section(header: Text("视频")) {
                        ForEach(store.videos.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { video in
                            VStack(alignment: .leading) {
                                Text(video.name)
                                HStack {
                                    Text(ByteCountFormatter.string(fromByteCount: video.size, countStyle: .file)).font(.caption)
                                    Spacer()
                                    Button(store.downloaded(video) ? "已下载" : video.supported ? "下载" : "不支持") {
                                        Task { await store.download(video) }
                                    }.disabled(store.busy || store.loading || !video.supported || store.downloaded(video))
                                }
                            }
                        }
                    }
                }.searchable(text: $search).navigationTitle("服务器视频")
                    .confirmationDialog("删除服务器源文件？", isPresented: $confirmRemote, titleVisibility: .visible) {
                        Button("删除远程视频", role: .destructive) { Task { await store.deleteDownloadedRemote() } }
                        Button("取消", role: .cancel) {}
                    } message: { Text("仅删除当前服务器上已有完整本地副本的 \(store.remoteCandidates.count) 个视频。服务器文件不可恢复，本地副本保留。") }
                    .alert("下载全部视频？", isPresented: $confirmDownloadAll) {
                        Button("下载") { Task { await store.downloadAll() } }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("下载当前服务器全部支持且尚未下载的视频，不受搜索筛选影响。预计新增 \(ByteCountFormatter.string(fromByteCount: store.pendingBytes, countStyle: .file))。")
                    }
            }.navigationViewStyle(.stack).tabItem { Label("下载", systemImage: "arrow.down.circle") }
            NavigationView {
                List {
                    Section {
                        Text("已下载：\(store.local.count) 个文件")
                        Text("存储占用：\(store.storageLabel)").font(.headline)
                        Text("待删除：\(store.markedItems.count) 个 · \(ByteCountFormatter.string(fromByteCount: store.markedBytes, countStyle: .file))").foregroundColor(.orange)
                        Button(role: .destructive) { confirm = true } label: { Text("一键删除已下载视频") }
                            .disabled(store.busy || store.local.isEmpty)
                        if !store.message.isEmpty { Text(store.message).font(.footnote) }
                    }
                    ForEach(store.local) { item in
                        Button { selected = item } label: {
                            VStack(alignment: .leading) {
                                Text(String(item.name.dropFirst(17))).foregroundColor(.primary)
                                if store.marked.contains(item.name) { Label("待删除", systemImage: "trash").foregroundColor(.orange).font(.caption) }
                                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).font(.caption)
                            }
                        }
                    }
                }.safeAreaInset(edge: .bottom) {
                    HStack {
                        Spacer()
                        Button { confirmMarked = true } label: {
                            Label("一键删除待删除（\(store.markedItems.count)）", systemImage: "trash")
                                .font(.subheadline.bold()).padding(12).foregroundColor(.white)
                                .background(store.markedItems.isEmpty || store.busy ? Color.gray : Color.red).clipShape(Capsule())
                        }.disabled(store.busy || store.markedItems.isEmpty).padding(.trailing, 12)
                    }.padding(.vertical, 6)
                }.navigationTitle("已下载").onAppear { store.scan() }
                    .confirmationDialog("删除已标记的本地视频？", isPresented: $confirmMarked, titleVisibility: .visible) {
                        Button("删除待删除视频", role: .destructive) { store.deleteMarked() }
                        Button("取消", role: .cancel) {}
                    } message: { Text("删除 \(store.markedItems.count) 个已标记视频，其他本地视频不受影响。") }
                    .alert("删除全部本地下载？", isPresented: $confirm) {
                        Button("删除", role: .destructive) { store.deleteAll() }
                        Button("取消", role: .cancel) {}
                    } message: { Text("仅删除本 App 的本地文件，不会删除服务器视频。") }
                    .sheet(item: $selected) { item in LocalPlayer(store: store, item: item) }
            }.navigationViewStyle(.stack).tabItem { Label("已下载", systemImage: "folder") }
        }.task { await store.refresh() }
    }
}
struct LocalPlayer: View {
    @ObservedObject var store: Store
    let item: LocalVideo
    @State private var player: AVPlayer
    @Environment(\.dismiss) private var dismiss
    init(store: Store, item: LocalVideo) {
        self.store = store; self.item = item
        _player = State(initialValue: AVPlayer(url: item.url))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Spacer(); Button("关闭") { dismiss() }.padding() }
            VideoPlayer(player: player)
            HStack {
                Spacer()
                Button {
                    store.toggleMark(item)
                } label: {
                    Label(store.marked.contains(item.name) ? "已标记 · 取消待删除" : "待删除",
                          systemImage: store.marked.contains(item.name) ? "checkmark.circle.fill" : "trash")
                        .padding(12).foregroundColor(.white)
                        .background(store.marked.contains(item.name) ? Color.orange : Color.gray)
                        .clipShape(Capsule())
                }.padding()
            }
        }.background(Color.black).foregroundColor(.white)
        .onAppear { player.play() }.onDisappear { player.pause() }
    }
}
