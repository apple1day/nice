import Foundation
import Combine

// Owns ONE active PlaybackModel. The fullScreenCover's original item stays
// unchanged; only this model's current clip/drawable changes between swipes.
// All operations run on the main queue, like VideoStore and PlaybackModel.
final class PlaylistPlaybackModel: ObservableObject {
    @Published private(set) var current: PlaybackRequest
    @Published private(set) var player: PlaybackModel
    @Published private(set) var notice: String?
    private var playlist: LocalPlaybackPlaylist
    private let store: VideoStore
    private let engineFactory: () -> LocalPlaybackEngine
    private let defaults: UserDefaults
    private let manageAudioSession: Bool
    private var switching = false
    private var closed = false

    init(request: PlaybackRequest, store: VideoStore,
         engineFactory: @escaping () -> LocalPlaybackEngine = { VLCPlaybackEngine() },
         defaults: UserDefaults = .standard, manageAudioSession: Bool = true) {
        self.store = store
        self.engineFactory = engineFactory
        self.defaults = defaults
        self.manageAudioSession = manageAudioSession
        current = request
        playlist = LocalPlaybackPlaylist(ids: store.localPlaylistRecords.map(\.id), currentID: request.key)
        player = PlaybackModel(request: request, engine: engineFactory(), defaults: defaults,
                               manageAudioSession: manageAudioSession)
    }

    var entries: [DownloadRecord] {
        let available = Dictionary(uniqueKeysWithValues: store.completed.map { ($0.id, $0) })
        return playlist.ids.compactMap { available[$0] }
    }
    var positionLabel: String {
        let ids = entries.map(\.id)
        guard let index = ids.firstIndex(of: current.key) else { return "本地播放列表" }
        return "\(index + 1) / \(ids.count)"
    }

    // A gesture resolves once onEnded. Validate the next local file BEFORE
    // closing the current engine; boundaries/errors must not interrupt playback.
    @discardableResult func move(_ direction: LocalPlaybackPlaylist.Direction) -> Bool {
        guard !closed, !switching else { return false }
        let available = Set(store.localPlaylistRecords.map(\.id))
        let candidates = playlist.candidates(direction, available: available)
        guard !candidates.isEmpty else {
            notice = direction == .previous ? "已经是第一个本地视频" : "已经是最后一个本地视频"
            return false
        }
        for id in candidates {
            guard let next = try? store.localPlaybackRequest(for: id) else { continue }
            return transition(to: next)
        }
        notice = "这个方向的视频文件已缺失或无效，当前视频继续播放。"
        return false
    }

    @discardableResult func select(_ id: String) -> Bool {
        guard !closed, !switching, playlist.ids.contains(id) else { return false }
        if id == current.key { return true }
        do { return transition(to: try store.localPlaybackRequest(for: id)) }
        catch { notice = "无法切换：\(error.localizedDescription)"; return false }
    }

    private func transition(to next: PlaybackRequest) -> Bool {
        switching = true
        defer { switching = false }
        do {
            // Stop output + persist the OLD bookmark, then transfer the deletion
            // lease. Never present another cover or leave two engines running.
            try store.transitionPlayback(from: current, to: next) { player.close() }
            let nextPlayer = PlaybackModel(request: next, engine: engineFactory(), defaults: defaults,
                                           manageAudioSession: manageAudioSession)
            playlist.select(next.key)
            current = next
            player = nextPlayer
            notice = nil
            return true
        } catch {
            notice = "无法切换：\(error.localizedDescription)"
            return false
        }
    }

    func clearNotice() { notice = nil }
    func close() {
        guard !closed else { return }
        closed = true
        player.close()
        store.playbackDidClose(current)
    }
}
