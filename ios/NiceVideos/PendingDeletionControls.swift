import SwiftUI

// Reusable pending-delete control. Marking only adds the video to the persisted
// pending list; it never deletes a file. Actual deletion is list-page only.
struct WatchDeleteButton: View {
    @EnvironmentObject private var store: VideoStore
    let videoID: String
    var compact = false
    var onInteraction: () -> Void = {}
    private var queued: Bool { store.isPendingDeletion(videoID) }
    var body: some View {
        Group {
            if compact {
                HStack(spacing: 12) {
                    markButton
                    Text("待删除 \(store.pendingDeletionRecords.count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.white)
                    if queued { undoButton }
                }
            } else {
                VStack(spacing: 8) {
                    markButton
                    Text("待删除 \(store.pendingDeletionRecords.count) 个")
                        .font(.caption.monospacedDigit()).foregroundStyle(.white)
                    if queued {
                        undoButton
                    } else {
                        Text("只加入待删除列表，不会自动删除")
                            .font(.caption2).foregroundStyle(.white)
                    }
                }
            }
        }
        .padding(compact ? 8 : 12)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
    }
    private var markButton: some View {
        Button {
            onInteraction()
            if !queued { store.markForDeletion(videoID) }
        } label: {
            Label(queued ? "已待删除" : "删除", systemImage: queued ? "checkmark.circle" : "trash")
                .font(.headline).padding(.horizontal, 8).padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent).tint(.orange)
        .disabled(queued)
        .accessibilityLabel(queued ? "当前视频已加入待删除列表" : "将当前视频加入待删除列表")
        .accessibilityIdentifier("watchDeleteButton")
    }
    private var undoButton: some View {
        Button("撤销待删除") { onInteraction(); store.unmarkForDeletion(videoID) }
            .buttonStyle(.bordered).tint(.white)
            .accessibilityIdentifier("undoWatchDeleteButton")
    }
}

// Shared by list pages. This section is intentionally the only place that
// performs the queued file deletions, after an explicit confirmation.
struct PendingDeletionSection: View {
    @EnvironmentObject private var store: VideoStore
    @State private var expanded = false
    @State private var confirmDelete = false
    @State private var confirmedIDs: [String] = []
    var body: some View {
        Section {
            Text("播放器中的“删除”只把视频加入待删除列表，没有数量上限，也不会自动删除。需要在这里点击一键删除后才会真正删除手机文件。")
                .font(.footnote).foregroundStyle(.secondary)
            if !store.pendingDeletionRecords.isEmpty {
                DisclosureGroup("查看待删除视频", isExpanded: $expanded) {
                    ForEach(store.pendingDeletionRecords) { record in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.video.name).lineLimit(2)
                                Text(record.video.sizeLabel).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("撤销") { store.unmarkForDeletion(record.id) }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("撤销待删除：\(record.video.name)")
                        }.padding(.vertical, 4)
                    }
                }
            }
            Button(role: .destructive) {
                confirmedIDs = store.pendingDeletionRecords.map(\.id)
                confirmDelete = true
            } label: {
                Label("一键删除待删除视频（\(store.pendingDeletionRecords.count)）", systemImage: "trash")
            }
            .disabled(store.pendingDeletionRecords.isEmpty)
            .accessibilityIdentifier("deleteAllPendingVideosButton")
            .confirmationDialog("删除这 \(confirmedIDs.count) 个待删除视频？", isPresented: $confirmDelete,
                                titleVisibility: .visible) {
                Button("确认删除手机副本", role: .destructive) {
                    store.deleteAllPendingVideos(ids: confirmedIDs)
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只删除本次确认时已经加入待删除列表的手机视频，不会删除服务器文件，也不会删除其他未标记的视频。正在播放的项目会保留并提示稍后重试。")
            }
            if let notice = store.deletionNotice {
                Text(notice).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("pendingDeletionNotice")
            }
        } header: {
            Text("待删除 · \(store.pendingDeletionRecords.count)")
        }
    }
}
