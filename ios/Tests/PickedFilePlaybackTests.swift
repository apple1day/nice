import UIKit
import XCTest
@testable import NiceVideos

@MainActor
final class PickedFilePlaybackTests: XCTestCase {
    /// Insert a 64-bit ISO BMFF free box after ftyp. Only the tiny fixture's
    /// bytes are written. All decoder metadata and samples begin past 4 GiB.
    private func makeLargeMovie(at url: URL) throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "fragmented", withExtension: "mp4", subdirectory: "Fixtures"))
        let sample = try Data(contentsOf: fixture)
        guard sample.count >= 8, sample[4..<8] == Data("ftyp".utf8) else {
            throw ClientError("Missing ftyp in the generated test fixture")
        }
        let ftypSize = sample.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard (8..<sample.count).contains(ftypSize) else {
            throw ClientError("Invalid ftyp length in the generated test fixture")
        }

        let padding: UInt64 = 1 << 32
        var freeBox = Data([0, 0, 0, 1]) + Data("free".utf8)
        withUnsafeBytes(of: padding.bigEndian) { freeBox.append(contentsOf: $0) }
        try sample.prefix(ftypSize).write(to: url)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(ftypSize))
        try file.write(contentsOf: freeBox)
        try file.seek(toOffset: UInt64(ftypSize) + padding)
        try file.write(contentsOf: sample.dropFirst(ftypSize))
    }

    func testPickedMovieBeyond4GiBPlaysThroughNormalAndVRDecoderWithoutChangingLibrary() async throws {
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
        let ordinaryFrame = expectation(description: "Native drawable plays samples beyond 4 GiB")
        let vrFrame = expectation(description: "Reopened VR decoder delivers a frame from the same file")
        var sawOrdinaryFrame = false
        var sawVRFrame = false
        engine.onUpdate = { state in
            receive(state)
            guard state.phase == .playing, state.hasVideo, state.seekable, state.seconds > 0 else { return }
            if host.mode == .standard && !sawOrdinaryFrame {
                sawOrdinaryFrame = true
                ordinaryFrame.fulfill()
            } else if host.mode == .half && !sawVRFrame {
                sawVRFrame = true
                vrFrame.fulfill()
            }
        }
        model.player.attach(to: host)
        await fulfillment(of: [ordinaryFrame], timeout: 15)
        host.mode = .half
        await fulfillment(of: [vrFrame], timeout: 15)
        XCTAssertTrue(sawOrdinaryFrame && sawVRFrame)
        XCTAssertFalse(model.canMove(.next))
        XCTAssertFalse(model.markCurrentForDeletion(expectedRequestID: request.id))
        model.close()

        XCTAssertNil(store.playback)
        XCTAssertEqual(store.records, initialRecords)
        XCTAssertEqual(try disk.loadRecords(), initialRecords)
        XCTAssertEqual(try Data(contentsOf: libraryFile), Data([1, 2, 3, 4]))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: libraryFile.deletingLastPathComponent().path),
                       [libraryFile.lastPathComponent])
        XCTAssertEqual(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int(source.byteCount))
    }
}
