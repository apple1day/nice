import XCTest
@testable import NiceVideos

@MainActor
final class VRFolderLibraryTests: XCTestCase {
    private func tempFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func temporaryDefaults() throws -> UserDefaults {
        let name = "VRFolderLibraryTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func settled(_ library: VRFolderLibrary) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while library.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(library.isLoading)
    }

    func testDirectoryBookmarkRestoresAndRefreshReflectsCurrentContents() async throws {
        let root = try tempFolder()
        let folder = root.appendingPathComponent("VR180", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("sample.MKV")
        try Data([9, 8, 7, 6, 5]).write(to: source)
        for name in ["ignore.txt", "index.m3u8", ".hidden.mp4"] {
            try Data([1]).write(to: folder.appendingPathComponent(name))
        }
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("alias.mp4"), withDestinationURL: source)
        let defaults = try temporaryDefaults()
        let original = VRFolderLibrary(defaults: defaults)
        original.authorize(root)
        try await settled(original)
        XCTAssertNil(original.errorMessage)
        XCTAssertEqual(original.entries.map(\.name), ["VR180"])
        original.enter(try XCTUnwrap(original.entries.first))
        try await settled(original)
        XCTAssertEqual(original.entries.map(\.name), ["sample.MKV"])
        XCTAssertEqual(original.entries.first?.byteCount, 5)
        XCTAssertNotNil(defaults.data(forKey: "vr.folders.v1"))

        let restored = VRFolderLibrary(defaults: defaults)
        restored.restoreLastSelection()
        try await settled(restored)
        XCTAssertEqual(restored.roots, original.roots)
        XCTAssertEqual(restored.path, ["VR180"])
        let movie = try XCTUnwrap(restored.entries.first)
        let bytes = try await PickedVideoFile.open(restored.selection(for: movie))
        XCTAssertEqual(bytes.byteCount, 5)

        try FileManager.default.removeItem(at: source)
        let added = folder.appendingPathComponent("new.mov")
        try Data([5]).write(to: added)
        restored.refresh()
        try await settled(restored)
        XCTAssertEqual(restored.entries.map(\.name), ["new.mov"])
        XCTAssertThrowsError(try restored.selection(for: movie))
        restored.back()
        try await settled(restored)
        XCTAssertEqual(restored.path, [])
        XCTAssertEqual(restored.entries.map(\.name), ["VR180"])
    }

    func testRootGrantSurvivesRemovingFolderUntilLastChildReaderReleases() async throws {
        let root = try tempFolder()
        let name = "kept.mp4"
        try Data([1, 2, 3, 4]).write(to: root.appendingPathComponent(name))
        let stopped = expectation(description: "Release exactly the original root grant")
        stopped.assertForOverFulfill = true
        var starts = 0
        let library = VRFolderLibrary(defaults: try temporaryDefaults()) { url in
            PickedVideoFile.Selection(url, startAccess: { _ in starts += 1; return true },
                                      endAccess: { stoppedURL in
                XCTAssertEqual(stoppedURL, root)
                stopped.fulfill()
            })
        }
        library.authorize(root)
        XCTAssertEqual(starts, 1, "Acquire inside the picker callback")
        try await settled(library)
        let file = try XCTUnwrap(library.entries.first)
        var thumbnailLease: PickedVideoFile.Selection? = try library.selection(for: file)
        var player: PickedVideoFile? = try await PickedVideoFile.open(library.selection(for: file))
        library.forget(try XCTUnwrap(library.currentRoot))
        XCTAssertTrue(library.roots.isEmpty)
        XCTAssertEqual(player?.byteCount, 4)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(thumbnailLease).url), Data([1, 2, 3, 4]))
        thumbnailLease = nil
        XCTAssertEqual(player?.byteCount, 4)
        player = nil
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
    }

    func testReauthorizeMissingFolderAndIgnorePreviousAsynchronousListing() async throws {
        let first = try tempFolder(), second = try tempFolder()
        try Data([1]).write(to: first.appendingPathComponent("first.mov"))
        try Data([2]).write(to: second.appendingPathComponent("second.mp4"))
        let defaults = try temporaryDefaults()
        let library = VRFolderLibrary(defaults: defaults)
        library.authorize(first)
        try await settled(library)
        let old = try XCTUnwrap(library.currentRoot)
        library.authorize(first)
        try await settled(library)
        XCTAssertEqual(library.roots.count, 1)
        try FileManager.default.removeItem(at: first)
        library.refresh()
        try await settled(library)
        XCTAssertNotNil(library.errorMessage)
        XCTAssertTrue(library.needsReauthorization)
        XCTAssertEqual(library.roots.map(\.id), [old.id])
        library.authorize(first, replacing: old.id)
        library.authorize(second, replacing: old.id)
        try await settled(library)
        XCTAssertNil(library.errorMessage)
        XCTAssertEqual(library.roots.map(\.id), [old.id])
        XCTAssertEqual(library.entries.map(\.name), ["second.mp4"])
        let restored = VRFolderLibrary(defaults: defaults)
        restored.restoreLastSelection()
        try await settled(restored)
        XCTAssertEqual(restored.entries.map(\.name), ["second.mp4"])
    }
}
