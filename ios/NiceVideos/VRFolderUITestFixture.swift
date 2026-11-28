#if DEBUG
import Foundation

// Only an explicitly launched UI-test process can supply a simulated picker
// result. The normal UI, bookmark persistence, enumeration and playback are real.
@MainActor enum VRFolderUITestFixture {
    private static var testID: UUID? {
        let process = ProcessInfo.processInfo
        guard process.arguments.contains("--ui-test-vr-folder"),
              let value = process.environment["NICE_VR_FOLDER_TEST_ID"] else { return nil }
        return UUID(uuidString: value)
    }

    static var isolatedDefaults: UserDefaults? {
        testID.flatMap { UserDefaults(suiteName: "VRFolderUITest." + $0.uuidString) }
    }

    static func chooseIfRequested(in library: VRFolderLibrary, replacing: UUID?) -> Bool {
        guard let id = testID, let encoded = ProcessInfo.processInfo.environment["NICE_VR_FOLDER_MOVIE"] else {
            return false  // Use the actual UIDocumentPicker, including on test relaunch.
        }
        do {
            guard let compressed = Data(base64Encoded: encoded) else { throw CocoaError(.fileReadCorruptFile) }
            let movie = try (compressed as NSData).decompressed(using: .zlib) as Data
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
                .appendingPathComponent("VR 示例", isDirectory: true)
            let child = root.appendingPathComponent("旅行", isDirectory: true)
            try fm.createDirectory(at: child, withIntermediateDirectories: true)
            try movie.write(to: root.appendingPathComponent("Panorama Demo.mp4"), options: .atomic)
            try movie.write(to: child.appendingPathComponent("Trip.mov"), options: .atomic)
            try Data("Not a video".utf8).write(to: root.appendingPathComponent("notes.txt"))
            library.authorize(root, replacing: replacing)
        } catch {
            assertionFailure("VR folder UI test fixture failed: \(error.localizedDescription)")
        }
        return true
    }
}
#endif
