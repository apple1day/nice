import Foundation

@main
struct VideoFilesChecks {
    private static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }
    }

    static func main() async throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let downloads = scratch.appendingPathComponent("Downloads", isDirectory: true)
        let files = VideoFiles(folder: downloads)
        let base = URL(string: "http://192.168.168.2:8106/")!
        let clip = Video(name: "猫 #1.mp4", size: 24, contentType: "video/mp4", downloadUrl: "/api/download/%E7%8C%AB%20%231.mp4")
        let stream = Video(name: "stream.mp4", size: 5, contentType: "application/vnd.apple.mpegurl", downloadUrl: "/api/download/stream.mp4")
        let json = try JSONEncoder().encode(["videos": [clip, stream]])
        let entries = try await files.catalog(data: json, base: base)
        try expect(entries.count == 2, "catalog order/count")
        let entry = entries[0]
        try expect(entry.filename == "18abe98ea7c1e4e4_猫 #1.mp4", "legacy filename for Unicode and special characters")
        try expect(entry.supported && !entries[1].supported, "supported video and playlist")
        let otherBase = URL(string: "http://other.test/")!
        let otherEntries = try await files.catalog(data: json, base: otherBase)
        try expect(otherEntries[0].filename != entry.filename, "separate servers use separate local copies")
        try expect(try await files.scan().isEmpty, "new directory")
        try expect(try await files.existing(entry) == nil, "missing download")
        let binary = Data(repeating: 0x80, count: 24)
        let temporary = scratch.appendingPathComponent("temp-video")
        try binary.write(to: temporary)
        let ok = HTTPURLResponse(url: base, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "video/mp4"])!
        let item = try await files.install(temporary, response: ok, entry: entry)
        try expect(try Data(contentsOf: item.url) == binary, "download installation")
        try expect(try await files.existing(entry) == item, "installed size lookup")
        try expect(try await files.verified(entry), "complete binary file")
        let scanned = try await files.scan()
        try expect(scanned == [item], "scan discovers installed file: expected \(item), found \(scanned)")

        let unsupportedData = Data("#EXTM3U".utf8) + Data(repeating: 32, count: 17)
        try unsupportedData.write(to: item.url)
        try expect(try await files.verified(entry) == false, "reject same-sized playlist as local backup")
        try Data([1, 2, 3]).write(to: item.url)
        try expect(try await files.existing(entry) == nil, "wrong-sized copy")
        try expect(try await files.verified(entry) == false, "reject truncated backup")

        // A failed replacement must not destroy the old copy or leave a temporary file.
        try binary.write(to: item.url)
        try Data([0]).write(to: temporary)
        let badInstall = try? await files.install(temporary, response: ok, entry: entry)
        try expect(badInstall == nil, "reject truncated download")
        try expect(try Data(contentsOf: item.url) == binary, "existing copy survives bad replacement")
        try expect(!fm.fileExists(atPath: temporary.path), "temporary file cleanup")

        let replacement = Data(repeating: 0x01, count: 24)
        try replacement.write(to: temporary)
        let changed = try await files.install(temporary, response: ok, entry: entry)
        try expect(changed == item && (try? Data(contentsOf: item.url)) == replacement, "valid replacement installed")

        // A directory substituted at a known file URL must never be recursively removed.
        try fm.removeItem(at: item.url)
        try fm.createDirectory(at: item.url, withIntermediateDirectories: false)
        let keep = item.url.appendingPathComponent("keep")
        try binary.write(to: keep)
        try expect(await files.remove([item]).isEmpty && fm.fileExists(atPath: keep.path), "directory replacement protected")
        try fm.removeItem(at: item.url)
        let external = scratch.appendingPathComponent("outside-video")
        try binary.write(to: external)
        try fm.createSymbolicLink(at: item.url, withDestinationURL: external)
        try expect(try await files.verified(entry) == false, "symbolic link cannot authorize remote deletion")
        try expect(await files.remove([item]).isEmpty && fm.fileExists(atPath: external.path), "symbolic link replacement protected")
        try fm.removeItem(at: item.url)
        try binary.write(to: item.url)
        try expect(await files.remove([item]) == [item] && !fm.fileExists(atPath: item.url.path), "local removal")
        try expect(await files.remove([item]) == [item], "local removal idempotent")

        print("VideoFilesChecks passed")
    }
}
