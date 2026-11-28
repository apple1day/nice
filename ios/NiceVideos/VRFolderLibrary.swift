import Combine
import Darwin
import Foundation

struct VRFolderRoot: Identifiable, Equatable {
    let id: UUID
    let name: String
}

struct VRFolderEntry: Identifiable, Equatable {
    let id: String
    let name: String
    let url: URL
    let isDirectory: Bool
    let byteCount: Int64?
    let modifiedAt: Date?
    let canThumbnail: Bool
}

private struct SavedVRFolder: Codable {
    let id: UUID
    var name: String
    var bookmark: Data
    var lastKnownURL: URL   // A deduplication hint. Access always uses the bookmark.
    var root: VRFolderRoot { VRFolderRoot(id: id, name: name) }
}

private enum FolderSource {
    case picker(PickedVideoFile.Selection)
    case bookmark(Data)
    case open(PickedVideoFile.Selection)
}

private enum FolderRead {
    struct Listing {
        let grant: PickedVideoFile.Selection
        let bookmark: Data?
        let entries: [VRFolderEntry]
    }

    static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.utf8.contains(0)
    }

    static func load(source: FolderSource, root: UUID, path: [String],
                     coordinator: NSFileCoordinator) throws -> Listing {
        try Task.checkCancellation()
        let grant: PickedVideoFile.Selection
        var renew = false
        switch source {
        case .open(let scope): grant = scope
        case .picker(let scope):
            grant = scope
            renew = true
        case .bookmark(let bookmark):
            let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &renew)
            grant = PickedVideoFile.Selection(url)
        }
        guard grant.url.isFileURL, (grant.url.host ?? "").isEmpty || grant.url.host == "localhost",
              path.allSatisfy(validComponent) else { throw CocoaError(.fileReadInvalidFileName) }
        // Refuse intermediate links even if a previously browsed directory was replaced.
        var directory = grant.url
        let directoryKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        for index in 0...path.count {
            let values = try directory.resourceValues(forKeys: directoryKeys)
            guard values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            if index < path.count { directory.appendPathComponent(path[index], isDirectory: true) }
        }
        let bookmark = renew ? try grant.url.bookmarkData(options: .minimalBookmark,
                        includingResourceValuesForKeys: nil, relativeTo: nil) : nil
        var coordinationError: NSError?
        var result: Result<[VRFolderEntry], Error>?
        coordinator.coordinate(readingItemAt: directory, options: .withoutChanges, error: &coordinationError) { location in
            result = Result { try list(location: location, directory: directory, root: root, path: path) }
        }
        try Task.checkCancellation()
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return Listing(grant: grant, bookmark: bookmark, entries: try result.get())
    }

    // Apple's TN3150 recommends checking SF_DATALESS with stat before starting a
    // preview. lstat reads metadata and also detects links substituted since listing.
    static func materialized(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            var info = stat()
            guard let path, Darwin.lstat(path, &info) == 0 else { return false }
            return info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && info.st_flags & UInt32(SF_DATALESS) == 0
        }
    }

    private static func list(location: URL, directory: URL, root: UUID, path: [String]) throws -> [VRFolderEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isHiddenKey, .isPackageKey,
            .isSymbolicLinkKey, .isAliasFileKey, .fileSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey,
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        let urls = try FileManager.default.contentsOfDirectory(at: location, includingPropertiesForKeys: Array(keys),
                                                               options: .skipsHiddenFiles)
        var entries: [VRFolderEntry] = []
        for child in urls {
            try Task.checkCancellation()
            let name = child.lastPathComponent
            guard validComponent(name), !name.hasPrefix("."),
                  let info = try? child.resourceValues(forKeys: keys),
                  info.isSymbolicLink != true, info.isAliasFile != true,
                  info.isHidden != true, info.isPackage != true else { continue }
            let isDirectory = info.isDirectory == true
            guard isDirectory || (info.isRegularFile != false &&
                                  PickedVideoFile.supportedExtensions.contains(child.pathExtension.lowercased())) else { continue }
            // Use the logical provider URL beyond the lifetime of this coordinated accessor.
            let url = directory.appendingPathComponent(name, isDirectory: isDirectory)
            let bytes = isDirectory ? nil : info.fileSize.map { Int64($0) }
            let id = ([root.uuidString] + path + [name]).joined(separator: "/")
            let local: Bool
            if info.isUbiquitousItem == true {
                let status = info.ubiquitousItemDownloadingStatus
                local = status == .current || status == .downloaded
            } else {
                // Unmaterialized and sparse/provider-reported partial files need
                // an explicit playback tap; do not read movie bytes to classify.
                local = (info.fileSize ?? 0) > 0 && (info.fileAllocatedSize ?? 0) >= (info.fileSize ?? Int.max)
            }
            entries.append(VRFolderEntry(id: id, name: name, url: url, isDirectory: isDirectory, byteCount: bytes,
                                         modifiedAt: info.contentModificationDate,
                                         canThumbnail: !isDirectory && local && materialized(child)))
        }
        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.name < $1.name : order == .orderedAscending
        }
    }
}

