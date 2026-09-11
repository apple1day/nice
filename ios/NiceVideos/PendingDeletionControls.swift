import SwiftUI

// A small, explicit control at the center of the video. Marking does not stop
// playback or delete this file immediately. Repeated taps cannot move its order.
struct WatchDeleteButton: View {
    @EnvironmentObject private var store: VideoStore
    let videoID: String
    private var queued: Bool { store.isPendingDeletion(videoID) }
    var body: some View {
        VStack(spacing: 8) {
            Button { store.markForDeletion(videoID) } label: {
                Label(queued ? "已待删除" : "删除", systemImage: queued ? "checkmark.circle" : "trash")
                    .font(.headline).padding(.horizontal, 8).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent).tint(.orange)
            .disabled(queued)
            .accessibilityLabel(queued ? "当前视频已加入待删除" : "将当前视频加入待删除队列")
            .accessibilityIdentifier("watchDeleteButton")
            Text("待删除 \(store.pendingDeletionRecords.count)/\(VideoStore.deletionQueueLimit)")
                .font(.caption.monospacedDigit()).foregroundStyle(.white)
            if queued {
                Button("撤销待删除") { store.unmarkForDeletion(videoID) }
                    .buttonStyle(.bordered).tint(.white)
                    .accessibilityIdentifier("undoWatchDeleteButton")
            } else {
                Text(store.pendingDeletionRecords.count >= VideoStore.deletionQueueLimit
                     ? "加入后自动删除最早的一个" : "先加入队列，不立即删除")
                    .font(.caption2).foregroundStyle(.white)
            }
        }
        .padding(12)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
    }
}

// Shared by the local and server lists; it always refers to the entire device's
// queue, not the current search filter or only the currently configured server.
struct PendingDeletionSection: View {
    @EnvironmentObject private var store: VideoStore
    @State private var expanded = false
    @State private var confirmDelete = false
    @State private var confirmedIDs: [String] = []
    var body: some View {
        Section {
            Text("保留最近 \(VideoStore.deletionQueueLimit) 个待删除视频；加入第 \(VideoStore.deletionQueueLimit + 1) 个时自动删除最早的手机副本。")
                .font(.footnote).foregroundStyle(.secondary)
            if !store.pendingDeletionRecords.isEmpty {
                DisclosureGroup("查看待删除视频（最早的在前）", isExpanded: $expanded) {
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
                Label("一键删除所有待删除视频（\(store.pendingDeletionRecords.count)）", systemImage: "trash")
            }
            .disabled(store.pendingDeletionRecords.isEmpty)
            .accessibilityIdentifier("deleteAllPendingVideosButton")
            .confirmationDialog("删除这 \(confirmedIDs.count) 个待删除视频？", isPresented: $confirmDelete,
                                titleVisibility: .visible) {
                Button("删除手机副本", role: .destructive) {
                    store.deleteAllPendingVideos(ids: confirmedIDs)
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("仅删除此手机待删除队列中的视频，包含不同服务器的本地副本，不受搜索条件影响。不会删除服务器文件，也不会删除其他未标记的视频。")
            }
            if let notice = store.deletionNotice {
                Text(notice).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("pendingDeletionNotice")
            }
        } header: {
            Text("待删除 · \(store.pendingDeletionRecords.count)/\(VideoStore.deletionQueueLimit)")
        }
    }
}
