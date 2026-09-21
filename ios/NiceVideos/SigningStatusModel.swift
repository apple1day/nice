import Foundation
import Combine

@MainActor
final class SigningStatusModel: ObservableObject {
    @Published private(set) var status: SigningStatus = .loading
    @Published private(set) var reminderEnabled: Bool
    @Published private(set) var report: SigningReminderReport?
    @Published private(set) var isReading = false
    @Published private(set) var isUpdatingReminders = false

    private static let preferenceKey = "signing.expiryReminder.enabled"
    private let defaults: UserDefaults
    private let scheduler: SigningReminderScheduler
    private let readProfile: @Sendable () -> SigningStatus
    private var loaded = false
    private var revision = 0

    init(defaults: UserDefaults = .standard,
         client: any SigningNotificationClient = SystemSigningNotificationClient(),
         readProfile: @escaping @Sendable () -> SigningStatus = { SigningProfileReader.readInstalledProfile() }) {
        self.defaults = defaults
        self.scheduler = SigningReminderScheduler(client: client)
        self.readProfile = readProfile
        reminderEnabled = defaults.bool(forKey: Self.preferenceKey)
    }

    /// Read one small bundle file once per launch, never the video directory.
    /// Returning to the foreground refreshes permissions/reminders, not media.
    func activate(forceReload: Bool = false) {
        guard !isReading else { return }
        if loaded && !forceReload {
            synchronizeReminders()
            return
        }
        isReading = true
        let reader = readProfile
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { reader() }.value
            guard let self else { return }
            self.status = result
            self.loaded = true
            self.isReading = false
            self.synchronizeReminders()
        }
    }

    func setReminderEnabled(_ enabled: Bool) {
        reminderEnabled = enabled
        defaults.set(enabled, forKey: Self.preferenceKey)
        // Only this explicit user action can ask for notification permission.
        synchronizeReminders(requestPermission: enabled)
    }

    private func synchronizeReminders(requestPermission: Bool = false) {
        guard loaded else { return }
        revision += 1
        let currentRevision = revision
        isUpdatingReminders = true
        let task = scheduler.synchronize(expiration: status.expirationDate, enabled: reminderEnabled,
                                         requestPermission: requestPermission)
        Task { [weak self] in
            let result = await task.value
            guard let self, self.revision == currentRevision else { return }
            self.report = result
            self.isUpdatingReminders = false
        }
    }
}
