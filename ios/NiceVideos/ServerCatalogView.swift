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
    @State private var pendingServerDeletionServer = ""
    @State private var deletingServerNames = Set<String>()
    @State private var pendingDownloadedDeletion: DownloadedServerDeletionPlan?
    @State private var deletingDownloaded = false
    @State private var downloadedDeletionResult: DownloadedServerDeletionResult?

    private var filtered: [Video] {
        store.videos.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var downloadedPlan: DownloadedServerDeletionPlan {
        DownloadedServerDeletionPlan(server: store.server, videos: store.videos, records: store.completed)
    }

    private var deletingFromServer: Bool { deletingDownloaded || !deletingServerNames.isEmpty }

    var body: some View {
        List {
            downloadedDeletionSection
            Section {
                Text("服务器用于获取列表、下载和远程删除。删除服务器视频不会删除手机中已经下载好的本地副本。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if store.server.isEmpty {
                    Text("请先在「设置」填写 Mac 的局域网地址。")
                } else {
                    Button("读取 / 刷新服务器列表") { store.refresh() }
                        .disabled(store.loading || deletingFromServer)
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
                                pendingServerDeletionServer = store.server
                                pendingServerDeletion = video
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            .disabled(record?.state == .downloading || deletingDownloaded || store.restoring || store.loading)
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
                    .disabled(store.restoring || deletingFromServer || !store.videos.contains(where: { $0.supportsOffline }))
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
        .onChange(of: store.server) { _, _ in
            pendingServerDeletion = nil
            pendingDownloadedDeletion = nil
            downloadedDeletionResult = nil
            confirmAll = false
        }
    }

    private var downloadedDeletionSection: some View {
        let plan = downloadedPlan
        return Section {
            Text("一键清理当前服务器中已经完整下载到手机的视频，只删除服务器源文件，保留手机本地副本。未完成下载或本地文件缺失的项目不会删除。")
                .font(.footnote).foregroundStyle(.secondary)
            Button(role: .destructive) {
                pendingDownloadedDeletion = plan
            } label: {
                Label("一键删除已经下载的视频（\(plan.records.count)）", systemImage: "trash")
            }
            .disabled(plan.records.isEmpty || store.restoring || store.loading || deletingFromServer)
            .accessibilityIdentifier("deleteDownloadedServerVideosButton")
            .confirmationDialog("删除这 \(pendingDownloadedDeletion?.records.count ?? 0) 个已下载视频的服务器源文件？",
                                isPresented: Binding(
                                    get: { pendingDownloadedDeletion != nil },
                                    set: { if !$0 { pendingDownloadedDeletion = nil } }
                                ), titleVisibility: .visible, presenting: pendingDownloadedDeletion) { snapshot in
                Button("确认删除服务器源文件", role: .destructive) { deleteDownloadedFromServer(snapshot) }
                Button("取消", role: .cancel) { pendingDownloadedDeletion = nil }
            } message: { snapshot in
                Text("服务器：\(snapshot.server)\n只处理本次确认时已下载完成的视频，不受搜索条件影响。手机本地副本、收藏和待删除标记均保留。此操作不可撤销。")
            }
            if deletingDownloaded {
                ProgressView("正在删除服务器视频，请勿重复操作")
            }
            if let result = downloadedDeletionResult {
                Text(result.summary).font(.footnote)
                    .accessibilityIdentifier("downloadedServerDeletionResult")
                if !result.details.isEmpty || !result.failures.isEmpty {
                    DisclosureGroup("查看处理结果") {
                        ForEach(Array((result.details + result.failures).enumerated()), id: \.offset) { _, detail in
                            Text(detail).font(.caption).textSelection(.enabled)
                        }
                    }
                }
            }
        } header: {
            Text("已经下载 · \(plan.records.count)")
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
            .disabled(store.restoring || deletingFromServer)
        }
    }

    private func deleteFromServer(_ video: Video) {
        let selectedServer = pendingServerDeletionServer
        pendingServerDeletion = nil
        guard store.server == selectedServer, !deletingDownloaded else {
            store.errorMessage = "服务器已切换或正在批量清理，请重新确认删除。"
            return
        }
        deletingServerNames.insert(video.name)
        Task { @MainActor in
            defer { deletingServerNames.remove(video.name) }
            guard store.server == selectedServer else {
                store.errorMessage = "服务器已切换，请重新确认删除。"
                return
            }
            do {
                try await store.deleteServerVideo(video, expectedServer: selectedServer)
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteDownloadedFromServer(_ snapshot: DownloadedServerDeletionPlan) {
        pendingDownloadedDeletion = nil
        guard !deletingFromServer else { return }
        deletingDownloaded = true
        downloadedDeletionResult = nil
        Task { @MainActor in
            defer { deletingDownloaded = false }
            let result = await store.deleteDownloadedServerVideos(snapshot)
            if store.server == snapshot.server { downloadedDeletionResult = result }
        }
    }
}
