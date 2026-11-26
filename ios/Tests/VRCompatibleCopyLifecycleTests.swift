import XCTest
@testable import NiceVideos

@MainActor
final class VRCompatibleCopyLifecycleTests: XCTestCase {
    func testExistingDestinationSurvivesAndSourceCannotBeOverwritten() async throws {
        let movie = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "offline", withExtension: "mp4", subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("影片 {1}, '旧版'.mp4")
        let originalData = Data("original".utf8)
        try originalData.write(to: existing)
        for (source, target) in [(movie, existing), (existing, existing)] {
            do {
                _ = try await VRCompatibleCopy.generate(fileURL: source, pickedFile: nil, destination: target) { _ in
                    XCTFail("An occupied destination should not start the encoder")
                }
                XCTFail("The existing file should be protected")
            } catch {
                XCTAssertEqual(try Data(contentsOf: existing), originalData)
            }
        }
    }

    func testCancellationAtStartPublishesNothingAndReleasesDestination() async throws {
        let movie = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "offline", withExtension: "mp4", subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("Cancelled.mp4")
        var started = false
        do {
            _ = try await Task {
                try await VRCompatibleCopy.generate(fileURL: movie, pickedFile: nil, destination: target) { progress in
                    if progress == 0 {
                        started = true
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            }.value
            XCTFail("A cancelled conversion returned a movie")
        } catch is CancellationError {}
        XCTAssertTrue(started)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
