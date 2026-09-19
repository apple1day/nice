import SwiftUI

// Only this tiny adapter observes the broad store. The actual list observes its
// metadata-only model, not download progress or playback presentation changes.
struct OfflineView: View {
    @EnvironmentObject private var store: VideoStore
    var body: some View { OfflineLibraryContent(store: store) }
}

private struct OfflineLibraryContent: View {
    let store: VideoStore
    @StateObject private var library: LocalLibraryModel
    @State private var search = ""
    @State private var selection = BatchSelection()
    @State private var deletion: BatchDeletionRequest?
    @State private var result: BatchDeletionResult?

    init(store: VideoStore) {
        self.store = store
        _library = StateObject(wrappedValue: LocalLibraryModel(store: store))
    }
    private var selected: [DownloadRecord] {
        library.visibleRows.map(\.record).filter { selection.contains($0.taskToken) }
    }
    var body: some View {
        List {
            Section {
                HStack {
                    Text(library.summary)
                    Spacer(minLength: 8)
                    if !library.pendingRecords.isEmpty {
                        Text("待删除 \(library.pendingRecords.count)").foregroundStyle(.orange)
                    }
                }.font(.footnote)
                if selection.isSelecting {
                    Text("全选仅针对当前搜索结果。").font(.caption).foregroundStyle(.secondary)
                }
                if let notice = library.notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let result = result { BatchDeletionResultSection(result: result) }
            ForEach(library.visibleRows) { row in
                Button {
                    if selection.isSelecting { selection.toggle(row.record.taskToken) }
                    else { store.playLocal(row.record) }
                } label: {
                    LocalVideoRowLabel(row: row, selecting: selection.isSelecting,
                                       selected: selection.contains(row.record.taskToken)).equatable()
                }
                .buttonStyle(.plain)
                .accessibilityValue(selection.isSelecting
                    ? (selection.contains(row.record.taskToken) ? "已选择" : "未选择")
                    : (row.record.hasWatched ? "已观看，本地播放" : "未观看，本地播放"))
                .accessibilityIdentifier("localVideoRow.\(row.id)")
                .swipeActions(allowsFullSwipe: false) {
                    if !selection.isSelecting {
                        Button("删除", role: .destructive) {
                            deletion = BatchDeletionRequest(scope: .localVideos, records: [row.record])
                        }.disabled(library.restoring)
                    }
                }
                .contextMenu {
                    if !selection.isSelecting && row.record.pendingDeletionOrder != nil {
                        Button("撤销待删除") { store.unmarkForDeletion(row.id) }
                    }
                }
            }
            if library.visibleRows.isEmpty {
                ContentUnavailableView(search.isEmpty ? "暂无本地视频" : "没有匹配的视频", systemImage: "internaldrive",
                    description: Text("在「服务器」下载视频后即可离线播放。"))
            }
        }
        .navigationTitle("本地视频")
        .searchable(text: $search, prompt: "搜索本地视频")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                PendingDeleteToolbarButton(records: library.pendingRecords, disabled: library.restoring) { snapshot in
                    store.deletePendingVideos(snapshot)
                    selection.retainVisible(library.visibleTokens)
                }
                if selection.isSelecting {
                    Button(selection.allSelected(in: library.visibleTokens) ? "取消全选" : "全选") {
                        selection.toggleAll(in: library.visibleTokens)
                    }.disabled(library.visibleRows.isEmpty)
                    Button("取消") { selection.cancel() }
                } else {
                    Button("选择") { result = nil; selection.begin() }
                        .disabled(library.visibleRows.isEmpty || library.restoring)
                        .accessibilityIdentifier("selectLocalVideosButton")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selection.isSelecting {
                BatchDeletionFooter(count: selection.tokens.count, disabled: library.restoring) {
                    deletion = BatchDeletionRequest(scope: .localVideos, records: selected)
                }
            }
        }
        .onChange(of: search) { _, value in library.setSearch(value) }
        .onChange(of: library.visibleTokens) { _, tokens in selection.retainVisible(tokens) }
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
        selection.retainVisible(library.visibleTokens)
        if outcome.failures.isEmpty { selection.cancel() }
    }
}

private struct LocalVideoRowLabel: View, Equatable {
    let row: LocalLibraryRow
    let selecting: Bool
    let selected: Bool
    var body: some View {
        HStack(spacing: 12) {
            if selecting { SelectionIndicator(selected: selected) }
            else { Image(systemName: "play.circle.fill").font(.title) }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(row.record.video.name).foregroundStyle(.primary).lineLimit(2)
                    if row.record.isFavorite {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                            .accessibilityLabel("已收藏").accessibilityIdentifier("favoriteBadge.\(row.id)")
                    }
                }
                Text(row.subtitle).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Label(row.record.hasWatched ? "已观看" : "未观看",
                          systemImage: row.record.hasWatched ? "eye.fill" : "eye")
                        .foregroundStyle(row.record.hasWatched ? Color.secondary : Color.accentColor)
                        .accessibilityIdentifier("watchedBadge.\(row.id)")
                    if row.record.pendingDeletionOrder != nil {
                        Label("待删除", systemImage: "trash").foregroundStyle(.orange)
                    }
                }.font(.caption)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 4).contentShape(Rectangle())
    }
}

private struct PendingDeleteToolbarButton: View {
    let records: [DownloadRecord]
    let disabled: Bool
    let action: ([DownloadRecord]) -> Void
    @State private var confirmed: [DownloadRecord] = []
    @State private var showConfirmation = false
    var body: some View {
        Button("删除待删除", role: .destructive) {
            confirmed = records
            showConfirmation = true
        }
        .disabled(disabled || records.isEmpty)
        .accessibilityIdentifier("deleteAllPendingVideosButton")
        .confirmationDialog("删除这 \(confirmed.count) 个待删除视频？", isPresented: $showConfirmation,
                            titleVisibility: .visible) {
            Button("确认删除手机副本", role: .destructive) {
                action(confirmed)
                confirmed = []
            }
            Button("取消", role: .cancel) { confirmed = [] }
        } message: {
            Text("删除本次确认时的待删除手机副本，不受搜索条件影响。不会删除服务器文件；正在播放、已撤销标记或重新下载的项目会保留。")
        }
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
