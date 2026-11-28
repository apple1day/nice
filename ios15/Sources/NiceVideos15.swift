import SwiftUI
import Combine
import AVKit

private func byteLabel(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

@main @MainActor struct NiceVideos15App: App {
    @StateObject private var store = Store()
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasInBackground = false

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationView {
                    RemotePage(store: store)
                }
                .navigationViewStyle(.stack)
                .tabItem { Label("下载", systemImage: "arrow.down.circle") }

                NavigationView {
                    LocalPage(store: store, library: store.library)
                }
                .navigationViewStyle(.stack)
                .tabItem { Label("已下载", systemImage: "folder") }
            }
            .task { await store.refresh() }
            .onChange(of: scenePhase) { phase in
                if phase == .background {
                    wasInBackground = true
                } else if phase == .active && wasInBackground {
                    wasInBackground = false
                    Task { await store.scan() }
                }
            }
        }
    }
}

@MainActor private final class CatalogSearch: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { filter() } }
    }
    @Published private(set) var rows: [CatalogEntry] = []

    private var entries: [CatalogEntry] = []
    private var subscription: AnyCancellable?
    private var searchTask: Task<Void, Never>?

    init(catalog: CatalogState) {
        subscription = catalog.$entries.sink { [weak self] entries in
            self?.entries = entries
            self?.filter()
        }
    }

    deinit { searchTask?.cancel() }

    private func filter() {
        searchTask?.cancel()
        guard !query.isEmpty, !entries.isEmpty else {
            rows = entries
            return
        }
        searchTask = Task { [weak self, entries, query] in
            let matches = await Self.matching(entries, query: query)
            guard !Task.isCancelled else { return }
            self?.rows = matches
        }
    }

    private nonisolated static func matching(_ entries: [CatalogEntry], query: String) async -> [CatalogEntry] {
        var matches: [CatalogEntry] = []
        for entry in entries {
            if Task.isCancelled { break }
            if entry.video.name.localizedCaseInsensitiveContains(query) {
                matches.append(entry)
            }
        }
        return matches
    }
}

@MainActor private struct RemotePage: View {
    let store: Store
    @StateObject private var search: CatalogSearch

    init(store: Store) {
        self.store = store
        _search = StateObject(wrappedValue: CatalogSearch(catalog: store.catalog))
    }

    var body: some View {
        List {
            Section(header: Text("服务器")) {
                ConnectionControls(store: store, server: store.server, gate: store.gate)
                ActivityPanel(store: store, activity: store.activity)
                CatalogActions(store: store, catalog: store.catalog, gate: store.gate)
                LocalUsage(library: store.library)
                OperationMessage(activity: store.activity)
            }
            Section(header: Text("视频")) {
                ForEach(search.rows) { entry in
                    RemoteRow(store: store, catalog: store.catalog, gate: store.gate, entry: entry)
                }
            }
        }
        .searchable(text: $search.query)
        .navigationTitle("服务器视频")
    }
}

@MainActor private struct ConnectionControls: View {
    let store: Store
    @ObservedObject var server: ServerState
    @ObservedObject var gate: GateState

    var body: some View {
        Group {
            TextField("服务器地址", text: $server.address)
                .autocapitalization(.none).disableAutocorrection(true).keyboardType(.URL)
            Button("连接 / 刷新") { Task { await store.refresh() } }
        }
        .disabled(gate.busy || gate.loading)
    }
}

@MainActor private struct ActivityPanel: View {
    let store: Store
    @ObservedObject var activity: ActivityState

    var body: some View {
        if activity.loading {
            ProgressView("正在刷新")
        }
        if activity.busy {
            if activity.deletingLocal {
                ProgressView("正在清理本地视频")
            } else if activity.deletingRemote {
                ProgressView(activity.current.isEmpty ? "正在确认本地副本" : "正在删除远程：\(activity.current)")
            } else {
                ProgressView(activity.current.isEmpty ? "正在准备下载" : "正在下载：\(activity.current)")
            }
            if activity.batchTotal > 0 {
                ProgressView(value: Double(activity.batchProcessed), total: Double(activity.batchTotal))
                Text("已处理 \(activity.batchProcessed)/\(activity.batchTotal)，失败 \(activity.batchFailed)")
                Button(activity.stopRequested ? "等待当前文件完成" : "停止后续下载") { store.requestStop() }
                    .disabled(activity.stopRequested)
            }
        }
    }
}

@MainActor private struct CatalogActions: View {
    let store: Store
    @ObservedObject var catalog: CatalogState
    @ObservedObject var gate: GateState
    @State private var confirmDownload = false
    @State private var confirmRemote = false
    @State private var remoteSelection = Set<String>()

