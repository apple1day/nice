import Combine
import Foundation

@main
struct VideoStateChecks {
    private static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }
    }

    @MainActor
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let entries = (0..<500).map { index -> CatalogEntry in
            let name = String(format: "clip-%03d.mp4", index)
            let video = Video(name: name, size: Int64(index + 1), contentType: "video/mp4", downloadUrl: "/api/download/" + name)
            return CatalogEntry(video: video, filename: name, supported: true)
        }
        let stream = Video(name: "playlist.mp4", size: 100, contentType: "application/vnd.apple.mpegurl",
                           downloadUrl: "/api/download/playlist.mp4")
        let unsupported = CatalogEntry(video: stream, filename: stream.name, supported: false)
        let complete = entries.map { LocalVideo(url: folder.appendingPathComponent($0.filename), size: $0.video.size) }
        let partial = LocalVideo(url: complete[200].url, size: 5)
        let unrelated = LocalVideo(url: folder.appendingPathComponent("extra.mov"), size: 33)

        let catalog = CatalogState()
        let library = LibraryState()
        let initial = (Array(complete.prefix(200)) + [partial, unrelated]).sorted { $0.name < $1.name }
        library.replace(initial)
        catalog.replace(entries + [unsupported], local: library.byName)
        let catalogBytes = entries.reduce(Int64(0)) { $0 + $1.video.size }
        let first200Bytes = complete.prefix(200).reduce(Int64(0)) { $0 + $1.size }
        try expect(library.items.count == 202 && library.bytes == first200Bytes + 38, "local storage includes partial and external files")
        try expect(catalog.pendingCount == 300 && catalog.downloadedCount == 200, "500 remote/200 downloaded")
        try expect(catalog.pendingBytes == catalogBytes - first200Bytes, "unsupported videos and mismatched sizes excluded from completed bytes")

        var catalogListUpdates = 0
        let observation = catalog.$entries.dropFirst().sink { _ in catalogListUpdates += 1 }
        defer { observation.cancel() }
        for item in complete.dropFirst(200).reversed() {
            library.record(item)
            catalog.record(item)
        }
        library.record(complete[200])
        catalog.record(complete[200])
        try expect(library.items == complete + [unrelated], "sorted incremental insertion and idempotent replacement")
        try expect(library.bytes == catalogBytes + unrelated.size && library.byName.count == 501, "incremental storage accounting")
        try expect(catalog.pendingCount == 0 && catalog.pendingBytes == 0 && catalog.downloadedCount == 500, "batch completed")
        library.record(partial)
        catalog.record(partial)
        try expect(catalog.pendingCount == 1 && catalog.pendingBytes == complete[200].size, "a truncated file re-enters the download queue")
        library.replace([unrelated])
        catalog.match(library.byName)
        try expect(catalog.downloadedNames.isEmpty && catalog.pendingBytes == catalogBytes, "deletion reconciles the download index")
        try expect(catalogListUpdates == 0, "file and progress changes never republish the remote catalog list")
        try await checkMarks(complete: complete)
        print("VideoStateChecks passed")
    }

    @MainActor
    private static func checkMarks(complete: [LocalVideo]) async throws {
        let suite = "NiceVideos15.Checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = complete[0]
        let second = complete[1]
        defaults.set([first.name, "old-deleted.mp4"], forKey: "pendingDeletion")
        let marks = MarkState(suiteName: suite)
        let local = [first.name: first, second.name: second]
        let saved = await marks.savedNames()
        marks.reconcile(local: local, saved: saved)
        try expect(marks.names == [first.name] && marks.bytes == first.size, "restore legacy marks and drop missing files")
        marks.toggle(second)
        marks.toggle(second)
        marks.toggle(first)
        marks.toggle(second)
        try expect(marks.names == [second.name] && marks.bytes == second.size, "rapid mark changes update immediately")
        marks.updateSize(of: second.name, delta: 5)
        try expect(marks.bytes == second.size + 5, "marked copy size change")
        // Persistence runs on an actor. Wait for the last value to be visible to another reader.
        for _ in 0..<200 {
            if Set(defaults.stringArray(forKey: "pendingDeletion") ?? []) == [second.name] { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw Failure(message: "last mark state did not persist")
    }
}
