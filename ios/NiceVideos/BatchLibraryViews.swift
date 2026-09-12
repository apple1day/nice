import SwiftUI

struct OfflineView: View {
    @EnvironmentObject private var store: VideoStore
    @State private var search = ""
    @State private var selection = BatchSelection()
    @State private var pendingRemoval: BatchRemovalRequest?
    @State private var notice: String?

    private var filtered: [DownloadRecord] {
        store.completed.filter { search.isEmpty || $0.video.name.localizedCaseInsensitiveContains(search) }
    }
    private var visibleTokens: Set<String> { Set(filtered.map(\.taskToken)) }

    var body: some View {
        List {
            Section {
                Label("所有播放均读取手机文件，无需服务器在线。", systemImage: "checkmark.shield")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("\(store.completed.count) 个视频 · \(ByteCountFormatter.string(fromByteCount: store.usedBytes, countStyle: .file))")
                if let notice = notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
            }
            if selection.isSelecting {
                BatchSelectionHeader(selection: $selection, visibleTokens: visibleTokens)
            } else {
                PendingDeletionSection()
            }
            ForEach(filtered) { record in
                Button {
                    if selection.isSelecting { selection.toggle(record.taskToken) }
                    else { store.playLocal(record) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selection.isSelecting
                              ? (selection.tokens.contains(record.taskToken) ? "checkmark.circle.fill" : "circle")
                              : "play.circle.fill")
                            .font(.title2).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.video.name).foregroundStyle(.primary).lineLimit(2)
                            Text("\(record.video.fileExtension.uppercased()) · \(record.video.sizeLabel)")
                                .font(.caption).foregroundStyle(.secondary)
                            if store.isPendingDeletion(record.id) {
                                Label("待删除", systemImage: "trash").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer(minLength: 0)
                    }.padding(.vertical, 4).contentShape(Rectangle())
                }
                .accessibilityValue(selection.isSelecting
                                    ? (selection.tokens.contains(record.taskToken) ? "已选择" : "未选择")
                                    : "本地播放")
                .swipeActions {
                    if !selection.isSelecting {
                        Button("删除", role: .destructive) {
                            pendingRemoval = BatchRemovalRequest(scope: .localVideos, records: [record])
                        }
                    }
                }
            }
            if filtered.isEmpty {
                ContentUnavailableView(search.isEmpty ? "暂无本地视频" : "没有匹配的视频", systemImage: "internaldrive",
                    description: Text("在「设置」连接视频站，再到「服务器」下载。完成后即可在此离线播放。"))
            }
        }
        .navigationTitle("本地视频")
        .searchable(text: $search, prompt: "搜索本地视频")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(selection.isSelecting ? "完成" : "选择") {
                    if selection.isSelecting { selection.end() } else { selection.begin(); notice = nil }
                }
                .disabled(!selection.isSelecting && filtered.isEmpty)
                .accessibilityIdentifier("local.selection.toggle")
            }
            if selection.isSelecting {
                ToolbarItem(placement: .bottomBar) {
                    Button("删除所选（\(selection.tokens.count)）", role: .destructive) {
                        pendingRemoval = BatchRemovalRequest(scope: .localVideos,
                            records: filtered.filter { selection.tokens.contains($0.taskToken) })
                    }
                    .disabled(selection.tokens.isEmpty)
                    .accessibilityIdentifier("local.selection.delete")
                }
            }
        }
        .onChange(of: visibleTokens) { _, tokens in selection.reconcile(with: tokens) }
        .onDisappear { selection.end(); pendingRemoval = nil }
        .modifier(BatchRemovalDialog(request: $pendingRemoval) { request in
            let result = store.removeBatch(request)
            notice = result.summary(for: request.scope)
            selection.reconcile(with: visibleTokens)
            // Failed rows stay selected for retry; successful rows disappear.
            if selection.tokens.isEmpty { selection.end() }
        })
    }
}

struct TransfersView: View {
    @EnvironmentObject private var store: VideoStore
    @State private var selection = BatchSelection()
    @State private var pendingRemoval: BatchRemovalRequest?
    @State private var notice: String?
    private var visibleTokens: Set<String> { Set(store.unfinished.map(\.taskToken)) }

