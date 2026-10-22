#if DEBUG
import SwiftUI
import Combine
import UIKit

// Only reachable through --ui-test-playback in a Debug build. The real player
// hierarchy receives a deterministic engine; touch handling is never replaced.
@MainActor struct PlaybackUITestFixtureView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var fixture = PlaybackUITestFixture()
    @State private var hasActivated = false

    var body: some View {
        Group {
            if !hasActivated {
                ProgressView("Starting UI test player")
            } else if let store = fixture.store, let playlist = fixture.playlist {
                PlaybackUITestPlayerView(playlist: playlist)
                    .environmentObject(store)
                    .overlay(alignment: .topLeading) {
                        PlaybackUITestDiagnosticsHost(playlist: playlist, probe: fixture.probe)
                            .allowsHitTesting(false)
                    }
            } else {
                Text(fixture.startupError ?? "UI test fixture could not start")
                    .accessibilityIdentifier("uiTestFixtureError")
            }
        }
        // The normal app opens playback after the user taps a library item in
        // an active scene. Match that lifecycle: mounting the player while the
        // app is still launching would correctly pause it as inactive.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { hasActivated = true }
        }
        .onDisappear { fixture.close() }
    }
}

@MainActor private final class PlaybackUITestFixture: ObservableObject {
    let probe = PlaybackUITestProbe()
    private(set) var store: VideoStore?
    private(set) var playlist: PlaylistPlaybackModel?
    private(set) var startupError: String?
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PlaybackUITest-" + UUID().uuidString, isDirectory: true)
    private let suite = "com.anxiong.nicevideos.uitest." + UUID().uuidString
    private var defaults: UserDefaults?
    private var closed = false

    init() {
        do {
            guard let defaults = UserDefaults(suiteName: suite) else {
                throw ClientError("Could not create isolated UI test settings")
            }
            self.defaults = defaults
            let disk = try LocalStorage(root: root)
            let server = try ServerAddress.normalize("http://127.0.0.1:8106")
            var records: [DownloadRecord] = []
            for index in 1...2 {
                let name = "uitest-\(index).mp4"
                let video = Video(name: name, size: 4, contentType: "video/mp4",
                                  url: "/api/stream/\(name)", downloadUrl: "/api/download/\(name)")
                var record = DownloadRecord(video: video, server: server)
                record.state = .complete
                record.downloadedAt = Date(timeIntervalSince1970: Double(3 - index))
                // These satisfy the offline file policy. The fake engine never
                // decodes them, and no catalog or media network request is made.
                try Data([1, 2, 3, 4]).write(to: disk.destination(for: record), options: .atomic)
                records.append(record)
            }
            try disk.saveRecords(records)
            let store = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
            store.playLocal(records[0])
            guard let request = store.playback else {
                throw ClientError(store.errorMessage ?? "Could not open UI test media")
            }
            let probe = self.probe
            let playlist = PlaylistPlaybackModel(
                request: request, store: store,
                engineFactory: { PlaybackUITestEngine(probe: probe) },
                defaults: defaults, manageAudioSession: false
            )
            self.store = store
            self.playlist = playlist
        } catch {
            startupError = error.localizedDescription
            close()
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        playlist?.close()
        defaults?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

// Main-queue confined, like LocalPlaybackEngine and the production models.
private final class PlaybackUITestProbe: ObservableObject {
    @Published var seekCount = 0
    @Published var lastSeek: Double = -1
    @Published var tickCount = 0
}

private final class PlaybackUITestEngine: LocalPlaybackEngine {
    var onUpdate: ((PlaybackSnapshot) -> Void)?
    private let probe: PlaybackUITestProbe
    private var timer: Timer?
    private var phase: PlaybackPhase = .idle
    private var seconds: Double = 12
    private var loaded = false
    private var stopped = false

    init(probe: PlaybackUITestProbe) { self.probe = probe }
    func attach(to view: UIView) {}

    func load(fileURL: URL) throws {
        try OfflineMediaPolicy.validateLocalFile(fileURL)
        loaded = true
    }

    func play() {
        guard loaded, !stopped else { return }
        phase = .playing
        publish()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, !self.stopped else { return }
            if self.phase == .playing { self.seconds = min(119, self.seconds + 0.2) }
            self.probe.tickCount += 1
            self.publish()
        }
        self.timer = timer
        // Keep publishing during touch tracking, as a real decoder does.
        RunLoop.main.add(timer, forMode: .common)
    }

    func pause() {
        guard !stopped else { return }
        phase = .paused
        publish()
    }

    func seek(to seconds: Double) {
        guard loaded, !stopped else { return }
        self.seconds = seconds
        probe.seekCount += 1
        probe.lastSeek = seconds
        publish()
    }

    private func publish() {
        onUpdate?(PlaybackSnapshot(phase: phase, seconds: seconds, duration: 120,
                                   seekable: true, hasVideo: true))
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        timer?.invalidate()
        timer = nil
        onUpdate = nil
    }

    deinit { timer?.invalidate() }
}

private struct PlaybackUITestDiagnosticsHost: View {
    @ObservedObject var playlist: PlaylistPlaybackModel
    let probe: PlaybackUITestProbe

    var body: some View {
        PlaybackUITestDiagnostics(player: playlist.player, probe: probe,
                                  currentItem: playlist.current.title)
    }
}

private struct PlaybackUITestDiagnostics: View {
    @ObservedObject var player: PlaybackModel
    @ObservedObject var probe: PlaybackUITestProbe
    let currentItem: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(String(probe.seekCount)).accessibilityIdentifier("uiTestSeekCount")
            Text(String(probe.lastSeek)).accessibilityIdentifier("uiTestLastSeek")
            Text(String(probe.tickCount)).accessibilityIdentifier("uiTestTickCount")
            Text(String(describing: player.phase)).accessibilityIdentifier("uiTestPlaybackPhase")
            Text(String(player.seconds)).accessibilityIdentifier("uiTestPlaybackSeconds")
            Text(currentItem).accessibilityIdentifier("uiTestCurrentItem")
        }
        .font(.system(size: 8, design: .monospaced))
        .foregroundStyle(.yellow)
        .padding(4)
        .background(.black.opacity(0.65))
        .allowsHitTesting(false)
    }
}
#endif