    var body: some View {
        Button("一键下载全部视频") { confirmDownload = true }
            .disabled(gate.busy || gate.loading || catalog.pendingCount == 0)
            .alert("下载全部视频？", isPresented: $confirmDownload) {
                Button("下载") { Task { await store.downloadAll() } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("下载当前服务器全部支持且尚未下载的视频，不受搜索筛选影响。预计新增 \(byteLabel(catalog.pendingBytes))。")
            }

        Button(role: .destructive) {
            remoteSelection = catalog.downloadedNames
            confirmRemote = true
        } label: {
            Text("删除已经下载的远程视频（\(catalog.downloadedCount)）")
        }
        .disabled(gate.busy || gate.loading || catalog.downloadedCount == 0)
        .confirmationDialog("删除服务器源文件？", isPresented: $confirmRemote, titleVisibility: .visible) {
            Button("删除远程视频", role: .destructive) {
                let confirmed = remoteSelection
                Task { await store.deleteDownloadedRemote(confirmedNames: confirmed) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅删除当前服务器上已有完整本地副本的 \(remoteSelection.count) 个视频。服务器文件不可恢复，本地副本保留。")
        }

        Text("待下载：\(catalog.pendingCount) 个 · \(byteLabel(catalog.pendingBytes))").font(.footnote)
    }
}

@MainActor private struct LocalUsage: View {
    @ObservedObject var library: LibraryState

    var body: some View {
        Text("本地已下载：\(library.items.count) 个 · 占用 \(byteLabel(library.bytes))").font(.headline)
    }
}

@MainActor private struct OperationMessage: View {
    @ObservedObject var activity: ActivityState
    var showLocalProgress = false

    var body: some View {
        if showLocalProgress && activity.deletingLocal {
            ProgressView("正在清理本地视频")
        }
        if !activity.message.isEmpty { Text(activity.message).font(.footnote) }
    }
}

@MainActor private struct RemoteRow: View {
    let store: Store
    @ObservedObject var catalog: CatalogState
    @ObservedObject var gate: GateState
    let entry: CatalogEntry

    var body: some View {
        let downloaded = catalog.downloadedNames.contains(entry.filename)
        VStack(alignment: .leading) {
            Text(entry.video.name)
            HStack {
                Text(byteLabel(entry.video.size)).font(.caption)
                Spacer()
                Button(downloaded ? "已下载" : entry.supported ? "下载" : "不支持") {
                    Task { await store.download(entry) }
                }
                .disabled(gate.busy || gate.loading || !entry.supported || downloaded)
            }
        }
    }
}

@MainActor private struct LocalPage: View {
    let store: Store
    @ObservedObject var library: LibraryState
    @State private var selected: LocalVideo?

    var body: some View {
        List {
            Section {
                LocalUsage(library: library)
                MarkSummary(marks: store.marks)
                ClearDownloads(store: store, gate: store.gate, isEmpty: library.items.isEmpty)
                OperationMessage(activity: store.activity, showLocalProgress: true)
            }
            ForEach(library.items) { item in
                Button { selected = item } label: {
                    LocalRow(item: item, marks: store.marks)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            MarkedDeletionButton(store: store, marks: store.marks, gate: store.gate)
        }
        .navigationTitle("已下载")
        .refreshable { await store.scan() }
        .sheet(item: $selected) { item in
            LocalPlayer(store: store, item: item).id(item.id)
        }
    }
}

@MainActor private struct MarkSummary: View {
    @ObservedObject var marks: MarkState

    var body: some View {
        Text("待删除：\(marks.names.count) 个 · \(byteLabel(marks.bytes))").foregroundColor(.orange)
    }
}

@MainActor private struct ClearDownloads: View {
    let store: Store
    @ObservedObject var gate: GateState
    let isEmpty: Bool
    @State private var confirm = false

    var body: some View {
        Button("一键删除已下载视频", role: .destructive) { confirm = true }
            .disabled(gate.busy || isEmpty)
            .alert("删除全部本地下载？", isPresented: $confirm) {
                Button("删除", role: .destructive) { Task { await store.deleteAll() } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("仅删除本 App 的本地文件，不会删除服务器视频。")
            }
    }
}

@MainActor private struct LocalRow: View {
    let item: LocalVideo
    @ObservedObject var marks: MarkState

    private var title: String {
        let name = item.name
        let prefix = name.prefix(16)
        guard prefix.count == 16, prefix.allSatisfy(\.isHexDigit), name.dropFirst(16).first == "_" else { return name }
        return String(name.dropFirst(17))
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text(title).foregroundColor(.primary)
            if marks.names.contains(item.name) {
                Label("待删除", systemImage: "trash").foregroundColor(.orange).font(.caption)
            }
            Text(byteLabel(item.size)).font(.caption)
        }
    }
}

@MainActor private struct MarkedDeletionButton: View {
    let store: Store
    @ObservedObject var marks: MarkState
    @ObservedObject var gate: GateState
    @State private var confirm = false

    var body: some View {
        let disabled = marks.names.isEmpty || gate.busy
        HStack {
            Spacer()
            Button { confirm = true } label: {
                Label("一键删除待删除（\(marks.names.count)）", systemImage: "trash")
                    .font(.subheadline.bold()).padding(12).foregroundColor(.white)
                    .background(disabled ? Color.gray : Color.red).clipShape(Capsule())
            }
            .disabled(disabled)
            .padding(.trailing, 12)
            .confirmationDialog("删除已标记的本地视频？", isPresented: $confirm, titleVisibility: .visible) {
                Button("删除待删除视频", role: .destructive) { Task { await store.deleteMarked() } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("删除 \(marks.names.count) 个已标记视频，其他本地视频不受影响。")
            }
        }
        .padding(.vertical, 6)
    }
}

@MainActor private struct LocalPlayer: View {
    let store: Store
    let item: LocalVideo
    @State private var player: AVPlayer?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.padding()
            }
            VideoPlayer(player: player)
            HStack {
                Spacer()
                PlayerMarkButton(store: store, item: item, marks: store.marks).padding()
            }
        }
        .background(Color.black).foregroundColor(.white)
        .onAppear {
            if player == nil { player = AVPlayer(url: item.url) }
            player?.play()
        }
        .onDisappear { player?.pause() }
    }
}

@MainActor private struct PlayerMarkButton: View {
    let store: Store
    let item: LocalVideo
    @ObservedObject var marks: MarkState

    var body: some View {
        let marked = marks.names.contains(item.name)
        Button { store.toggleMark(item) } label: {
            Label(marked ? "已标记 · 取消待删除" : "待删除", systemImage: marked ? "checkmark.circle.fill" : "trash")
                .padding(12).foregroundColor(.white)
                .background(marked ? Color.orange : Color.gray).clipShape(Capsule())
        }
    }
}
