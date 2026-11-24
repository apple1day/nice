import Darwin
import Foundation

/// Owns the security-scoped URL and the original read-only descriptor. Each VLC
/// input has its own position and reads this descriptor using pread(2).
final class PickedVideoFile {
    let url: URL
    let byteCount: UInt64
    private let handle: FileHandle
    private let original: stat
    private let selection: Selection

    /// Created synchronously by the Files delegate. This same grant survives
    /// dismissal, asynchronous preparation, and the last decoder that uses it.
    final class Selection: Identifiable {
        let url: URL
        private let stop: (() -> Void)?
        init(_ url: URL, startAccess: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
             endAccess: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
            self.url = url
            // URLs already readable in the sandbox may not require a scope.
            stop = startAccess(url) ? { endAccess(url) } : nil
        }
        deinit { stop?() }
    }

    private static let preparationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "NiceVideos.Files.open"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private init(url: URL, selection: Selection) throws {
        try Self.validateURL(url)
        let fd = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size > 0 else { throw OfflineMediaPolicy.Failure.missingFile }
        // Validate the same open file that the decoder will read, even when the
        // provider changes the picked path. Never read the whole movie as Data.
        try OfflineMediaPolicy.validateHeader(handle.read(upToCount: 512) ?? Data())
        self.handle = handle
        self.url = url
        self.selection = selection
        original = info
        byteCount = UInt64(info.st_size)
    }

    private static func validateURL(_ url: URL) throws {
        guard url.isFileURL, (url.host ?? "").isEmpty || url.host == "localhost" else {
            throw OfflineMediaPolicy.Failure.remoteURL
        }
        guard OfflineMediaPolicy.extensions.contains(url.pathExtension.lowercased()) else {
            throw OfflineMediaPolicy.Failure.unsupported
        }
    }

    static func open(_ url: URL) async throws -> PickedVideoFile {
        try Task.checkCancellation()
        return try await open(Selection(url))
    }

    static func open(_ selection: Selection) async throws -> PickedVideoFile {
        try Task.checkCancellation()
        try validateURL(selection.url)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        let intent = NSFileAccessIntent.readingIntent(with: selection.url, options: .withoutChanges)
        let result: Result<PickedVideoFile, Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                coordinator.coordinate(with: [intent], queue: preparationQueue) { error in
                    continuation.resume(returning: Result {
                        if let error { throw error }
                        return try PickedVideoFile(url: intent.url, selection: selection)
                    })
                }
                // Covers cancellation that occurred just before registration.
                if Task.isCancelled { coordinator.cancel() }
            }
        } onCancel: { coordinator.cancel() }
        try Task.checkCancellation()
        return try result.get()
    }

    /// Called only on VLC's I/O threads, in bounded chunks. Limit the provider's
    /// coordinated read to this call, so pausing or suspending the app never
    /// holds a coordination lock. A changed/unavailable source is a read error.
    func read(into buffer: UnsafeMutableRawPointer, count: Int, at offset: UInt64) -> Int {
        guard count >= 0, offset <= byteCount else { return -1 }
        if count == 0 || offset == byteCount { return 0 }
        let length = Int(min(UInt64(count), byteCount - offset))
        var result = -1
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: .withoutChanges,
                                                        error: &coordinationError) { coordinatedURL in
            var current = stat()
            let status = coordinatedURL.withUnsafeFileSystemRepresentation { path in
                path.map { lstat($0, &current) } ?? -1
            }
            guard status == 0, current.st_dev == original.st_dev, current.st_ino == original.st_ino,
                  current.st_size == original.st_size,
                  current.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
                  current.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec else { return }
            repeat {
                result = pread(handle.fileDescriptor, buffer, length, off_t(offset))
            } while result < 0 && errno == EINTR
            if result == 0 { result = -1 } // Truncation during a noncoordinated write.
        }
        return coordinationError == nil ? result : -1
    }

    deinit {
        // Close before releasing the URL's access, including failed/cancelled UI sessions.
        try? handle.close()
    }
}
