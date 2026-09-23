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
    @StateObject private var signing = SigningStatusModel()
    // The root subscribes only to presentation changes, not every progress tick.
    private let store = VideoStore.shared
    var body: some Scene {
        WindowGroup {
            LibraryRootView(store: store)
                .environmentObject(store)
                .environmentObject(signing)
        }
    }
}
