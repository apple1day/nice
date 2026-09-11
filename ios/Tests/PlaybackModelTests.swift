import XCTest
import UIKit
@testable import NiceVideos

private final class FakeEngine: LocalPlaybackEngine {
    var onUpdate: ((PlaybackSnapshot) -> Void)?
    var loads: [URL] = []
    var seeks: [Double] = []
    var playCount = 0
    var pauseCount = 0
    var stopCount = 0
    func attach(to view: UIView) {}
    func load(fileURL: URL) throws { try OfflineMediaPolicy.validateLocalFile(fileURL); loads.append(fileURL) }
    func play() { playCount += 1 }
    func pause() { pauseCount += 1 }
    func seek(to seconds: Double) { seeks.append(seconds) }
    func stop() { stopCount += 1 }
    func emit(_ phase: PlaybackPhase, seconds: Double = 0, duration: Double = 100, seekable: Bool = true) {
        onUpdate?(PlaybackSnapshot(phase: phase, seconds: seconds, duration: duration, seekable: seekable))
    }
}

@MainActor final class PlaybackModelTests: XCTestCase {
    private func fixture(saved: Double = 0) throws -> (PlaybackModel, FakeEngine, UserDefaults) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data([1, 2, 3, 4]).write(to: path)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(saved, forKey: "position.test")
        addTeardownBlock { try? FileManager.default.removeItem(at: path); defaults.removePersistentDomain(forName: suite) }
        let engine = FakeEngine()
        let request = try PlaybackRequest(key: "test", title: "test", url: path)
        let model = PlaybackModel(request: request, engine: engine, defaults: defaults, manageAudioSession: false)
        return (model, engine, defaults)
    }
    func testViewUpdatesDoNotCreateDuplicatePlayback() throws {
        let (model, engine, _) = try fixture()
        let view = UIView()
        model.attach(to: view)
        model.attach(to: view)
        XCTAssertEqual(engine.loads.count, 1)
        XCTAssertTrue(engine.loads[0].isFileURL)
        XCTAssertEqual(engine.playCount, 1)
        model.close()
    }
    func testResumeWaitsForDurationAndSeeksOnlyOnce() throws {
        let (model, engine, _) = try fixture(saved: 25)
        model.attach(to: UIView())
        engine.emit(.opening, duration: 0, seekable: false)
        XCTAssertTrue(engine.seeks.isEmpty)
        engine.emit(.playing)
        XCTAssertEqual(engine.seeks, [25])
        engine.emit(.playing, seconds: 26)
        XCTAssertEqual(engine.seeks, [25])
        model.close()
    }
    func testClosingBeforeFirstFramePreservesBookmark() throws {
        let (model, _, defaults) = try fixture(saved: 25)
        model.attach(to: UIView())
        model.close()
        XCTAssertEqual(defaults.double(forKey: "position.test"), 25)
    }
    func testPauseAndCloseSaveProgressAndStopOnce() throws {
        let (model, engine, defaults) = try fixture()
        model.attach(to: UIView())
        engine.emit(.playing, seconds: 12)
        model.pause()
        XCTAssertEqual(engine.pauseCount, 1)
        XCTAssertEqual(defaults.double(forKey: "position.test"), 12)
        let lateEvent = engine.onUpdate
        model.close()
        model.close()
        lateEvent?(PlaybackSnapshot(phase: .playing, seconds: 99, duration: 100, seekable: true))
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(defaults.double(forKey: "position.test"), 12)
    }
    func testEndClearsBookmarkAndReplayDoesNotRestoreIt() throws {
        let (model, engine, defaults) = try fixture(saved: 25)
        model.attach(to: UIView())
        engine.emit(.playing)
        engine.emit(.ended, seconds: 100)
        XCTAssertNil(defaults.object(forKey: "position.test"))
        model.toggle()
        engine.emit(.playing, seconds: 0)
        XCTAssertEqual(engine.seeks, [25])
        XCTAssertEqual(engine.playCount, 2)
        model.close()
    }
    func testSeekIgnoresNaNAndClampsRange() throws {
        let (model, engine, _) = try fixture()
        model.attach(to: UIView())
        engine.emit(.playing)
        model.seek(to: .nan)
        XCTAssertTrue(engine.seeks.isEmpty)
        model.seek(to: -20)
        model.seek(to: 200)
        XCTAssertEqual(engine.seeks, [0, 99.9])
        model.close()
    }
}
