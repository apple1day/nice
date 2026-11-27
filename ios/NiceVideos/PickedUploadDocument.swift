import Foundation

extension LocalUploadSource {
    // Read each provider's metadata and preserve the selected grant for queued
    // work and explicit retries. Only the active upload needs a private snapshot.
    static func pickedFiles(_ urls: [URL]) async throws -> [Self] {
        var sources: [Self] = []
        var seen = Set<String>()
        for url in urls {
            try Task.checkCancellation()
            do {
                let source = try await PickedUploadDocument.select(url)
                if seen.insert(source.id).inserted { sources.append(source) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw LocalUploadError("「\(url.lastPathComponent)」无法上传：\(error.localizedDescription)")
            }
        }
        return sources
    }
}

extension PickedUploadDocument {
    private static let reads: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "NiceVideos.uploads.documents"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    // The scoped URL identifies the logical document; the coordinated URL is
    // the provider's current representation. Bookmark the former, read the latter.
    private static func read<T>(_ url: URL, options: NSFileCoordinator.ReadingOptions,
                                _ body: @escaping (URL) throws -> T) async throws -> T {
        guard url.isFileURL, (url.host ?? "").isEmpty || url.host == "localhost" else {
            throw LocalUploadError("请从系统「文件」中选择本地视频。")
        }
        let grant = PickedVideoFile.Selection(url)
        defer { withExtendedLifetime(grant) {} }
        try Task.checkCancellation()
        let intent = NSFileAccessIntent.readingIntent(with: url, options: options)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        let value: T = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                coordinator.coordinate(with: [intent], queue: reads) { error in
                    continuation.resume(with: Result {
                        if let error { throw error }
                        return try body(intent.url)
                    })
                }
                if Task.isCancelled { coordinator.cancel() }
            }
        } onCancel: { coordinator.cancel() }
        try Task.checkCancellation()
        return value
    }

    private static func attributes(_ url: URL) throws -> [FileAttributeKey: Any] {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular else {
            throw LocalUploadError("请选择普通视频文件。")
        }
        return attrs
    }

    fileprivate static func select(_ url: URL) async throws -> LocalUploadSource {
        let name = url.lastPathComponent
        return try await read(url, options: .immediatelyAvailableMetadataOnly) { readable in
            let attrs = try attributes(readable)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            try LocalUploadWire.validateSource(name: name, size: size)
            let bookmark = try url.bookmarkData(options: .minimalBookmark,
                                                includingResourceValuesForKeys: nil, relativeTo: nil)
            let picked = Self(bookmark: bookmark, modificationDate: attrs[.modificationDate] as? Date,
                              volume: (attrs[.systemNumber] as? NSNumber)?.uint64Value,
                              fileNumber: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value)
            let stamp = picked.modificationDate?.timeIntervalSinceReferenceDate.bitPattern ?? 0
            return LocalUploadSource(id: "files:" + url.standardizedFileURL.path,
                                     taskToken: "\(picked.volume ?? 0):\(picked.fileNumber ?? 0):\(size):\(stamp)",
                                     name: name, size: size, pickedFile: picked)
        }
    }

    func prepare(_ source: LocalUploadSource, destination: URL) async throws -> URL {
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil,
                              bookmarkDataIsStale: &stale)
            guard !stale else { throw LocalUploadError("所选文件的位置或访问权限已变化。") }
            return try await Self.read(url, options: .withoutChanges) { readable in
                let attrs = try Self.attributes(readable)
                guard (attrs[.size] as? NSNumber)?.int64Value == source.size,
                      modificationDate == attrs[.modificationDate] as? Date,
                      volume == (attrs[.systemNumber] as? NSNumber)?.uint64Value,
                      fileNumber == (attrs[.systemFileNumber] as? NSNumber)?.uint64Value else {
                    throw LocalUploadError("所选视频已被修改或替换。")
                }
                // Foundation clones on supported APFS volumes; a provider on a
                // different volume can require space for one file. Both paths
                // are disk-backed and leave an immutable upload if the user edits
                // or moves their original during the transfer.
                try FileManager.default.copyItem(at: readable, to: destination)
                let copy = try Self.attributes(destination)
                guard (copy[.size] as? NSNumber)?.int64Value == source.size else {
                    throw LocalUploadError("视频暂存不完整。")
                }
                return destination
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LocalUploadError("无法准备「\(source.name)」：\(error.localizedDescription) 请确认文件可用、手机空间充足，必要时从「文件」重新选择。")
        }
    }
}
