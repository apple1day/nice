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
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-test-playback") {
                PlaybackUITestFixtureView()
            } else {
                NiceVideosRootView()
            }
            #else
            NiceVideosRootView()
            #endif
        }
    }
}

@MainActor private struct NiceVideosRootView: View {
    @StateObject private var signing = SigningStatusModel()
    // The test fixture never initializes the user's shared store or settings.
    // The normal root subscribes only to presentation changes, not progress ticks.
    private let store = VideoStore.shared
    var body: some View {
        LibraryRootView(store: store)
            .environmentObject(store)
            .environmentObject(signing)
    }
}
