import UIKit
import XCTest
@testable import NiceVideos

@MainActor
final class PickedFilePlaybackTests: XCTestCase {
    /// The two fixture resources contain only the populated regions of an MP4.
    /// Its faststart movie header indexes A/V samples using 64-bit chunk offsets.
    private func makeLargeMovie(at url: URL) throws {
        let bundle = Bundle(for: Self.self)
        let index = try XCTUnwrap(bundle.url(forResource: "co64-index", withExtension: "bin",
                                             subdirectory: "Fixtures"))
        let samples = try XCTUnwrap(bundle.url(forResource: "co64-samples", withExtension: "bin",
                                               subdirectory: "Fixtures"))
        try Data(contentsOf: index).write(to: url)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(1) << 32)
        try file.write(contentsOf: Data(contentsOf: samples))
    }

    func testUnsupportedSystemContainerFallsBackToVLCOnOriginalOpenFile() async throws {
        // The MP4 extension selects AVPlayer. Its contents are non-WebM
        // Matroska (MPEG-4 Part 2 / AAC), already decoded in our VLC tests.
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "offline", withExtension: "mkv",
                                                               subdirectory: "Fixtures"))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        try FileManager.default.copyItem(at: fixture, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try await PickedVideoFile.open(url)
        try Data("replacement at the same URL".utf8).write(to: url, options: .atomic)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let controller = UIViewController()
        window.rootViewController = controller
        let host = SBSPlaybackView(frame: window.bounds)
        controller.view.addSubview(host)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        let engine = SBSPlaybackEngine(pickedFile: file)
        defer { engine.stop(); window.isHidden = true }
        var errors: [String] = []
        var firstVideoTime: Double?
        var advanced = false
        let playing = expectation(description: "VLC recovers the original movie and advances with video")
        engine.onUpdate = { state in
            if state.phase == .failed { errors.append(state.error ?? "unspecified failure") }
            guard state.videoOutput == .vlcNative, state.phase == .playing, state.hasVideo else { return }
            if let firstVideoTime {
                if !advanced && state.seconds > firstVideoTime + 0.1 {
                    advanced = true
                    playing.fulfill()
                }
            } else {
                firstVideoTime = state.seconds
            }
        }
        engine.attach(to: host)
        XCTAssertEqual(engine.currentOutput, .system)
        try engine.load(fileURL: url)
        engine.play()
        await fulfillment(of: [playing], timeout: 15)
        XCTAssertEqual(engine.currentOutput, .vlcNative)
        XCTAssertTrue(errors.isEmpty, "System failure escaped before fallback: \(errors)")
    }

    func testPickedMovieBeyond4GiBPlaysAndSeeksAfterItsProviderReplacesThePath() async throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: folder) }
        let url = folder.appendingPathComponent("电影 #1.mp4")
        try makeLargeMovie(at: url)

        let disk = try LocalStorage(root: folder.appendingPathComponent("Library"))
        let server = try ServerAddress.normalize("http://127.0.0.1:9")
        let video = Video(name: url.lastPathComponent, size: 4, contentType: "video/mp4",
                          url: "/unused", downloadUrl: "/unused")
        var record = DownloadRecord(video: video, server: server)
        record.state = .complete
        record.downloadedAt = Date()
        let libraryFile = try disk.destination(for: record)
        try Data([1, 2, 3, 4]).write(to: libraryFile)
        try disk.saveRecords([record])
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        let initialRecords = store.records

        let source = try await PickedVideoFile.open(url)
        XCTAssertGreaterThan(source.byteCount, UInt64(UInt32.max))
        // A Files provider can update metadata and reuse its presentation URL
        // after coordinated opening. Only the descriptor still names our movie.
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_234_567_890)],
                             ofItemAtPath: url.path)
        let replacement = Data("Different document at the same Files URL".utf8)
        try replacement.write(to: url, options: .atomic)
        try store.playPickedFile(source)
        let request = try XCTUnwrap(store.playback)
        XCTAssertTrue(request.pickedFile === source)
        let engine = SBSPlaybackEngine(pickedFile: request.pickedFile)
        let model = PlaylistPlaybackModel(request: request, store: store, engineFactory: { engine },
                                          defaults: defaults, manageAudioSession: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        let controller = UIViewController()
        window.rootViewController = controller
        let host = SBSPlaybackView(frame: window.bounds)
        controller.view.addSubview(host)
        window.makeKeyAndVisible()
        defer { model.close(); window.isHidden = true }

        let receive = try XCTUnwrap(engine.onUpdate)
        let ordinaryFrame = XCTestExpectation(description: "Flat view plays samples beyond 4 GiB")
        let sought = XCTestExpectation(description: "Playback clock advances past the requested time")
        let vrFrame = XCTestExpectation(description: "System decoder delivers a stereo frame after switching to VR")
        var sawOrdinaryFrame = false
        var seekRequested = false
        var passedSeek = false
        var sawVRFrame = false
        var latest = PlaybackSnapshot(phase: .idle)
        var transitions: [String] = []
        var previousState = ""
        engine.onUpdate = { state in
            receive(state)
            latest = state
            let flags = "\(host.mode) \(state.phase) seekable=\(state.seekable) video=\(state.hasVideo) duration=\(state.duration)"
            if flags != previousState {
                transitions.append("\(flags) at \(state.seconds)")
                previousState = flags
            }
            guard state.phase == .playing, state.hasVideo else { return }
            if host.mode == .standard {
                if !sawOrdinaryFrame && state.seekable && state.duration >= 10 && state.seconds > 0 {
                    sawOrdinaryFrame = true
                    ordinaryFrame.fulfill()
                }
                if seekRequested && !passedSeek && state.seconds >= 5.4 {
                    passedSeek = true
                    sought.fulfill()
                }
            } else if host.mode == .half && state.videoOutput == .system && !sawVRFrame {
                sawVRFrame = true
                vrFrame.fulfill()
            }
        }
        func diagnostic() -> String {
            "Latest snapshot \(latest), player message \(model.player.message ?? "none"), transitions \(transitions)"
        }
        model.player.attach(to: host)
        await fulfillment(of: [ordinaryFrame], timeout: 15)
        guard sawOrdinaryFrame else { XCTFail(diagnostic()); return }
        seekRequested = true
        model.player.seek(to: 5)
        await fulfillment(of: [sought], timeout: 8)
        guard passedSeek else { XCTFail(diagnostic()); return }
        XCTAssertEqual(engine.currentOutput, .system, diagnostic())
        XCTAssertNil(host.renderer)
        host.mode = .half
        XCTAssertNotNil(host.renderer)
        await fulfillment(of: [vrFrame], timeout: 15)
        XCTAssertTrue(sawVRFrame, diagnostic())
        XCTAssertFalse(model.canMove(.next))
        XCTAssertFalse(model.markCurrentForDeletion(expectedRequestID: request.id))
        model.close()

        XCTAssertNil(store.playback)
        XCTAssertEqual(store.records, initialRecords)
        XCTAssertEqual(try disk.loadRecords(), initialRecords)
        XCTAssertEqual(try Data(contentsOf: libraryFile), Data([1, 2, 3, 4]))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: libraryFile.deletingLastPathComponent().path),
                       [libraryFile.lastPathComponent])
        XCTAssertEqual(try Data(contentsOf: url), replacement)
    }
}
