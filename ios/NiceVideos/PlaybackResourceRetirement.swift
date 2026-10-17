import Foundation

private enum PlaybackRetirementQueue {
    static let shared = DispatchQueue(label: "com.anxiong.nicevideos.playback-retirement", qos: .utility)
}

// Transfers THIS owner's reference to a serial background queue. Other owners
// may outlive it, so this alone does not determine an object's final deinit
// thread. VLC additionally attaches an independently retained native reference
// to its ObjC wrapper; that reference is retired only when the wrapper dies.
final class BackgroundPlaybackResource<Resource: AnyObject> {
    private final class Storage {
        var resource: Resource?
        var attachments: [ObjectIdentifier: AnyObject] = [:]
        init(_ resource: Resource?) { self.resource = resource }
    }

    private let storage: Storage
    private let releaseQueue: DispatchQueue
    private let lock = NSLock()
    private var retired = false

    init(_ resource: Resource?, releaseQueue: DispatchQueue? = nil) {
        storage = Storage(resource)
        self.releaseQueue = releaseQueue ?? PlaybackRetirementQueue.shared
    }

    // Active callers are main-queue confined. Once retirement starts, no caller
    // can borrow the resource while the background queue is releasing it.
    var resource: Resource? {
        lock.lock()
        defer { lock.unlock() }
        return retired ? nil : storage.resource
    }

    // Keep UIKit attachments alive through native destruction. Capture the
    // storage, not an attachment local, when transferring it back to main:
    // otherwise a fast main queue could leave the last release on the worker.
    func keepAlive(_ attachment: AnyObject) {
        lock.lock()
        defer { lock.unlock() }
        guard !retired else { return }
        storage.attachments[ObjectIdentifier(attachment)] = attachment
    }

    @discardableResult func retire() -> Bool {
        lock.lock()
        guard !retired else { lock.unlock(); return false }
        retired = true
        lock.unlock()

        // Do not capture a resource local here: the worker may run before this
        // method returns and leave that local as its final main-thread owner.
        let storage = storage
        releaseQueue.async {
            #if canImport(ObjectiveC)
            autoreleasepool { storage.resource = nil }
            #else
            storage.resource = nil
            #endif
            DispatchQueue.main.async { storage.attachments.removeAll() }
        }
        return true
    }

    deinit { retire() }
}
