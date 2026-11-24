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
    private static let emptyFilePickerTestStore: VideoStore? = {
        let id = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(id, isDirectory: true)
        guard let storage = try? LocalStorage(root: directory),
              let defaults = UserDefaults(suiteName: "FilePickerUITest." + id) else { return nil }
        return VideoStore(storage: storage, defaults: defaults, restoreDownloads: false)
    }()
    #endif
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-test-playback") {
                PlaybackUITestFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("--ui-test-file-picker") {
                if let store = Self.emptyFilePickerTestStore { NiceVideosRootView(store: store) }
                else { Text("无法创建文件选择器测试片库") }
            } else {
                NiceVideosRootView(store: .shared)
            }
            #else
            NiceVideosRootView(store: .shared)
            #endif
        }
    }
}

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
