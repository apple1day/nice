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
        return folder.appendingPathComponent(hash.prefix(16) + "_" + safe)
    }
    func downloaded(_ v: Video) -> Bool {
        guard let b = catalogBase else { return false }
        return local.contains { $0.url == destination(v,b) && $0.size == v.size }
    }
    func download(_ v: Video) async {
        guard !busy, !loading, v.supported, !downloaded(v), let b = catalogBase else { return }
        busy = true; current = v.name; message = ""
        defer { busy = false; current = ""; scan() }
        do {
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
            message = "下载完成"
        } catch { message = error.localizedDescription }
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
                        if store.busy { ProgressView("正在下载：\(store.current)") }
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
            }.navigationViewStyle(.stack).tabItem { Label("下载", systemImage: "arrow.down.circle") }
            NavigationView {
                List {
                    Section {
                        Text("已下载：\(store.local.count) 个文件")
                        Text(ByteCountFormatter.string(fromByteCount: store.local.reduce(Int64(0)) { $0 + $1.size }, countStyle: .file))
                        Button(role: .destructive) { confirm = true } label: { Text("一键删除已下载视频") }
                            .disabled(store.busy || store.local.isEmpty)
                        if !store.message.isEmpty { Text(store.message).font(.footnote) }
                    }
                    ForEach(store.local) { item in
                        Button { selected = item } label: {
                            VStack(alignment: .leading) {
                                Text(String(item.name.dropFirst(17))).foregroundColor(.primary)
                                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).font(.caption)
                            }
                        }
                    }
                }.navigationTitle("已下载").onAppear { store.scan() }
                    .alert("删除全部本地下载？", isPresented: $confirm) {
                        Button("删除", role: .destructive) { store.deleteAll() }
                        Button("取消", role: .cancel) {}
                    } message: { Text("仅删除本 App 的本地文件，不会删除服务器视频。") }
                    .sheet(item: $selected) { item in LocalPlayer(url: item.url) }
            }.navigationViewStyle(.stack).tabItem { Label("已下载", systemImage: "folder") }
        }.task { await store.refresh() }
    }
}
struct LocalPlayer: View {
    @State private var player: AVPlayer
    init(url: URL) { _player = State(initialValue: AVPlayer(url: url)) }
    var body: some View {
        VideoPlayer(player: player).onAppear { player.play() }.onDisappear { player.pause() }
    }
}
