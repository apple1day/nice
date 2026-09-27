import SwiftUI

struct UpdatedRootView: View {
    @EnvironmentObject private var store: VideoStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            NavigationStack { OfflineView() }
                .tabItem { Label("本地", systemImage: "internaldrive") }
            NavigationStack { ServerCatalogView() }
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.reconcileFiles() }
        }
    }
}

struct ServerCatalogView: View {
    @EnvironmentObject private var store: VideoStore
    @State private var search = ""
    @State private var confirmAll = false
    @State private var pendingServerDeletion: Video?
    @State private var deletingServerNames = Set<String>()

    private var filtered: [Video] {
        store.videos.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            PendingDeletionSection()
            Section {
                Text("服务器用于获取列表、下载和远程删除。删除服务器视频不会删除手机中已经下载好的本地副本。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if store.server.isEmpty {
                    Text("请先在「设置」填写 Mac 的局域网地址。")
                } else {
                    Button("读取 / 刷新服务器列表") { store.refresh() }
                        .disabled(store.loading)
                }
                if let notice = store.catalogNotice {
                    Text(notice).font(.footnote).foregroundStyle(.secondary)
                }
                if store.loading {
                    ProgressView("读取列表中；本地播放不受影响")
                }
            }

            ForEach(filtered) { video in
                let record = store.record(for: video)
                VStack(alignment: .leading, spacing: 10) {
                    Label(video.name, systemImage: "film")
                        .font(.headline)
                        .lineLimit(2)
                    Text("\(video.sizeLabel) · \(video.fileExtension.uppercased())")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let record = record, store.isPendingDeletion(record.id) {
                        Label("手机副本待删除", systemImage: "trash")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if !video.supportsOffline {
                        Text("暂不下载此格式；播放清单不是独立视频。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let record = record, record.state == .downloading {
                        ProgressView(value: store.progress[record.id] ?? 0)
                        Text("下载中 \(Int((store.progress[record.id] ?? 0) * 100))% · 请先取消下载再删除服务器源文件")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 16) {
                        primaryAction(video: video, record: record)
                        Spacer(minLength: 12)
                        if deletingServerNames.contains(video.name) {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("正在删除服务器视频")
                        } else {
                            Button(role: .destructive) {
                                pendingServerDeletion = video
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            .disabled(record?.state == .downloading)
                            .accessibilityIdentifier("deleteServerVideo.\(video.name)")
                        }
                    }
                }
                .padding(.vertical, 6)
                .buttonStyle(.borderless)
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
        .confirmationDialog("下载全部支持的完整视频文件？",
                            isPresented: $confirmAll,
                            titleVisibility: .visible) {
            Button("加入下载队列") { store.downloadAll() }
        } message: {
            Text("跳过本机已有或正在下载的视频。不下载 ZIP 或播放清单，请确认空间和流量。")
        }
        .confirmationDialog(pendingServerDeletion.map { "删除服务器视频“\($0.name)”？" } ?? "删除服务器视频？",
                            isPresented: Binding(
                                get: { pendingServerDeletion != nil },
                                set: { if !$0 { pendingServerDeletion = nil } }
                            ),
                            titleVisibility: .visible,
                            presenting: pendingServerDeletion) { video in
            Button("从服务器删除", role: .destructive) {
                deleteFromServer(video)
            }
            Button("取消", role: .cancel) { pendingServerDeletion = nil }
        } message: { video in
            Text("服务器中的“\(video.name)”会被删除。手机中已下载完成的本地副本会保留。")
        }
    }

    @ViewBuilder
    private func primaryAction(video: Video, record: DownloadRecord?) -> some View {
        if !video.supportsOffline {
            Button { } label: { Label("不支持下载", systemImage: "nosign") }
                .disabled(true)
        } else if let record = record, record.state == .complete {
            Button { store.playLocal(record) } label: {
                Label("本地播放", systemImage: "play.fill")
            }
        } else if let record = record, record.state == .downloading {
            Button { } label: { Label("下载中", systemImage: "arrow.down.circle") }
                .disabled(true)
        } else {
            Button { store.download(video) } label: {
                Label(record?.state == .failed ? "重新下载" : "下载到手机",
                      systemImage: "arrow.down.to.line")
            }
            .disabled(store.restoring || deletingServerNames.contains(video.name))
        }
    }

    private func deleteFromServer(_ video: Video) {
        pendingServerDeletion = nil
        deletingServerNames.insert(video.name)
        Task { @MainActor in
            defer { deletingServerNames.remove(video.name) }
            do {
                try await store.deleteServerVideo(video)
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }
}
