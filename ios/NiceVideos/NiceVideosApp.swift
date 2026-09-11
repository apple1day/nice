import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == VideoStore.sessionID else { completionHandler(); return }
        VideoStore.shared.backgroundCompletion = completionHandler
    }
}

@main
struct NiceVideosApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = VideoStore.shared
    var body: some Scene {
        WindowGroup { RootView().environmentObject(store) }
    }
}
