import XCTest
@testable import NiceVideos

final class ServerVideoDeletionTests: XCTestCase {
    private func video(downloadURL: String) -> Video {
        Video(name: "中文 a+b%#.mp4", size: 1024, contentType: "video/mp4",
              url: "/api/stream/%E4%B8%AD%E6%96%87%20a+b%25%23.mp4",
              downloadUrl: downloadURL)
    }

    func testDeleteEndpointReusesServerEncodedFilenameExactlyOnce() throws {
        let base = try ServerAddress.normalize("http://192.168.19.70:8106")
        let item = video(downloadURL: "/api/download/%E4%B8%AD%E6%96%87%20a+b%25%23.mp4")
        let result = try ServerAddress.deleteEndpoint(for: item, on: base)
        XCTAssertEqual(result.absoluteString,
                       "http://192.168.19.70:8106/api/videos/%E4%B8%AD%E6%96%87%20a+b%25%23.mp4")
        XCTAssertEqual(result.path, "/api/videos/中文 a+b%#.mp4")
    }

    func testDeleteEndpointRejectsUnexpectedDownloadPath() throws {
        let base = try ServerAddress.normalize("http://192.168.19.70:8106")
        for path in [
            "/download/demo.mp4",
            "/api/stream/demo.mp4",
            "/api/download/",
            "/api/download/folder/demo.mp4",
            "/api/download/demo.mp4?token=x",
            "/api/download/demo.mp4#fragment"
        ] {
            XCTAssertThrowsError(try ServerAddress.deleteEndpoint(for: video(downloadURL: path), on: base), path)
        }
    }
}
