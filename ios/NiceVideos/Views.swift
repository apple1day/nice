import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: VideoStore
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TabView {
            NavigationStack { OfflineView() }
                .tabItem { Label("本地", systemImage: "internaldrive") }
            NavigationStack { CatalogView() }
                .tabItem { Label("服务器", systemImage: "server.rack") }
            NavigationStack { TransfersView() }
                .tabItem { Label("下载", systemImage: "arrow.down.circle") }
            NavigationStack { SettingsView() }
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .fullScreenCover(item: $store.playback) { request in
            PlaybackScreen(request: request).environmentObject(store)
        }
        .alert("提示", isPresented: Binding(
            get: { store.playback == nil && store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) { Button("确定", role: .cancel) { store.errorMessage = nil } }
        message: { Text(store.errorMessage ?? "") }
        // Intentionally NO startup refresh, reachability gate, or login gate.
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
            PendingDeletionSection()
            Section {
                Text("服务器仅用于获取列表和下载。播放前必须下载完成。")
                    .font(.footnote).foregroundStyle(.secondary)
                if store.server.isEmpty {
                    Text("请先在「设置」填写 Mac 的局域网地址。")
                } else {
                    Button("读取 / 刷新服务器列表") { store.refresh() }.disabled(store.loading)
                }
                if let notice = store.catalogNotice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                if store.loading { ProgressView("读取列表中；本地播放不受影响") }
            }
            ForEach(filtered) { video in
                let record = store.record(for: video)
                VStack(alignment: .leading, spacing: 10) {
                    Label(video.name, systemImage: "film").font(.headline).lineLimit(2)
                    Text("\(video.sizeLabel) · \(video.fileExtension.uppercased())")
                        .font(.caption).foregroundStyle(.secondary)
                    if let record = record, store.isPendingDeletion(record.id) {
                        Label("手机副本待删除", systemImage: "trash").font(.caption).foregroundStyle(.orange)
                    }
                    if !video.supportsOffline {
                        Text("暂不下载此格式；播放清单不是独立视频。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let record = record, record.state == .complete {
                        Button { store.playLocal(record) } label: { Label("本地播放", systemImage: "play.fill") }
                    } else if let record = record, record.state == .downloading {
                        ProgressView(value: store.progress[record.id] ?? 0)
                        Text("下载中 \(Int((store.progress[record.id] ?? 0) * 100))%")
                            .font(.caption)
                    } else {
                        Button { store.download(video) } label: {
                            Label(record?.state == .failed ? "重新下载" : "下载到手机", systemImage: "arrow.down.to.line")
                        }.disabled(store.restoring)
                    }
                }.padding(.vertical, 6).buttonStyle(.borderless)
            }
        }
        .navigationTitle("服务器视频")
        .searchable(text: $search, prompt: "搜索文件名")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("全部下载") { confirmAll = true }
                    .disabled(store.restoring || !store.videos.contains(where: { $0.supportsOffline }))
            }
        }
        .confirmationDialog("下载全部支持的完整视频文件？", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("加入下载队列") { store.downloadAll() }
        } message: { Text("跳过本机已有或正在下载的视频。不下载 ZIP 或播放清单，请确认空间和流量。") }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: VideoStore
    @AppStorage("allowCellular") private var allowCellular = false
    @State private var draft = ""
    var body: some View {
        Form {
            SigningStatusSection()
            Section("视频服务器（仅列表与下载使用）") {
                TextField("http://192.168.19.70:8106", text: $draft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Button("保存并读取视频列表") { store.configureServer(draft) }
                Text("真机填写 Mac 的局域网地址，不要填写 localhost。播放本地视频不需要配置服务器。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("下载网络") {
                Toggle("允许新下载使用蜂窝数据", isOn: $allowCellular)
                Text("只影响新创建的任务；已有任务需要取消重试。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("离线播放器") {
                Text("MobileVLCKit 3.7.3 · 原生 VLC 内核 · 不使用 WebView")
                Text("支持下载 MP4、M4V、MOV、MKV、AVI、WebM、OGG、FLV、WMV、TS 完整文件。具体编码及设备解码能力仍需验证；不支持 HLS/DASH 清单离线下载。")
                Text("退出、锁屏、来电或拔出耳机时暂停；返回后手动继续。当前不提供画中画、后台音频、倍速或字幕选择界面。")
                Text("更换服务器不会清除本地文件。卸载 App 会删除下载；升级时保持原 Bundle Identifier。")
                NavigationLink("开源组件与许可证") { LicenseView() }
            }.font(.footnote)
            Section("安全") {
                Text("现有 Go 后端没有鉴权。仅在可信局域网使用，不要直接把 8106 暴露到公网。")
                    .font(.footnote)
            }
        }.navigationTitle("设置").onAppear { draft = store.server }
    }
}

private struct LicenseView: View {
    private var notices: String {
        let names = ["NOTICE", "MobileVLCKit-COPYING", "Acknowledgements"]
        return names.compactMap { name in
            guard let url = Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "Licenses") else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }.joined(separator: "\n\n────────────\n\n")
    }
    var body: some View {
        ScrollView { Text(notices).font(.footnote).textSelection(.enabled).padding() }
            .navigationTitle("开源许可证")
    }
}
