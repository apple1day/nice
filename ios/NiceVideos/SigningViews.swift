import SwiftUI
import UIKit

private extension SigningUrgency {
    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .orange
        case .urgent, .expired: return .red
        }
    }
    var icon: String {
        switch self {
        case .normal: return "checkmark.shield"
        case .warning, .urgent: return "exclamationmark.shield"
        case .expired: return "xmark.shield"
        }
    }
}

/// Only these small views tick. No @Published per-second clock, root invalidation,
/// store subscription or media validation is introduced by signing status.
@MainActor
struct SigningStatusCard: View {
    let status: SigningStatus
    let now: Date

    var body: some View {
        switch status {
        case .loading:
            ProgressView("正在读取签名信息…")
        case let .unavailable(reason):
            Label("无法确定签名到期时间", systemImage: "questionmark.shield")
                .font(.headline)
            Text(reason).font(.footnote).foregroundStyle(.secondary)
        case let .available(profile):
            let urgency = SigningUrgency.resolve(expiration: profile.expirationDate, now: now)
            VStack(alignment: .leading, spacing: 8) {
                Label(urgency == .expired ? "描述文件已到期" : "签名剩余时间", systemImage: urgency.icon)
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(SigningCountdown.text(expiration: profile.expirationDate, now: now))
                    .font(.title2.bold()).monospacedDigit().foregroundStyle(urgency.color)
                Text("到期时间：\(profile.expirationDate.formatted(date: .numeric, time: .shortened))")
                    .font(.footnote).textSelection(.enabled)
                Text("时区：\(TimeZone.current.identifier)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            Text("请在到期前通过 Xcode 刷新签名并覆盖安装。不要先卸载 App，以免删除本地视频。")
                .font(.footnote).foregroundStyle(urgency == .normal ? Color.secondary : urgency.color)
        }
    }
}

@MainActor
struct SigningStatusSection: View {
    @EnvironmentObject private var signing: SigningStatusModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                SigningStatusCard(status: signing.status, now: context.date)
            }
            Toggle("到期前提醒", isOn: Binding(
                get: { signing.reminderEnabled }, set: { signing.setReminderEnabled($0) }
            ))
            .disabled(signing.status.expirationDate == nil && !signing.reminderEnabled)
            if signing.isUpdatingReminders {
                ProgressView("正在更新提醒…").font(.footnote)
            } else {
                Text(reminderDescription).font(.footnote).foregroundStyle(.secondary)
            }
            if signing.reminderEnabled && signing.report?.permission == .denied {
                Button("前往系统设置开启通知") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            if signing.reminderEnabled && signing.report?.permission == .notDetermined {
                Button("允许到期通知") { signing.setReminderEnabled(true) }
            }
            if let error = signing.report?.error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Button("重新检查签名与提醒") { signing.activate(forceReload: true) }
                .disabled(signing.isReading || signing.isUpdatingReminders)
            #if DEBUG
            NavigationLink("查看提醒样式（演示）") { SigningPreviewGallery() }
            #endif
        } header: {
            Text("签名有效期")
        } footer: {
            Text("依据当前安装包的描述文件到期时间和手机时间计算，不按安装日期推算。证书被撤销等情况可能提前影响使用；这里不是系统签名有效性验证，也不会自动续签。")
        }
    }

    private var reminderDescription: String {
        guard signing.reminderEnabled else { return "开启后，在到期前 48 小时、24 小时提醒。无需连接视频服务器。" }
        guard signing.status.expirationDate != nil else { return "无法确定到期时间，未安排通知，旧提醒已清理。" }
        guard let report = signing.report else { return "正在检查通知权限。" }
        switch report.permission {
        case .denied: return "系统通知权限已关闭；App 内倒计时仍可查看。"
        case .notDetermined: return "尚未获得通知权限。请点击“允许到期通知”。"
        case .unavailable: return "当前无法使用系统通知；请查看 App 内提示。"
        case .authorized, .quiet:
            guard !report.scheduled.isEmpty else {
                return "没有待发送的提醒：提醒时间可能已过，请根据到期时间及时刷新签名。"
            }
            let times = report.scheduled.map { $0.fireDate.formatted(date: .numeric, time: .shortened) }
                .joined(separator: "、")
            let note = report.permission == .quiet ? "（静默授权）" : ""
            return "已安排 \(report.scheduled.count) 次提醒\(note)：\(times)。实际展示受系统通知和专注模式设置影响。"
        }
    }
}

@MainActor
struct SigningExpiryBanner: View {
    @EnvironmentObject private var signing: SigningStatusModel
    @State private var showDetails = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let expiration = signing.status.expirationDate {
                let urgency = SigningUrgency.resolve(expiration: expiration, now: context.date)
                if urgency != .normal {
                    Button { showDetails = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: urgency.icon)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(urgency == .expired ? "签名描述文件已到期" : "签名剩余 \(SigningCountdown.text(expiration: expiration, now: context.date))")
                                    .font(.subheadline.bold())
                                Text("请及时覆盖安装刷新签名，不要卸载 App")
                                    .font(.caption)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        .foregroundStyle(urgency.color)
                        .padding(12)
                        .background(urgency.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .accessibilityHint("查看签名到期时间和通知设置")
                }
            }
        }
        .sheet(isPresented: $showDetails) {
            NavigationStack {
                Form { SigningStatusSection() }
                    .navigationTitle("签名有效期")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showDetails = false }
                        }
                    }
            }
            .environmentObject(signing)
        }
    }
}

/// Owns lifecycle observation in a zero-size child, not the video list/player.
@MainActor
struct SigningLifecycleView: View {
    @EnvironmentObject private var signing: SigningStatusModel
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .task { signing.activate() }
            .onChange(of: phase) { _, value in
                if value == .active { signing.activate() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                signing.activate()
            }
            .accessibilityHidden(true)
    }
}

#if DEBUG
/// Deliberately read-only samples. No model, persisted preference, fake production
/// expiry, or scheduled notification is changed by opening this screen.
@MainActor
private struct SigningPreviewGallery: View {
    private let now = Date()
    var body: some View {
        Form {
            Section {
                Text("以下全部为演示数据，不代表当前安装版的签名。此页面不发送通知，也不修改签名。")
            }
            ForEach([126, 30, 6, 0], id: \.self) { hours in
                Section(hours > 48 ? "正常" : (hours > 24 ? "临近到期" : (hours > 0 ? "不足一天" : "已到期"))) {
                    SigningStatusCard(status: .available(SigningProfile(
                        expirationDate: now.addingTimeInterval(Double(hours) * 3600),
                        creationDate: nil, identifier: nil)), now: now)
                }
            }
            Section("无法读取") {
                SigningStatusCard(status: .unavailable("演示：未找到签名描述文件。"), now: now)
            }
        }
        .navigationTitle("提醒样式（演示）")
    }
}
#endif
