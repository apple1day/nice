import Foundation
import Combine

// One active engine. Metadata is cached in memory; displaying controls, seeking,
// and checking button availability must never validate the whole media library.
final class PlaylistPlaybackModel: ObservableObject {
    @Published private(set) var current: PlaybackRequest
    @Published private(set) var player: PlaybackModel
    @Published private(set) var notice: String?
    @Published private(set) var entries: [DownloadRecord] = []
    @Published private(set) var positionLabel = "本地播放列表"
    @Published private(set) var currentEntry: DownloadRecord?
    private var playlist: LocalPlaybackPlaylist
    private let store: VideoStore
    private let engineFactory: () -> LocalPlaybackEngine
    private let defaults: UserDefaults
    private let manageAudioSession: Bool
    private let resolveRequest: (String) throws -> PlaybackRequest
    private var recordSubscription: AnyCancellable?
    private var recordsByID: [String: DownloadRecord] = [:]
    private var positionsByID: [String: Int] = [:]
    private var availableIDs: Set<String> = []
    private var neighbors: [LocalPlaybackPlaylist.Direction: DownloadRecord] = [:]
    private var switching = false
    private var closed = false

    init(request: PlaybackRequest, store: VideoStore,
         engineFactory: @escaping () -> LocalPlaybackEngine = { VLCPlaybackEngine() },
         defaults: UserDefaults = .standard, manageAudioSession: Bool = true,
         requestResolver: ((String) throws -> PlaybackRequest)? = nil) {
        self.store = store
        self.engineFactory = engineFactory
        self.defaults = defaults
        self.manageAudioSession = manageAudioSession
        resolveRequest = requestResolver ?? { try store.localPlaybackRequest(for: $0) }
        current = request
        // Completed is an in-memory manifest query, NOT localPlaylistRecords
        // (which performs filesystem checks). Only the selected target is opened.
        playlist = LocalPlaybackPlaylist(ids: store.completed.map(\.id), currentID: request.key)
        player = PlaybackModel(request: request, engine: engineFactory(), defaults: defaults,
                               manageAudioSession: manageAudioSession)
        recordSubscription = store.$records.removeDuplicates().sink { [weak self] records in
            // @Published emits before store.records is assigned. Use the emitted
            // value, not store.records, so stars/deletions cannot lag one update.
            self?.updateMetadata(records)
        }
    }

    private func updateMetadata(_ records: [DownloadRecord]) {
        guard !closed else { return }
        let completed = Dictionary(uniqueKeysWithValues: records.filter { $0.state == .complete }.map { ($0.id, $0) })
        let next = playlist.ids.compactMap { completed[$0] }
        recordsByID = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })
        positionsByID = Dictionary(uniqueKeysWithValues: next.enumerated().map { ($0.element.id, $0.offset) })
        availableIDs = Set(recordsByID.keys)
        if entries != next { entries = next }
        updateCurrentMetadata()
    }

    private func updateCurrentMetadata() {
        let entry = recordsByID[current.key]
        if currentEntry != entry { currentEntry = entry }
        let label = positionsByID[current.key].map { "\($0 + 1) / \(entries.count)" } ?? "本地播放列表"
        if positionLabel != label { positionLabel = label }
        neighbors.removeAll(keepingCapacity: true)
        for direction in [LocalPlaybackPlaylist.Direction.previous, .next] {
            if let id = playlist.candidates(direction, available: availableIDs).first {
                neighbors[direction] = recordsByID[id]
            }
        }
    }

    // Constant-time, in-memory lookups, including for a missing current anchor.
    // Existence is intentionally checked only after an explicit navigation action.
    func neighbor(_ direction: LocalPlaybackPlaylist.Direction) -> DownloadRecord? {
        neighbors[direction]
    }
    func canMove(_ direction: LocalPlaybackPlaylist.Direction) -> Bool {
        !closed && !switching && neighbors[direction] != nil
    }

    @discardableResult func move(_ direction: LocalPlaybackPlaylist.Direction) -> Bool {
        guard !closed, !switching else { return false }
        let candidates = playlist.candidates(direction, available: availableIDs)
        guard !candidates.isEmpty else {
            notice = direction == .previous ? "已经是第一个本地视频" : "已经是最后一个本地视频"
            return false
        }
        // Resolve candidates in order and stop as soon as a playable target is
        // found. Missing/corrupt neighbors are skipped; unrelated files are not read.
        for id in candidates {
            guard let next = try? resolveRequest(id) else { continue }
            return transition(to: next)
        }
        notice = "这个方向的视频文件已缺失或无效，当前视频继续播放。"
        return false
    }

    @discardableResult func select(_ id: String) -> Bool {
        guard !closed, !switching, playlist.ids.contains(id) else { return false }
        if id == current.key { return true }
        do { return transition(to: try resolveRequest(id)) }
        catch { notice = "无法切换：\(error.localizedDescription)"; return false }
    }

    private func transition(to next: PlaybackRequest) -> Bool {
        switching = true
        defer { switching = false }
        do {
            // Keep the store's target-only revalidation and playback lease. Never
            // trade file/deletion safety for speed, or stop the current player first.
            try store.transitionPlayback(from: current, to: next) { player.close() }
            let nextPlayer = PlaybackModel(request: next, engine: engineFactory(), defaults: defaults,
                                           manageAudioSession: manageAudioSession)
            playlist.select(next.key)
            current = next
            player = nextPlayer
            updateCurrentMetadata()
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
        recordSubscription?.cancel()
        recordSubscription = nil
        player.close()
        store.playbackDidClose(current)
    }
}