@MainActor
final class VRFolderLibrary: ObservableObject {
    @Published private(set) var roots: [VRFolderRoot]
    @Published private(set) var currentRoot: VRFolderRoot?
    @Published private(set) var path: [String] = []
    @Published private(set) var entries: [VRFolderEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var needsReauthorization = false

    private let defaults: UserDefaults
    private let capture: (URL) -> PickedVideoFile.Selection
    private var saved: [SavedVRFolder]
    private var grant: PickedVideoFile.Selection?
    private var filesByID: [String: URL] = [:]
    private var pendingPickerBookmark = false
    private var loadTask: Task<Void, Never>?
    private var revision: UInt = 0
    private var attemptedRestore = false

    init(defaults: UserDefaults = .standard,
         capture: @escaping (URL) -> PickedVideoFile.Selection = { PickedVideoFile.Selection($0) }) {
        self.defaults = defaults
        self.capture = capture
        saved = defaults.data(forKey: "vr.folders.v1").flatMap {
            try? JSONDecoder().decode([SavedVRFolder].self, from: $0)
        } ?? []
        roots = saved.map(\.root)
    }
    deinit { loadTask?.cancel() }

    func restoreLastSelection() {
        guard !attemptedRestore, currentRoot == nil else { return }
        attemptedRestore = true
        guard let id = defaults.string(forKey: "vr.folders.lastRoot"),
              let record = saved.first(where: { $0.id.uuidString == id }) else { return }
        let last = defaults.stringArray(forKey: "vr.folders.lastPath") ?? []
        load(record.root, path: last.allSatisfy(FolderRead.validComponent) ? last : [],
             source: .bookmark(record.bookmark))
    }

    func authorize(_ url: URL, replacing: UUID? = nil) {
        attemptedRestore = true
        // Capture the picker grant synchronously before dismissal or an async hop.
        let scope = capture(url)
        let existing = saved.first(where: { $0.lastKnownURL.standardizedFileURL == url.standardizedFileURL })
        let id = replacing ?? existing?.id ?? UUID()
        let root = VRFolderRoot(id: id, name: url.lastPathComponent)
        load(root, path: [], source: .picker(scope))
    }

    func select(_ root: VRFolderRoot) {
        attemptedRestore = true
        guard let record = saved.first(where: { $0.id == root.id }) else { return }
        load(record.root, path: [], source: .bookmark(record.bookmark))
    }

    func enter(_ folder: VRFolderEntry) {
        guard folder.isDirectory, entries.contains(folder), let root = currentRoot, let grant else { return }
        load(root, path: path + [folder.name], source: .open(grant))
    }

    func back() {
        guard !path.isEmpty else { showRoots(); return }
        navigate(to: Array(path.dropLast()))
    }

    func refresh() { navigate(to: path) }

    private func navigate(to path: [String]) {
        guard let root = currentRoot else { return }
        if let grant { load(root, path: path, source: pendingPickerBookmark ? .picker(grant) : .open(grant)) }
        else if let record = saved.first(where: { $0.id == root.id }) {
            load(record.root, path: path, source: .bookmark(record.bookmark))
        }
    }

    func selection(for entry: VRFolderEntry) throws -> PickedVideoFile.Selection {
        guard let grant, !entry.isDirectory, let url = filesByID[entry.id] else { throw CocoaError(.fileReadNoSuchFile) }
        // Use the URL from the current listing instead of a caller-supplied path.
        return PickedVideoFile.Selection(url, inheriting: grant)
    }

    func forget(_ root: VRFolderRoot) {
        if currentRoot?.id == root.id { showRoots() }
        saved.removeAll { $0.id == root.id }
        persist()
    }

    func showRoots() {
        revision &+= 1
        loadTask?.cancel()
        loadTask = nil
        currentRoot = nil
        grant = nil
        path = []
        entries = []
        filesByID = [:]
        errorMessage = nil
        needsReauthorization = false
        isLoading = false
        defaults.removeObject(forKey: "vr.folders.lastRoot")
        defaults.removeObject(forKey: "vr.folders.lastPath")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: "vr.folders.v1") }
        roots = saved.map(\.root)
    }

    private func load(_ root: VRFolderRoot, path: [String], source: FolderSource) {
        revision &+= 1
        let ticket = revision
        loadTask?.cancel()
        switch source {
        case .open(let scope): grant = scope
        case .picker(let scope):
            grant = scope
            pendingPickerBookmark = true
        case .bookmark:
            grant = nil
            pendingPickerBookmark = false
        }
        currentRoot = root
        self.path = path
        entries = []
        filesByID = [:]
        needsReauthorization = false
        errorMessage = nil
        isLoading = true
        let coordinator = NSFileCoordinator(filePresenter: nil)
        let reader = Task.detached(priority: .userInitiated) {
            try FolderRead.load(source: source, root: root.id, path: path, coordinator: coordinator)
        }
        loadTask = Task { [weak self] in
            let result = await withTaskCancellationHandler {
                await reader.result
            } onCancel: {
                reader.cancel()
                coordinator.cancel()
            }
            guard let self, self.revision == ticket else { return }
            self.isLoading = false
            self.loadTask = nil
            do {
                let listing = try result.get()
                let name = listing.grant.url.lastPathComponent
                self.grant = listing.grant
                self.entries = listing.entries
                self.filesByID = Dictionary(uniqueKeysWithValues: listing.entries.lazy.filter { !$0.isDirectory }.map { ($0.id, $0.url) })
                self.pendingPickerBookmark = false
                self.currentRoot = VRFolderRoot(id: root.id, name: name)
                if listing.bookmark != nil {
                    self.saved.removeAll { $0.id != root.id && $0.lastKnownURL.standardizedFileURL == listing.grant.url.standardizedFileURL }
                }
                if let index = self.saved.firstIndex(where: { $0.id == root.id }) {
                    let record = self.saved[index]
                    if listing.bookmark != nil || name != record.name || listing.grant.url != record.lastKnownURL {
                        self.saved[index] = SavedVRFolder(id: root.id, name: name,
                            bookmark: listing.bookmark ?? record.bookmark, lastKnownURL: listing.grant.url)
                        self.persist()
                    }
                } else if let bookmark = listing.bookmark {
                    self.saved.append(SavedVRFolder(id: root.id, name: name, bookmark: bookmark, lastKnownURL: listing.grant.url))
                    self.persist()
                }
                self.defaults.set(root.id.uuidString, forKey: "vr.folders.lastRoot")
                self.defaults.set(path, forKey: "vr.folders.lastPath")
            } catch {
                // Keep the saved bookmark when a drive is disconnected or a provider is offline.
                self.needsReauthorization = path.isEmpty || (error as NSError).code == NSFileReadNoPermissionError
                self.errorMessage = "无法读取此文件夹。请检查存储设备或文件提供方，也可以重新选择文件夹。\n" + error.localizedDescription
            }
        }
    }
}
