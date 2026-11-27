import SwiftUI
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(SigningReminderPlan.identifiers.contains(notification.request.identifier) ? [.banner, .sound] : [])
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == VideoStore.sessionID else { completionHandler(); return }
        VideoStore.shared.backgroundCompletion = completionHandler
    }
}

@main
@MainActor
struct NiceVideosApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #if DEBUG
    private static let isolatedLibraryTestStore: VideoStore? = {
        let id = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(id, isDirectory: true)
        guard let storage = try? LocalStorage(root: directory),
              let defaults = UserDefaults(suiteName: "FilePickerUITest." + id) else { return nil }
        if ProcessInfo.processInfo.arguments.contains("--ui-test-deleted-records") {
            do {
                let server = try ServerAddress.normalize("http://127.0.0.1:9")
                func completed(_ name: String) -> DownloadRecord {
                    let video = Video(name: name, size: 4, contentType: "video/mp4", url: "", downloadUrl: "")
                    var record = DownloadRecord(video: video, server: server)
                    record.state = .complete
                    return record
                }
                let kept = completed("Retained movie.mp4")
                try Data([1, 2, 3, 4]).write(to: storage.destination(for: kept))
                // Leave the second payload absent, as when removed from Files.
                try storage.saveRecords([kept, completed("Removed movie.mp4")])
            } catch { return nil }
        }
        return VideoStore(storage: storage, defaults: defaults, restoreDownloads: false)
    }()
    #endif
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-test-playback") {
                PlaybackUITestFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("--ui-test-file-picker") ||
                        ProcessInfo.processInfo.arguments.contains("--ui-test-vr-folder") ||
                        ProcessInfo.processInfo.arguments.contains("--ui-test-deleted-records") {
                if let store = Self.isolatedLibraryTestStore { NiceVideosRootView(store: store) }
                else { Text("无法创建文件选择器测试片库") }
            } else if ProcessInfo.processInfo.arguments.contains("--ui-test-moving-video"),
                      let store = Self.isolatedLibraryTestStore {
                MovingVideoUITestRoot(store: store)
            } else {
                NiceVideosRootView(store: .shared)
            }
            #else
            NiceVideosRootView(store: .shared)
            #endif
        }
    }
}

#if DEBUG
// Only the test runner carries the movie. Open its bytes through the same
// document and store entry points that a successful Files selection uses.
@MainActor private struct MovingVideoUITestRoot: View {
    let store: VideoStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var opened = false

    var body: some View {
        NiceVideosRootView(store: store)
            .task(id: scenePhase) {
                guard !opened, scenePhase == .active else { return }
                opened = true
                do {
                    let environment = ProcessInfo.processInfo.environment
                    func fixtureData(_ key: String) throws -> Data {
                        guard let encoded = environment[key], let compressed = Data(base64Encoded: encoded) else {
                            throw ClientError("Missing test movie bytes")
                        }
                        return try (compressed as NSData).decompressed(using: .zlib) as Data
                    }
                    let resume360 = environment["NICE_UI_TEST_RESUME_360"] == "1"
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                        resume360 ? "resume-stereo360.mp4" : "moving-stereo.mp4")
                    try fixtureData("NICE_UI_TEST_MOVIE").write(to: url, options: .atomic)
                    if environment["NICE_UI_TEST_SAMPLES"] != nil {
                        let handle = try FileHandle(forWritingTo: url)
                        defer { try? handle.close() }
                        try handle.seek(toOffset: UInt64(1) << 32)
                        try handle.write(contentsOf: fixtureData("NICE_UI_TEST_SAMPLES"))
                    }
                    let file = try await PickedVideoFile.open(url)
                    if resume360 {
                        // Reproduce a saved headset movie opened well beyond its first frame.
                        let key = PlaybackRequest(pickedFile: file).key
                        var profile = VRMoviePreferences()
                        profile.projection = .vr360
                        profile.eyes = .sideBySide
                        profile.headset = true
                        profile.save(key: key)
                        UserDefaults.standard.set(143.0, forKey: "position." + key)
                    }
                    try store.playPickedFile(file, startMode: resume360 ? .panorama : .standard)
                } catch { store.errorMessage = error.localizedDescription }
            }
    }
}
#endif

@MainActor private struct NiceVideosRootView: View {
    @StateObject private var signing = SigningStatusModel()
    // The test fixture never initializes the user's shared store or settings.
    // The normal root subscribes only to presentation changes, not progress ticks.
    private let store: VideoStore

    init(store: VideoStore) { self.store = store }

    var body: some View {
        LibraryRootView(store: store)
            .environmentObject(store)
            .environmentObject(signing)
    }
}
