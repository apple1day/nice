import AVFoundation
import XCTest
@testable import NiceVideos

final class PickedAssetResourceLoaderTests: XCTestCase {
    func testHighOffsetsAreBoundedAndStopExactlyAtEOF() throws {
        let base = Int64(1) << 32
        let eof = base + 9_000_000
        let chunk = Int64(PickedAssetResourceLoader.chunkSize)
        func next(_ requested: Int64, _ current: Int64, _ length: Int, _ toEnd: Bool = false) throws -> Range<Int64>? {
            try PickedAssetResourceLoader.nextChunk(requestedOffset: requested, currentOffset: current,
                                                    length: length, toEnd: toEnd, fileLength: eof)
        }
        XCTAssertEqual(try next(base, 0, 32), base..<(base + 32))
        XCTAssertEqual(try next(base, base + 160, 200), (base + 160)..<(base + 200))
        XCTAssertEqual(try next(base, base, Int.max), base..<(base + chunk))
        XCTAssertEqual(try next(base, eof - 3, 1, true), (eof - 3)..<eof)
        XCTAssertEqual(try next(eof - 2, eof - 2, 128), (eof - 2)..<eof)
        XCTAssertNil(try next(base, base + 200, 200))
        XCTAssertNil(try next(eof + 2, eof + 2, 10))
        XCTAssertThrowsError(try next(-1, 0, 2))
    }

    /// A real H.264 frame lives past 4 GiB. A provider replacing its pathname
    /// after selection must not redirect AVFoundation to the new contents.
    func testSystemDecoderReadsOriginalFrameBeyondFourGiB() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("测试 #1.mp4")
        func fixture(_ name: String) throws -> Data {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "bin",
                                                               subdirectory: "Fixtures"))
            return try Data(contentsOf: url)
        }
        try fixture("co64-index").write(to: movie)
        let writer = try FileHandle(forWritingTo: movie)
        try writer.seek(toOffset: UInt64(1) << 32)
        try writer.write(contentsOf: fixture("co64-samples"))
        try writer.close()
        let file = try await PickedVideoFile.open(movie)
        let loader = PickedAssetResourceLoader(file: file)
        defer { loader.cancel() }
        try Data("different document".utf8).write(to: movie, options: .atomic)
        let duration = try await loader.asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 10)
        let generator = AVAssetImageGenerator(asset: loader.asset)
        let (image, _) = try await generator.image(at: CMTime(seconds: 5, preferredTimescale: 600))
        XCTAssertEqual(image.width, 160)
        XCTAssertEqual(image.height, 90)
    }
}
