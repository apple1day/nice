import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: VideoStore
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TabView {
            NavigationStack { CatalogView() }
                .tabItem { Label("视频", systemImage: "play.rectangle") }
            NavigationStack { OfflineView() }
                .tabItem { Label("本地", systemImage: "internaldrive") }
            NavigationStack { TransfersView() }
                .tabItem { Label("下载", systemImage: "arrow.down.circle") }
            NavigationStack { SettingsView() }
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .sheet(item: $store.playback) { request in PlaybackScreen(request: request) }
        .alert("提示", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) { Button("确定", role: .cancel) { store.errorMessage = nil } }
        message: { Text(store.errorMessage ?? "") }
        .task { store.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.reconcileFiles() }
        }
    }
}

struct CatalogView: View {
    @EnvironmentObject private var store: VideoStore
    @State private var search = ""
    @State private var confirmAll = false
    private var filtered: [Video] {
        store.videos.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        List {
            if store.server.isEmpty {
                ContentUnavailableView("连接你的视频站", systemImage: "network",
                    description: Text("在「设置」填写 Mac 的局域网地址。无需注册账号。"))
            }
            if let notice = store.catalogNotice {
                Section { Label(notice, systemImage: "wifi.slash").font(.footnote).foregroundStyle(.secondary) }
            }
            if store.loading { ProgressView("更新列表中；本地视频始终可用") }
            ForEach(filtered) { video in
                VStack(alignment: .leading, spacing: 10) {
                    Label(video.name, systemImage: "film").font(.headline).lineLimit(2)
                    HStack {
                        Text(video.sizeLabel)
                        Text(video.fileExtension.uppercased())
                        Spacer()
                        if store.record(for: video)?.state == .complete {
                            Label("已在本机", systemImage: "checkmark.circle.fill")
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                    if !video.supportsStreaming {
                        Text("需要扩展解码器；当前版本不支持此格式")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button { store.play(video) } label: {
                            Label(store.record(for: video)?.state == .complete ? "本地播放" : "在线播放",
                                  systemImage: "play.fill")
                        }.disabled(!video.supportsStreaming)
                        Spacer()
                        if store.record(for: video)?.state == .downloading {
                            Text("下载中 \(Int((store.progress[store.record(for: video)?.id ?? ""] ?? 0) * 100))%")
                                .font(.caption)
                        } else {
                            Button { store.download(video) } label: {
                                Label("下载", systemImage: "arrow.down.to.line")
                            }.disabled(!video.supportsOffline || store.restoring || store.record(for: video)?.state == .complete)
                        }
                    }.buttonStyle(.borderless)
                }.padding(.vertical, 6)
            }
            if !store.server.isEmpty && !store.loading && filtered.isEmpty {
                Text("没有匹配的视频。可刷新列表，或前往「本地」查看已下载内容。")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Nice 视频")
        .searchable(text: $search, prompt: "搜索文件名")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("刷新视频列表").disabled(store.loading || store.server.isEmpty)
                Button { confirmAll = true } label: { Image(systemName: "arrow.down.circle") }
                    .accessibilityLabel("下载全部兼容视频")
                    .disabled(store.restoring || !store.videos.contains(where: { $0.supportsOffline }))
            }
        }
        .confirmationDialog("下载全部 MP4、M4V、MOV？", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("加入下载队列") { store.downloadAll() }
        } message: {
            Text("已在本机和正在下载的会跳过。每个文件单独下载，不使用 ZIP；请确认手机空间和流量设置。")
        }
    }
}

struct OfflineView: View {
    @EnvironmentObject private var store: VideoStore
    @State private var search = ""
    @State private var deletion: DownloadRecord?
    private var filtered: [DownloadRecord] {
        store.completed.filter { search.isEmpty || $0.video.name.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        List {
            Section {
                Label("断网也能打开和播放，不需要服务器在线。", systemImage: "checkmark.shield")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("\(store.completed.count) 个视频 · \(ByteCountFormatter.string(fromByteCount: store.usedBytes, countStyle: .file))")
            }
            ForEach(filtered) { record in
                Button { store.playLocal(record) } label: {
                    HStack {
                        Image(systemName: "play.circle.fill").font(.title)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.video.name).foregroundStyle(.primary).lineLimit(2)
                            Text(record.video.sizeLabel).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }
                .swipeActions {
                    Button("删除", role: .destructive) { deletion = record }
                }
            }
            if filtered.isEmpty {
                ContentUnavailableView("暂无本地视频", systemImage: "internaldrive",
                    description: Text("先在「视频」下载一个 MP4，完成后即可离线播放。"))
            }
        }
        .navigationTitle("本地视频")
        .searchable(text: $search, prompt: "搜索本地视频")
        .confirmationDialog("仅删除手机中的文件？", isPresented: Binding(
            get: { deletion != nil }, set: { if !$0 { deletion = nil } }
        ), titleVisibility: .visible) {
            Button("删除本地文件", role: .destructive) {
                if let record = deletion { store.removeFromDevice(record) }
                deletion = nil
            }
        } message: { Text("不会删除服务器上的视频。") }
    }
}

struct TransfersView: View {
    @EnvironmentObject private var store: VideoStore
    var body: some View {
        List {
            Section {
                Text("默认仅通过 Wi-Fi 下载。系统可能等待网络；切换后台由 iOS 调度。不要上划强退 App。")
                    .font(.footnote).foregroundStyle(.secondary)
                if store.restoring { ProgressView("恢复系统下载任务") }
            }
            ForEach(store.unfinished) { record in
                VStack(alignment: .leading, spacing: 10) {
                    Text(record.video.name).font(.headline)
                    if record.state == .downloading {
                        ProgressView(value: store.progress[record.id] ?? 0)
                        HStack {
                            Text("\(Int((store.progress[record.id] ?? 0) * 100))% · \(record.video.sizeLabel)")
                                .font(.caption)
                            Spacer()
                            Button("取消") { store.cancel(record) }
                        }
                    } else {
                        Text(record.message ?? "下载失败").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("重新下载") { store.retry(record) }.disabled(store.restoring)
                            Spacer()
                            Button("移除记录", role: .destructive) { store.removeFromDevice(record) }
                        }
                    }
                }.padding(.vertical, 5).buttonStyle(.borderless)
            }
            if store.unfinished.isEmpty { Text("没有进行中或失败的任务。下载完成的视频在「本地」。").foregroundStyle(.secondary) }
        }.navigationTitle("下载任务")
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: VideoStore
    @AppStorage("allowCellular") private var allowCellular = false
    @State private var draft = ""
    var body: some View {
        Form {
            Section("视频服务器") {
                TextField("http://192.168.1.10:8106", text: $draft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Button("保存并读取视频列表") { store.configureServer(draft) }
                Text("填写服务器根地址。真机不要填写 localhost；它指向手机，而不是 Mac。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("下载网络") {
                Toggle("允许新下载使用蜂窝数据", isOn: $allowCellular)
                Text("只影响此后创建的任务；已有任务需取消后重试。大视频可能消耗大量流量。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("离线与格式") {
                Text("原生 SwiftUI + AVPlayer，无 WebView。下载保存为手机里的真实文件，不依赖网页缓存。")
                Text("当前下载 MP4、M4V、MOV；内部音视频编码仍须设备支持。HLS 仅尝试在线播放，不下载 m3u8 清单。MKV/AVI 等暂不支持。")
                Text("从服务器删除视频或更换服务器地址，不会清除本地下载。卸载 App 会删除其本地文件。")
            }.font(.footnote)
            Section("安全") {
                Text("当前 Go 后端没有登录鉴权。仅在可信局域网使用，不要把 8106 端口直接暴露到公网。公网连接应使用 HTTPS，并先补充鉴权。")
                    .font(.footnote)
            }
        }
        .navigationTitle("设置")
        .onAppear { draft = store.server }
    }
}
