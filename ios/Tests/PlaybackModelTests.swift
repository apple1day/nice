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

@MainActor private final class PlaybackModelScrubObserver: PlaybackScrubObserver {
    let model: PlaybackModel
    init(model: PlaybackModel) { self.model = model }
    func draftChanged(_ seconds: Double?) {}
    func editingChanged(_ editing: Bool) { model.setScrubbing(editing) }
    func commit(_ seconds: Double) { model.seek(to: seconds) }
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
        XCTAssertEqual(engine.loads.count, 2, "Replay must replace the finished native input")
        XCTAssertEqual(engine.loads[0], engine.loads[1])
        model.close()
    }
    private func finishQueuedCallbacks() async {
        let drained = expectation(description: "queued playback completion processed")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }
    func testEndCallbackRunsOnceAfterTerminalStateAndBookmarkAreUpdated() async throws {
        let (model, engine, defaults) = try fixture(saved: 25)
        var completions = 0
        model.onPlaybackEnded = {
            completions += 1
            XCTAssertEqual(model.phase, .ended)
            XCTAssertEqual(model.seconds, 100)
            XCTAssertNil(defaults.object(forKey: "position.test"))
        }
        model.attach(to: UIView())
        engine.emit(.playing)
        engine.emit(.ended, seconds: 100)
        engine.emit(.ended, seconds: 100)
        XCTAssertEqual(completions, 0, "Completion must run after the engine callback returns")
        await finishQueuedCallbacks()
        XCTAssertEqual(completions, 1)
        engine.emit(.ended, seconds: 100)
        await finishQueuedCallbacks()
        XCTAssertEqual(completions, 1)
        model.close()
    }
    func testReplayCancelsQueuedCompletionAndCanFinishAgain() async throws {
        let (model, engine, _) = try fixture()
        var completions = 0
        model.onPlaybackEnded = { completions += 1 }
        model.attach(to: UIView())
        engine.emit(.playing)
        engine.emit(.ended, seconds: 100)
        model.toggle()
        engine.emit(.ended, seconds: 100)
        await finishQueuedCallbacks()
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(model.phase, .opening)
        XCTAssertEqual(engine.playCount, 2)

        engine.emit(.playing)
        engine.emit(.ended, seconds: 100)
        await finishQueuedCallbacks()
        XCTAssertEqual(completions, 1)
        model.close()
    }
    func testSeekCancelsQueuedCompletion() async throws {
        let (model, engine, _) = try fixture()
        var completions = 0
        model.onPlaybackEnded = { completions += 1 }
        model.attach(to: UIView())
        engine.emit(.ended, seconds: 100)
        model.seek(to: 20)
        await finishQueuedCallbacks()
        XCTAssertEqual(completions, 0)
        XCTAssertTrue(engine.seeks.isEmpty, "Stopped input must restart before seeking")
        XCTAssertEqual(engine.playCount, 2)
        engine.emit(.playing, seconds: 0)
        XCTAssertEqual(engine.seeks, [20])
        engine.emit(.ended, seconds: 100)
        await finishQueuedCallbacks()
        XCTAssertEqual(completions, 1, "Seeking back into a finished clip starts a new playback cycle")
        model.close()
    }
    private func scrubFixture(model: PlaybackModel)
        -> (PlaybackScrubController, PlaybackTrackingSlider, PlaybackModelScrubObserver) {
        let controller = PlaybackScrubController()
        let slider = PlaybackTrackingSlider(frame: CGRect(x: 0, y: 0, width: 300, height: 44))
        slider.maximumValue = 100
        slider.value = 20
        let observer = PlaybackModelScrubObserver(model: model)
        controller.bind(slider, observer: observer)
        return (controller, slider, observer)
    }
    func testHeldScrubDefersEOFAndTouchUpSeekRestartsCurrentClip() async throws {
        let (model, engine, defaults) = try fixture()
        var completions = 0
        model.onPlaybackEnded = { completions += 1 }
        model.attach(to: UIView())
        engine.emit(.playing, seconds: 90)
        let (controller, slider, observer) = scrubFixture(model: model)
        XCTAssertTrue(slider.beginScrubbing())
        engine.emit(.ended, seconds: 100, duration: 0, seekable: false)
        await finishQueuedCallbacks()
        XCTAssertEqual(completions, 0)
        XCTAssertTrue(controller.isEditing(in: slider))
        XCTAssertTrue(model.seekable, "EOF must not disable and cancel the held native slider")
        XCTAssertEqual(model.duration, 100)

        // Exercise the production controller's editing=false BEFORE commit order.
        slider.finishScrubbing()
        await finishQueuedCallbacks()
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(engine.playCount, 2)
        XCTAssertEqual(engine.loads.count, 2)
        XCTAssertEqual(engine.loads[0], engine.loads[1], "EOF recovery reloads only the current file")
        XCTAssertTrue(engine.seeks.isEmpty)
        XCTAssertEqual(model.phase, .opening)
        engine.emit(.paused, seconds: 0, duration: 0, seekable: false)
        XCTAssertTrue(engine.seeks.isEmpty, "Preserved UI seekability is not native input readiness")
        engine.emit(.playing, seconds: 0)
        XCTAssertEqual(engine.seeks, [20])
        XCTAssertEqual(model.seconds, 20)
        XCTAssertEqual(defaults.double(forKey: "position.test"), 20)

        engine.emit(.ended, seconds: 100, duration: 0, seekable: false)
        await finishQueuedCallbacks()
        XCTAssertEqual(completions, 1)
        withExtendedLifetime(observer) {}
        model.close()
    }
    func testCancellingHeldScrubWithoutSeekDeliversDeferredEOFOnce() async throws {
        let (model, engine, _) = try fixture()
        var completions = 0
        model.onPlaybackEnded = { completions += 1 }
        model.attach(to: UIView())
        engine.emit(.playing, seconds: 90)
        let (controller, slider, observer) = scrubFixture(model: model)
        XCTAssertTrue(slider.beginScrubbing())
        engine.emit(.ended, seconds: 100, duration: 0, seekable: false)
        await finishQueuedCallbacks()
        XCTAssertEqual(completions, 0)
        controller.cancel()
        controller.cancel()
        slider.finishScrubbing()
        engine.emit(.ended, seconds: 100, duration: 0, seekable: false)
        await finishQueuedCallbacks()
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(engine.seeks.isEmpty)
        XCTAssertEqual(engine.playCount, 1)
        withExtendedLifetime(observer) {}
        model.close()
    }
    func testScrubStartingAfterEOFCancelsDeliveryUntilItEnds() async throws {
        let (model, engine, _) = try fixture()
        var completions = 0
        model.onPlaybackEnded = { completions += 1 }
        model.attach(to: UIView())
        engine.emit(.playing, seconds: 90)
        engine.emit(.ended, seconds: 100)
        model.setScrubbing(true)
        await finishQueuedCallbacks()
        XCTAssertEqual(completions, 0)
        model.setScrubbing(false)
        await finishQueuedCallbacks()
        XCTAssertEqual(completions, 1)
        model.close()
    }
    func testPauseOrCloseCancelsEOFReleasedByScrubCancellation() async throws {
        for shouldClose in [false, true] {
            let (model, engine, _) = try fixture()
            var completions = 0
            model.onPlaybackEnded = { completions += 1 }
            model.attach(to: UIView())
            engine.emit(.playing, seconds: 90)
            let (controller, slider, observer) = scrubFixture(model: model)
            XCTAssertTrue(slider.beginScrubbing())
            engine.emit(.ended, seconds: 100, duration: 0, seekable: false)
            controller.cancel()
            if shouldClose { model.close() } else { model.pause() }
            slider.finishScrubbing()
            await finishQueuedCallbacks()
            XCTAssertEqual(completions, 0)
            XCTAssertEqual(engine.playCount, 1)
            XCTAssertTrue(engine.seeks.isEmpty)
            withExtendedLifetime(observer) {}
            model.close()
        }
    }
    func testSeekAfterEOFAndLatePauseWaitsForExplicitPlayThenAppliesTarget() async throws {
        let (model, engine, _) = try fixture()
        model.attach(to: UIView())
        engine.emit(.playing, seconds: 90)
        model.setScrubbing(true)
        engine.emit(.ended, seconds: 100, duration: 0, seekable: false)
        model.pause()
        engine.emit(.paused, seconds: 0, duration: 0, seekable: false)
        model.setScrubbing(false)
        model.seek(to: 30)
        await finishQueuedCallbacks()
        XCTAssertEqual(engine.playCount, 1)
        XCTAssertEqual(engine.loads.count, 1, "A paused EOF seek must not open the input early")
        XCTAssertTrue(engine.seeks.isEmpty)
        XCTAssertEqual(model.phase, .paused)
        XCTAssertEqual(model.seconds, 30)
        model.toggle()
        XCTAssertEqual(engine.playCount, 2)
        XCTAssertEqual(engine.loads.count, 2)
        engine.emit(.playing, seconds: 0)
        XCTAssertEqual(engine.seeks, [30])
        XCTAssertEqual(model.seconds, 30)
        XCTAssertEqual(model.phase, .playing)
        model.close()
    }
    func testRestartPlayingWithoutSeekReadinessKeepsTargetAndSuppressesOldEOF() async throws {
        let (model, engine, _) = try fixture()
        var completions = 0
        model.onPlaybackEnded = { completions += 1 }
        model.attach(to: UIView())
        engine.emit(.playing, seconds: 90)
        model.setScrubbing(true)
        engine.emit(.ended, seconds: 100, duration: 0, seekable: false)
        model.setScrubbing(false)
        model.seek(to: 20)

        engine.emit(.playing, seconds: 0, duration: 0, seekable: false)
        XCTAssertTrue(model.seekable, "The pending target must preserve the slider's valid range")
        XCTAssertEqual(model.duration, 100)
        XCTAssertEqual(model.seconds, 20)
        XCTAssertTrue(engine.seeks.isEmpty)
        engine.emit(.ended, seconds: 100, duration: 0, seekable: false)
        await finishQueuedCallbacks()
        XCTAssertEqual(completions, 0, "A stale EOF cannot complete a restart before its seek is applied")
        XCTAssertEqual(model.seconds, 20)

        model.seek(to: 30)
        XCTAssertEqual(engine.playCount, 2, "Replacing a queued target must not reopen again")
        engine.emit(.playing, seconds: 0, duration: 100, seekable: false)
        XCTAssertTrue(engine.seeks.isEmpty)
        engine.emit(.playing, seconds: 0, duration: 100, seekable: true)
        XCTAssertEqual(engine.seeks, [30])
        XCTAssertEqual(model.seconds, 30)
        engine.emit(.ended, seconds: 100, duration: 0, seekable: false)
        await finishQueuedCallbacks()
        XCTAssertEqual(completions, 1)
        model.close()
    }
    func testNativeStoppedSnapshotAfterEndDoesNotCancelCompletionOrRestoreBookmark() async throws {
        let (model, engine, defaults) = try fixture()
        var completions = 0
        model.onPlaybackEnded = { completions += 1 }
        model.attach(to: UIView())
        engine.emit(.playing, seconds: 90)
        engine.emit(.ended, seconds: 100)
        engine.emit(.idle, seconds: 0, duration: 0, seekable: false)
        await finishQueuedCallbacks()
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(model.phase, .ended)
        XCTAssertEqual(model.seconds, 100)
        XCTAssertNil(defaults.object(forKey: "position.test"))
        model.close()
    }
    func testPausedReplayAfterCancelledEndCanCompleteAgain() async throws {
        let (model, engine, _) = try fixture()
        var completions = 0
        model.onPlaybackEnded = { completions += 1 }
        model.attach(to: UIView())
        engine.emit(.playing)
        engine.emit(.ended, seconds: 100)
        model.pause()
        engine.emit(.paused, seconds: 100)
        await finishQueuedCallbacks()
        XCTAssertEqual(completions, 0)
        model.toggle()
        engine.emit(.playing, seconds: 0)
        engine.emit(.ended, seconds: 100)
        await finishQueuedCallbacks()
        XCTAssertEqual(completions, 1)
        model.close()
    }
    func testPauseBeforeMountPreventsAutomaticPlayback() throws {
        let (model, engine, _) = try fixture()
        model.pause()
        model.attach(to: UIView())
        XCTAssertEqual(engine.loads.count, 1)
        XCTAssertEqual(engine.playCount, 0)
        XCTAssertEqual(model.phase, .paused)
        model.toggle()
        XCTAssertEqual(engine.playCount, 1)
        model.close()
    }
    func testLatePlayingEventCannotUndoPauseDuringOpening() throws {
        let (model, engine, _) = try fixture()
        model.attach(to: UIView())
        model.pause()
        engine.emit(.playing)
        XCTAssertEqual(model.phase, .paused)
        XCTAssertEqual(engine.pauseCount, 2)
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
        XCTAssertEqual(engine.loads.count, 1, "Ordinary seeks must not reload or revalidate the file")
        model.close()
    }
    func testEOFReloadFailureRemainsFailedWithoutAdvancing() async throws {
        for useSeek in [false, true] {
            let (model, engine, _) = try fixture()
            var completions = 0
            model.onPlaybackEnded = { completions += 1 }
            model.attach(to: UIView())
            engine.emit(.playing, seconds: 90)
            model.setScrubbing(true)
            engine.emit(.ended, seconds: 100, duration: 0, seekable: false)
            try FileManager.default.removeItem(at: XCTUnwrap(engine.loads.first))
            model.setScrubbing(false)
            if useSeek { model.seek(to: 20) } else { model.toggle() }
            engine.emit(.playing, seconds: 0)
            engine.emit(.ended, seconds: 100, duration: 0, seekable: false)
            await finishQueuedCallbacks()
            XCTAssertEqual(model.phase, .failed)
            XCTAssertNotNil(model.message)
            XCTAssertEqual(engine.playCount, 1)
            XCTAssertEqual(engine.loads.count, 1)
            XCTAssertEqual(completions, 0)
            model.close()
        }
    }
}
