import Darwin
import Foundation
import UIKit

/// Owns the security-scoped URL and the original read-only descriptor. Each VLC
/// input has its own position and reads this descriptor using pread(2).
final class PickedVideoFile {
    var url: URL { selection.url }
    let byteCount: UInt64
    private let handle: FileHandle
    private let presentation: Presentation
    private let selection: Selection

    /// Created synchronously by the Files delegate. This same grant survives
    /// dismissal, asynchronous preparation, and the last decoder that uses it.
    final class Selection: Identifiable {
        let url: URL
        private let stop: (() -> Void)?
        private let directoryGrant: Selection?
        // A descendant of a security-scoped directory inherits its read grant.
        // Playback and thumbnail work retain this exact grant after navigation.
        init(_ url: URL, inheriting directoryGrant: Selection) {
            self.url = url
            self.directoryGrant = directoryGrant
            stop = nil
        }
        init(_ url: URL, startAccess: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
             endAccess: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
            self.url = url
            directoryGrant = nil
            // URLs already readable in the sandbox may not require a scope.
            stop = startAccess(url) ? { endAccess(url) } : nil
        }
        deinit { stop?() }
    }

    /// Present the logical document selected in Files, even when a provider
    /// supplies a different URL for the contents of a particular accessor.
    private final class Presentation: NSObject, NSFilePresenter {
        let presentedItemOperationQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.name = "NiceVideos.Files.moves"
            queue.maxConcurrentOperationCount = 1
            return queue
        }()
        private let locationLock = NSLock()
        private var location: URL
        var currentURL: URL { locationLock.withLock { location } }
        var presentedItemURL: URL? { currentURL }
        func presentedItemDidMove(to newURL: URL) {
            locationLock.withLock { location = newURL }
        }

        // Registration may ask for presentedItemURL, so it must not hold the
        // location lock. An open finishing in the background stays unregistered.
        private let registrationLock = NSLock()
        private var active = false
        private var foreground: Bool
        private var registered = false
        @MainActor init(_ url: URL) {
            location = url
            foreground = UIApplication.shared.applicationState != .background
            super.init()
            for notification in [UIApplication.didEnterBackgroundNotification, UIApplication.willEnterForegroundNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(applicationStateChanged(_:)),
                                                       name: notification, object: nil)
            }
        }
        @objc private func applicationStateChanged(_ notification: Notification) {
            updateRegistration(foreground: notification.name == UIApplication.willEnterForegroundNotification)
        }
        func updateRegistration(active: Bool? = nil, foreground: Bool? = nil) {
            registrationLock.withLock {
                if let active { self.active = active }
                if let foreground { self.foreground = foreground }
                let shouldRegister = self.active && self.foreground
                guard registered != shouldRegister else { return }
                if shouldRegister { NSFileCoordinator.addFilePresenter(self) }
                else { NSFileCoordinator.removeFilePresenter(self) }
                registered = shouldRegister
            }
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }

    private static let preparationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "NiceVideos.Files.open"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private init(contentsAt url: URL, selection: Selection, presentation: Presentation) throws {
        try Self.requireLocalURL(url)
        // Keep O_NONBLOCK until fstat excludes a FIFO or other special file.
        let fd = try url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { throw CocoaError(.fileReadInvalidFileName) }
            let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            return descriptor
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size > 0 else { throw OfflineMediaPolicy.Failure.missingFile }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        // A regular File Provider item can fetch additional ranges on demand.
        // Let reads on the decoder's I/O thread wait for those bytes.
        guard let header = try handle.read(upToCount: 512), !header.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try OfflineMediaPolicy.validateHeader(header)
        self.handle = handle
        self.selection = selection
        self.presentation = presentation
        byteCount = UInt64(info.st_size)
        presentation.updateRegistration(active: true)
    }

    private static func requireLocalURL(_ url: URL) throws {
        guard url.isFileURL, (url.host ?? "").isEmpty || url.host == "localhost" else {
            throw OfflineMediaPolicy.Failure.remoteURL
        }
    }

    static let supportedExtensions = OfflineMediaPolicy.extensions.union([
        "mpeg", "mpg", "m2v", "m2ts", "mts", "3gp", "3g2", "ogv", "vob", "asf", "f4v"
    ])

    private static func validateURL(_ url: URL) throws {
        try requireLocalURL(url)
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
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
        let presentation = await Presentation(selection.url)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        let intent = NSFileAccessIntent.readingIntent(with: selection.url, options: .withoutChanges)
        let result: Result<PickedVideoFile, Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                coordinator.coordinate(with: [intent], queue: preparationQueue) { error in
                    continuation.resume(returning: Result {
                        if let error { throw error }
                        return try PickedVideoFile(contentsAt: intent.url, selection: selection, presentation: presentation)
                    })
                }
                // Covers cancellation that occurred just before registration.
                if Task.isCancelled { coordinator.cancel() }
            }
        } onCancel: { coordinator.cancel() }
        try Task.checkCancellation()
        return try result.get()
    }

    /// Coordinate each bounded refill, keeping the original descriptor as the
    /// only source of bytes. Provider timestamps and cache pathnames can change
    /// while that descriptor is still readable.
    func read(into buffer: UnsafeMutableRawPointer, count: Int, at offset: UInt64) throws -> Int {
        guard count >= 0 else { throw POSIXError(.EINVAL) }
        guard count > 0, offset < byteCount else { return 0 }
        let length = Int(min(UInt64(count), byteCount - offset))
        var location = presentation.currentURL
        var canRetryMove = true
        while true {
            var outcome: Result<Int, Error>?
            var coordinationError: NSError?
            let coordinator = NSFileCoordinator(filePresenter: presentation)
            coordinator.coordinate(readingItemAt: location, options: .withoutChanges, error: &coordinationError) { _ in
                outcome = Result { try readDescriptor(into: buffer, length: length, offset: off_t(offset)) }
            }
            if let coordinationError {
                let updated = presentation.currentURL
                guard canRetryMove, updated != location else { throw coordinationError }
                canRetryMove = false
                location = updated
                continue
            }
            guard let outcome else { throw CocoaError(.fileReadUnknown) }
            return try outcome.get()
        }
    }

    private func readDescriptor(into buffer: UnsafeMutableRawPointer, length: Int, offset: off_t) throws -> Int {
        let fd = handle.fileDescriptor
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard info.st_size >= 0, UInt64(info.st_size) >= byteCount else {
            throw CocoaError(.fileReadCorruptFile)
        }
        while true {
            let bytes = pread(fd, buffer, length, offset)
            if bytes > 0 { return bytes }
            if bytes == 0 { throw CocoaError(.fileReadCorruptFile) }
            let errorCode = errno
            if errorCode != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode)) }
        }
    }

    deinit {
        presentation.updateRegistration(active: false)
        // Close before releasing the URL's access, including failed/cancelled UI sessions.
        try? handle.close()
    }
}