    var body: some View {
        List {
            Section {
                Text("默认禁用新下载的蜂窝数据。后台传输由 iOS 调度；手动上划强退会中断任务，失败重试从头下载。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("删除或清空仅影响本页未完成的任务，已下载的本地视频会保留。")
                    .font(.footnote).foregroundStyle(.secondary)
                if store.restoring { ProgressView("恢复系统下载任务") }
                if let notice = notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
            }
            if selection.isSelecting {
                BatchSelectionHeader(selection: $selection, visibleTokens: visibleTokens)
            }
            ForEach(store.unfinished) { record in
                if selection.isSelecting {
                    // No nested cancel/retry buttons in selection mode. Tapping
                    // any part of a row only changes its selection.
                    Button { selection.toggle(record.taskToken) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selection.tokens.contains(record.taskToken)
                                  ? "checkmark.circle.fill" : "circle")
                                .font(.title2).accessibilityHidden(true)
                            transferDetails(record, showActions: false)
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(selection.tokens.contains(record.taskToken) ? "已选择" : "未选择")
                } else {
                    transferDetails(record, showActions: true).buttonStyle(.borderless)
                }
            }
            if store.unfinished.isEmpty {
                Text("没有进行中或失败的任务。下载完成的视频在「本地」。").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("下载任务")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(selection.isSelecting ? "完成" : "选择") {
                    if selection.isSelecting { selection.end() } else { selection.begin(); notice = nil }
                }
                .disabled(!selection.isSelecting && (store.unfinished.isEmpty || store.restoring))
                .accessibilityIdentifier("transfers.selection.toggle")
                Button("一键清空", role: .destructive) {
                    pendingRemoval = BatchRemovalRequest(scope: .downloadTasks,
                                                         records: store.unfinished, clearAll: true)
                }
                .disabled(store.unfinished.isEmpty || store.restoring)
                .accessibilityIdentifier("transfers.clearAll")
            }
            if selection.isSelecting {
                ToolbarItem(placement: .bottomBar) {
                    Button("删除所选（\(selection.tokens.count)）", role: .destructive) {
                        pendingRemoval = BatchRemovalRequest(scope: .downloadTasks,
                            records: store.unfinished.filter { selection.tokens.contains($0.taskToken) })
                    }
                    .disabled(selection.tokens.isEmpty || store.restoring)
                    .accessibilityIdentifier("transfers.selection.delete")
                }
            }
        }
        .onChange(of: visibleTokens) { _, tokens in selection.reconcile(with: tokens) }
        .onDisappear { selection.end(); pendingRemoval = nil }
        .modifier(BatchRemovalDialog(request: $pendingRemoval) { request in
            let result = store.removeBatch(request)
            notice = result.summary(for: request.scope)
            selection.reconcile(with: visibleTokens)
            if selection.tokens.isEmpty { selection.end() }
        })
    }

    private func transferDetails(_ record: DownloadRecord, showActions: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(record.video.name).font(.headline).foregroundStyle(.primary)
            if record.state == .downloading {
                ProgressView(value: store.progress[record.id] ?? 0)
                HStack {
                    Text("\(Int((store.progress[record.id] ?? 0) * 100))% · \(record.video.sizeLabel)")
                        .font(.caption).foregroundStyle(.secondary)
                    if showActions {
                        Spacer()
                        Button("取消") { store.cancel(record) }.disabled(store.restoring)
                    }
                }
            } else {
                Text(record.message ?? "下载失败").font(.caption).foregroundStyle(.secondary)
                if showActions {
                    HStack {
                        Button("重新下载") { store.retry(record) }.disabled(store.restoring)
                        Spacer()
                        Button("移除记录", role: .destructive) {
                            pendingRemoval = BatchRemovalRequest(scope: .downloadTasks, records: [record])
                        }.disabled(store.restoring)
                    }
                }
            }
        }.padding(.vertical, 5)
    }
}

private struct BatchSelectionHeader: View {
    @Binding var selection: BatchSelection
    let visibleTokens: Set<String>
    var body: some View {
        Section {
            HStack {
                Text("已选 \(selection.tokens.count) / \(visibleTokens.count) 项")
                Spacer()
                Button(selection.allSelected(in: visibleTokens) ? "取消全选" : "全选") {
                    selection.toggleAll(in: visibleTokens)
                }.disabled(visibleTokens.isEmpty).buttonStyle(.borderless)
            }
        } footer: {
            Text("全选仅针对当前显示的项目；切换搜索会取消隐藏项目的选择。")
        }
    }
}

private struct BatchRemovalDialog: ViewModifier {
    @Binding var request: BatchRemovalRequest?
    let onConfirm: (BatchRemovalRequest) -> Void
    func body(content: Content) -> some View {
        content.confirmationDialog(request?.title ?? "确认删除", isPresented: Binding(
            get: { request != nil }, set: { if !$0 { request = nil } }
        ), titleVisibility: .visible, presenting: request) { snapshot in
            Button(snapshot.confirmLabel, role: .destructive) {
                request = nil
                onConfirm(snapshot)
            }
            Button("取消", role: .cancel) { request = nil }
        } message: { snapshot in
            Text(snapshot.explanation)
        }
    }
}
