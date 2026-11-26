import SwiftUI
import UIKit

@MainActor struct VRCompatibleCopySheet: View {
    let onPlay: (PickedVideoFile) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var picker: Picker?
    @State private var source: PickedVideoFile.Selection?
    @State private var folder: PickedVideoFile.Selection?
    @State private var output: URL?
    @State private var work: Task<Void, Never>?
    @State private var progress = 0.0
    @State private var opening = false
    @State private var stopping = false
    @State private var status: String?
    @State private var cleanupTime: UIBackgroundTaskIdentifier = .invalid

    private enum Picker: Int, Identifiable {
        case source, folder
        var id: Int { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    choice("选择原视频", value: source?.url.lastPathComponent, icon: "film",
                           identifier: "compatibleCopySource") { picker = .source }
                    choice("选择保存文件夹", value: folder?.url.lastPathComponent, icon: "folder",
                           identifier: "compatibleCopyDestination") { picker = .folder }
                } footer: {
                    Text("8192 × 4096 左右分屏影片将转换为整幅 1920 × 960 的 H.264 MP4，目标 30 fps。两眼排布保留，原片有声音时输出 AAC。")
                }
                Section {
                    if let output {
                        LabeledContent("已保存", value: output.lastPathComponent)
                            .accessibilityIdentifier("compatibleCopySaved")
                        Button("用 Afterglow XR 播放", systemImage: "eyeglasses") { play(output) }
                            .disabled(work != nil).accessibilityIdentifier("playGeneratedCopy")
                    } else if work == nil {
                        Button("开始制作", systemImage: "play.fill") { start() }
                            .disabled(source == nil || folder == nil || scenePhase != .active)
                            .accessibilityIdentifier("startCompatibleCopy")
                    } else if !opening {
                        ProgressView(value: progress) {
                            Text(stopping ? "正在取消…" : "正在制作…")
                        } currentValueLabel: {
                            Text(progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                        }
                        Button("取消制作", role: .cancel) { cancel("已取消制作。") }
                            .disabled(stopping)
                    }
                    if opening { ProgressView("正在打开副本…") }
                    if let status { Text(status).font(.subheadline).accessibilityIdentifier("compatibleCopyStatus") }
                } footer: {
                    if output == nil {
                        Text("制作时请保持 App 在前台。副本预计每分钟约 46 MB。设备需要临时空间，跨卷保存时还需在目标位置留出副本空间。")
                    }
                }
            }
            .navigationTitle("制作兼容副本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.disabled(work != nil)
                        .accessibilityIdentifier("closeCompatibleCopy")
                }
            }
        }
        .interactiveDismissDisabled(work != nil)
        .sheet(item: $picker) { target in
            switch target {
            case .source:
                VideoDocumentPicker { selection in
                    if let selection { source = selection; resetResult() }
                    picker = nil
                }
            case .folder:
                VRDirectoryPicker { url in
                    if let url { folder = PickedVideoFile.Selection(url); resetResult() }
                    picker = nil
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background, work != nil else { return }
            if cleanupTime == .invalid {
                cleanupTime = UIApplication.shared.beginBackgroundTask(withName: "Finish compatible copy cleanup") {
                    Task { @MainActor in endCleanupTime() }
                }
            }
            cancel(opening ? "已暂停打开副本。" : "App 已转入后台，制作已取消。")
        }
        .onDisappear { work?.cancel() }
    }

    private func choice(_ label: String, value: String?, icon: String, identifier: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(label, systemImage: icon)
                Spacer()
                if let value { Text(value).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary) }
            }
        }
        .accessibilityIdentifier(identifier).disabled(work != nil)
    }

    private func resetResult() {
        status = nil
        output = nil
        progress = 0
    }

    private func start() {
        guard work == nil, let source, let folder, scenePhase == .active else { return }
        resetResult()
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        let destination = folder.url.appendingPathComponent("NiceVR-compat-\(token).mp4")
        work = Task { @MainActor in
            let oldIdleTimer = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            defer {
                UIApplication.shared.isIdleTimerDisabled = oldIdleTimer
                finishWork()
                withExtendedLifetime(folder) {}
            }
            do {
                let input = try await PickedVideoFile.open(source)
                try Task.checkCancellation()
                let saved = try await VRCompatibleCopy.generate(fileURL: input.url, pickedFile: input,
                    destination: destination) { value in
                    if value.isFinite { progress = min(1, max(0, value)) }
                }
                // Publication may have completed just before a cancellation.
                // Show that saved result even if the app has since backgrounded.
                output = saved
                progress = 1
                status = nil
            } catch {
                if !Task.isCancelled { status = error.localizedDescription }
            }
        }
    }

    private func play(_ url: URL) {
        guard work == nil, let folder, scenePhase == .active else { return }
        opening = true
        status = nil
        work = Task { @MainActor in
            defer { finishWork() }
            do {
                let selection = PickedVideoFile.Selection(url, inheriting: folder)
                let file = try await PickedVideoFile.open(selection)
                try Task.checkCancellation()
                onPlay(file)
            } catch {
                if !Task.isCancelled { status = "副本已保存。打开失败：\(error.localizedDescription)" }
            }
        }
    }

    private func cancel(_ reason: String) {
        guard work != nil else { return }
        stopping = true
        status = reason
        work?.cancel()
    }

    private func finishWork() {
        work = nil
        opening = false
        stopping = false
        endCleanupTime()
    }

    private func endCleanupTime() {
        if cleanupTime != .invalid {
            UIApplication.shared.endBackgroundTask(cleanupTime)
            cleanupTime = .invalid
        }
    }
}
