import SwiftUI

struct OfflineView: View {
    @EnvironmentObject private var store: VideoStore
    @State private var search = ""
    @State private var selection = BatchSelection()
    @State private var deletion: BatchDeletionRequest?
    @State private var result: BatchDeletionResult?

    private var filtered: [DownloadRecord] {
        store.completed.filter { search.isEmpty || $0.video.name.localizedCaseInsensitiveContains(search) }
    }
    private var visibleTokens: [String] { filtered.map(\.taskToken) }
    private var selected: [DownloadRecord] { filtered.filter { selection.contains($0.taskToken) } }

    var body: some View {
        List {
            Section {
                Label("所有播放均读取手机文件，无需服务器在线。", systemImage: "checkmark.shield")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("\(store.completed.count) 个视频 · \(ByteCountFormatter.string(fromByteCount: store.usedBytes, countStyle: .file))")
                if selection.isSelecting {
                    Text("点击视频勾选；全选仅针对当前搜索结果。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let result = result { BatchDeletionResultSection(result: result) }
            if !selection.isSelecting { PendingDeletionSection() }
            ForEach(filtered) { record in
                Button {
                    if selection.isSelecting { selection.toggle(record.taskToken) }
                    else { store.playLocal(record) }
                } label: {
                    HStack {
                        if selection.isSelecting {
                            SelectionIndicator(selected: selection.contains(record.taskToken))
                        } else {
                            Image(systemName: "play.circle.fill").font(.title)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Text(record.video.name).foregroundStyle(.primary).lineLimit(2)
                                if record.isFavorite {
                                    Image(systemName: "star.fill")
                                        .foregroundStyle(.yellow)
                                        .accessibilityLabel("已收藏")
                                        .accessibilityIdentifier("favoriteBadge.\(record.id)")
                                }
                            }
                            Text("\(record.video.fileExtension.uppercased()) · \(record.video.sizeLabel)")
                                .font(.caption).foregroundStyle(.secondary)
                            if store.isPendingDeletion(record.id) {
                                Label("待删除", systemImage: "trash").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(selection.isSelecting
                                    ? (selection.contains(record.taskToken) ? "已选择" : "未选择") : "本地播放")
                .accessibilityIdentifier("localVideoRow.\(record.id)")
                .swipeActions(allowsFullSwipe: false) {
                    if !selection.isSelecting {
                        Button("删除", role: .destructive) {
                            deletion = BatchDeletionRequest(scope: .localVideos, records: [record])
                        }.disabled(store.restoring)
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
            ToolbarItemGroup(placement: .topBarTrailing) {
                if selection.isSelecting {
                    Button(selection.allSelected(in: visibleTokens) ? "取消全选" : "全选") {
                        selection.toggleAll(in: visibleTokens)
                    }.disabled(filtered.isEmpty)
                    Button("取消") { selection.cancel() }
                } else {
                    Button("选择") { result = nil; selection.begin() }
                        .disabled(filtered.isEmpty || store.restoring)
                        .accessibilityIdentifier("selectLocalVideosButton")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selection.isSelecting {
                BatchDeletionFooter(count: selected.count, disabled: store.restoring) {
                    deletion = BatchDeletionRequest(scope: .localVideos, records: selected)
                }
            }
        }
        .onChange(of: visibleTokens) { _, tokens in selection.retainVisible(tokens) }
        .confirmationDialog(deletion?.title ?? "删除本地视频？", isPresented: Binding(
            get: { deletion != nil }, set: { if !$0 { deletion = nil } }
        ), titleVisibility: .visible, presenting: deletion) { snapshot in
            Button(snapshot.buttonTitle, role: .destructive) { performDeletion(snapshot) }
            Button("取消", role: .cancel) { deletion = nil }
        } message: { snapshot in Text(snapshot.message) }
    }

    private func performDeletion(_ snapshot: BatchDeletionRequest) {
        deletion = nil
        let outcome = store.deleteBatch(snapshot)
        result = outcome
        selection.retainVisible(visibleTokens)
        // Keep failed rows selected so they can be retried; successful rows vanish.
        if outcome.failures.isEmpty { selection.cancel() }
    }
}

struct TransfersView: View {
    @EnvironmentObject private var store: VideoStore
    @State private var selection = BatchSelection()
    @State private var deletion: BatchDeletionRequest?
    @State private var result: BatchDeletionResult?

    private var visibleTokens: [String] { store.unfinished.map(\.taskToken) }
    private var selected: [DownloadRecord] { store.unfinished.filter { selection.contains($0.taskToken) } }

    var body: some View {
        List {
            Section {
                Text("默认禁用新下载的蜂窝数据。后台传输由 iOS 调度；手动上划强退会中断任务，失败重试从头下载。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("删除或清空会取消进行中的任务；已下载完成的本地视频不会删除。")
                    .font(.footnote).foregroundStyle(.secondary)
                if store.restoring { ProgressView("恢复系统下载任务") }
            }
            if let result = result { BatchDeletionResultSection(result: result) }
            ForEach(store.unfinished) { record in
                if selection.isSelecting {
                    Button { selection.toggle(record.taskToken) } label: {
                        HStack(spacing: 12) {
                            SelectionIndicator(selected: selection.contains(record.taskToken))
                            transferDescription(record)
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(selection.contains(record.taskToken) ? "已选择" : "未选择")
                    .accessibilityIdentifier("selectDownloadTask.\(record.id)")
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        transferDescription(record)
                        if record.state == .downloading {
                            HStack {
                                Spacer()
                                Button("取消") { store.cancel(record) }.disabled(store.restoring)
                            }
                        } else {
                            HStack {
                                Button("重新下载") { store.retry(record) }.disabled(store.restoring)
                                Spacer()
                                Button("移除记录", role: .destructive) {
                                    deletion = BatchDeletionRequest(scope: .downloadTasks, records: [record])
                                }.disabled(store.restoring)
                            }
                        }
                    }.padding(.vertical, 5).buttonStyle(.borderless)
                }
            }
            if store.unfinished.isEmpty {
                Text("没有进行中或失败的任务。下载完成的视频在「本地」。").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("下载任务")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("一键清空", role: .destructive) {
                    deletion = BatchDeletionRequest(scope: .downloadTasks, records: store.unfinished, clearAll: true)
                }
                .disabled(store.restoring || store.unfinished.isEmpty)
                .accessibilityIdentifier("clearDownloadTasksButton")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if selection.isSelecting {
                    Button(selection.allSelected(in: visibleTokens) ? "取消全选" : "全选") {
                        selection.toggleAll(in: visibleTokens)
                    }.disabled(store.unfinished.isEmpty)
                    Button("取消") { selection.cancel() }
                } else {
                    Button("选择") { result = nil; selection.begin() }
                        .disabled(store.restoring || store.unfinished.isEmpty)
                        .accessibilityIdentifier("selectDownloadTasksButton")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selection.isSelecting {
                BatchDeletionFooter(count: selected.count, disabled: store.restoring) {
                    deletion = BatchDeletionRequest(scope: .downloadTasks, records: selected)
                }
            }
        }
        .onChange(of: visibleTokens) { _, tokens in selection.retainVisible(tokens) }
        .confirmationDialog(deletion?.title ?? "删除下载任务？", isPresented: Binding(
            get: { deletion != nil }, set: { if !$0 { deletion = nil } }
        ), titleVisibility: .visible, presenting: deletion) { snapshot in
            Button(snapshot.buttonTitle, role: .destructive) { performDeletion(snapshot) }
            Button("取消", role: .cancel) { deletion = nil }
        } message: { snapshot in Text(snapshot.message) }
    }

    private func transferDescription(_ record: DownloadRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(record.video.name).font(.headline).foregroundStyle(.primary)
            if record.state == .downloading {
                ProgressView(value: store.progress[record.id] ?? 0)
                Text("下载中 \(Int((store.progress[record.id] ?? 0) * 100))% · \(record.video.sizeLabel)")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(record.message ?? "下载失败").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }

    private func performDeletion(_ snapshot: BatchDeletionRequest) {
        deletion = nil
        let outcome = store.deleteBatch(snapshot)
        result = outcome
        selection.retainVisible(visibleTokens)
        if outcome.failures.isEmpty { selection.cancel() }
    }
}

private struct SelectionIndicator: View {
    let selected: Bool
    var body: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.title2)
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .accessibilityHidden(true)
    }
}

private struct BatchDeletionFooter: View {
    let count: Int
    let disabled: Bool
    let action: () -> Void
    var body: some View {
        HStack {
            Text("已选 \(count) 项").font(.subheadline).accessibilityIdentifier("batchSelectionCount")
            Spacer()
            Button(role: .destructive, action: action) {
                Label("删除已选（\(count)）", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(count == 0 || disabled)
            .accessibilityIdentifier("deleteSelectedItemsButton")
        }
        .padding(.horizontal).padding(.vertical, 10)
        .background(.regularMaterial)
    }
}

private struct BatchDeletionResultSection: View {
    let result: BatchDeletionResult
    var body: some View {
        Section {
            Text(result.summary).font(.footnote).accessibilityIdentifier("batchDeletionSummary")
            if result.skipped > 0 {
                Text("跳过的项目状态或下载批次已变化，或已经移除；未对其执行删除。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !result.details.isEmpty || !result.failures.isEmpty {
                DisclosureGroup("查看处理结果") {
                    ForEach(Array((result.details + result.failures).enumerated()), id: \.offset) { _, text in
                        Text(text).font(.caption).textSelection(.enabled)
                    }
                }
            }
        }
    }
}
