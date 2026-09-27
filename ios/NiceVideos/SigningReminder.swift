import Foundation

struct SigningReminderRequest: Equatable, Sendable {
    let identifier: String
    let fireDate: Date
    let expirationDate: Date
    let hoursBefore: Int
}

enum SigningReminderPlan {
    static let identifiers = ["nice.signing-expiry.48h", "nice.signing-expiry.24h"]

    static func requests(expiration: Date?, now: Date) -> [SigningReminderRequest] {
        guard let expiration, expiration.timeIntervalSince1970.isFinite else { return [] }
        return zip([48, 24], identifiers).compactMap { hours, identifier in
            let date = expiration.addingTimeInterval(-Double(hours) * 3600)
            // Do not replay missed reminders, or schedule notifications at expiry.
            guard date > now else { return nil }
            return SigningReminderRequest(identifier: identifier, fireDate: date,
                                          expirationDate: expiration, hoursBefore: hours)
        }
    }
}

enum SigningNotificationPermission: Equatable, Sendable {
    case notDetermined, denied, authorized, quiet, unavailable
    var allowsDelivery: Bool { self == .authorized || self == .quiet }
}

protocol SigningNotificationClient: Sendable {
    func permission() async -> SigningNotificationPermission
    func requestPermission() async throws
    func clear(identifiers: [String]) async
    func add(_ request: SigningReminderRequest) async throws -> Bool
}

struct SigningReminderReport: Equatable, Sendable {
    let permission: SigningNotificationPermission
    let scheduled: [SigningReminderRequest]
    let error: String?
}

/// Calls enter the queue synchronously on the main actor. Awaiting notification
/// permission/add must not allow an older enable operation to run AFTER disable.
/// Only our two namespaced requests are removed; other app notifications survive.
@MainActor
final class SigningReminderScheduler {
    private let client: any SigningNotificationClient
    private var tail: Task<SigningReminderReport, Never>?

    init(client: any SigningNotificationClient) { self.client = client }

    func synchronize(expiration: Date?, enabled: Bool, requestPermission: Bool = false,
                     now: @escaping @Sendable () -> Date = { Date() }) -> Task<SigningReminderReport, Never> {
        let previous = tail
        let client = client
        let task = Task { @MainActor in
            _ = await previous?.value
            var permission = await client.permission()
            var errorMessage: String?
            if enabled, expiration != nil, requestPermission, permission == .notDetermined {
                do { try await client.requestPermission() }
                catch { errorMessage = "无法申请通知权限，请稍后重试。" }
                permission = await client.permission()
            }
            await client.clear(identifiers: SigningReminderPlan.identifiers)
            let requests = enabled && permission.allowsDelivery
                ? SigningReminderPlan.requests(expiration: expiration, now: now()) : []
            var scheduled: [SigningReminderRequest] = []
            do {
                for request in requests {
                    guard request.fireDate > now() else { continue }
                    if try await client.add(request) { scheduled.append(request) }
                }
            } catch {
                await client.clear(identifiers: SigningReminderPlan.identifiers)
                scheduled = []
                errorMessage = "到期通知安排失败，App 内倒计时仍可查看，请点击重新检查。"
            }
            return SigningReminderReport(permission: permission, scheduled: scheduled, error: errorMessage)
        }
        tail = task
        return task
    }
}

#if canImport(UserNotifications)
import UserNotifications

/// UNUserNotificationCenter's asynchronous API is safe to call from this adapter.
/// All mutations are additionally serialized by SigningReminderScheduler.
final class SystemSigningNotificationClient: SigningNotificationClient, @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()

    func permission() async -> SigningNotificationPermission {
        switch (await center.notificationSettings()).authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .quiet
        #if os(iOS)
        case .ephemeral: return .quiet
        #endif
        @unknown default: return .unavailable
        }
    }

    func requestPermission() async throws {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
    }

    func clear(identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func add(_ request: SigningReminderRequest) async throws -> Bool {
        // A permission dialog/queue can take time. Never add a now-past trigger.
        guard request.fireDate > Date() else { return false }
        let content = UNMutableNotificationContent()
        content.title = "NiceVideos 签名即将到期"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
        content.body = "描述文件将于 \(formatter.string(from: request.expirationDate)) 到期（约 \(request.hoursBefore) 小时后）。请通过 Xcode 刷新签名并覆盖安装，不要卸载 App，以免删除本地视频。"
        content.sound = .default
        content.threadIdentifier = "nice.signing-expiry"
        // Pin to an absolute UTC date so travel and daylight saving do not move it.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                 from: request.fireDate)
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try await center.add(UNNotificationRequest(identifier: request.identifier,
                                                 content: content, trigger: trigger))
        return true
    }
}
#endif
