import SwiftUI
import UniformTypeIdentifiers

private struct UploadDestination: Identifiable {
    let id = UUID()
    let server: URL
    let allowsCellular: Bool
}

struct LocalUploadView: View {
    let store: VideoStore
    @StateObject private var uploads = LocalUploadManager.shared
    @AppStorage("allowUploadCellular") private var allowCellular = false
    @State private var destination: UploadDestination?
    @State private var choosingFiles = false
    @State private var fileDestination: UploadDestination?
    @State private var inspection: Task<Void, Never>?
    @State private var picked: [LocalUploadSource] = []

    var body: some View {
        List {
            Section {
                Button {
                    guard let target = uploadDestination() else { return }
                    fileDestination = target
                    choosingFiles = true
                } label: {
                    Label("从「文件」选择视频", systemImage: "folder")
                }
                .disabled(inspection != nil || !picked.isEmpty)
                .accessibilityIdentifier("chooseFilesToUploadButton")
                Button {
                    destination = uploadDestination()
                } label: {
                    Label("从已下载视频选择", systemImage: "arrow.down.circle")
                }
                .disabled(inspection != nil || !picked.isEmpty)
                .accessibilityIdentifier("chooseVideosToUploadButton")
                Text("支持多选 MP4、MOV、MKV 等视频。大视频请保持 App 在前台，上传中断后需要从头重试。")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("允许新上传使用蜂窝数据", isOn: $allowCellular)
                Text("默认关闭。任务会固定使用确认时的服务器地址和网络设置；单个视频上限 20 GiB。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if inspection != nil {
                Section {
                    ProgressView("正在读取所选文件信息…")
                    Button("取消选择", role: .cancel) { discardFileSelection() }
                }
            } else if !picked.isEmpty, let target = fileDestination {
                Section("待上传的文件（\(picked.count)）") {
                    LabeledContent("上传到", value: target.server.absoluteString)
                    ForEach(picked, id: \.id) { source in
                        LabeledContent {
                            Text(ByteCountFormatter.string(fromByteCount: source.size, countStyle: .file))
                        } label: {
                            Text(source.name).lineLimit(2)
                        }
                    }
                    Button("确认上传到服务器") {
                        if uploads.enqueue(picked, server: target.server, allowsCellular: allowCellular) {
                            discardFileSelection()
                        }
                    }
                    .accessibilityIdentifier("confirmFilesUploadButton")
                    Button("取消选择", role: .cancel) { discardFileSelection() }
                }
            } else if uploads.jobs.isEmpty {
                ContentUnavailableView("暂无上传任务", systemImage: "arrow.up.circle")
            }
            ForEach(uploads.jobs.reversed()) { job in
                VStack(alignment: .leading, spacing: 8) {
                    Text(job.source.name).font(.headline).lineLimit(2)
                    Text(job.server.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    HStack {
                        Text(job.state.label)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: job.source.size, countStyle: .file))
                    }.font(.caption)
                    if job.state == .uploading {
                        UploadByteProgress(progress: uploads.progress, id: job.id)
                    }
                    if let message = job.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    if job.state.isPending {
                        Button("取消上传", role: .destructive) { uploads.cancel(job.id) }
                    } else if job.state != .completed {
                        Button("重新上传") { uploads.retry(job.id) }
                    }
                }.padding(.vertical, 4).buttonStyle(.borderless)
                    .accessibilityIdentifier("uploadJob.\(job.id.uuidString)")
            }
        }
        .navigationTitle("上传视频")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("清理记录") { uploads.clearFinished() }
                    .disabled(!uploads.jobs.contains { !$0.state.isPending })
            }
        }
        // Some file providers advertise MKV and WebM as generic data. The upload
        // service validates every selected file against the server's supported formats.
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.data],
                      allowsMultipleSelection: true, onCompletion: receiveFiles)
        .sheet(item: $destination) { value in
            UploadVideoPicker(store: store, destination: value) { sources in
                uploads.enqueue(sources, server: value.server, allowsCellular: value.allowsCellular)
            }
        }
        .alert("上传提示", isPresented: Binding(
            get: { uploads.errorMessage != nil }, set: { if !$0 { uploads.errorMessage = nil } }
        )) { Button("确定", role: .cancel) { uploads.errorMessage = nil } }
        message: { Text(uploads.errorMessage ?? "") }
    }
    private func uploadDestination() -> UploadDestination? {
        do {
            return UploadDestination(server: try ServerAddress.normalize(store.server), allowsCellular: allowCellular)
        } catch {
            uploads.errorMessage = "请先在「设置」配置上传目标服务器。\n\(error.localizedDescription)"
            return nil
        }
    }

    private func receiveFiles(_ result: Result<[URL], Error>) {
        guard let target = fileDestination else { return }
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { discardFileSelection(); return }
            inspection = Task { @MainActor in
                do {
                    let sources = try await LocalUploadSource.pickedFiles(urls)
                    guard !Task.isCancelled, fileDestination?.id == target.id else { return }
                    picked = sources
                } catch {
                    guard !Task.isCancelled, fileDestination?.id == target.id else { return }
                    fileDestination = nil
                    uploads.errorMessage = error.localizedDescription
                }
                inspection = nil
            }
        case .failure(let error):
            discardFileSelection()
            let nsError = error as NSError
            if nsError.domain != NSCocoaErrorDomain || nsError.code != NSUserCancelledError {
                uploads.errorMessage = error.localizedDescription
            }
        }
    }

    private func discardFileSelection() {
        inspection?.cancel()
        inspection = nil
        fileDestination = nil
        picked = []
    }
}

private struct UploadByteProgress: View {
    @ObservedObject var progress: LocalUploadProgress
    let id: UUID
    var body: some View {
        let fraction = progress.fractions[id] ?? 0
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: fraction)
            Text(fraction >= 1 ? "已发送，等待服务器确认…" : "已发送 \(Int(fraction * 100))%")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

private struct UploadVideoPicker: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var library: LocalLibraryModel
    let destination: UploadDestination
    let upload: ([LocalUploadSource]) -> Bool
    @State private var search = ""
    @State private var tokens = Set<String>()
    @State private var confirmed: [LocalUploadSource] = []
    @State private var confirm = false
    @State private var failedToQueue = false

    init(store: VideoStore, destination: UploadDestination, upload: @escaping ([LocalUploadSource]) -> Bool) {
        _library = StateObject(wrappedValue: LocalLibraryModel(store: store, includeMissing: false))
        self.destination = destination
        self.upload = upload
    }
    var body: some View {
        NavigationStack {
            List {
                Section("上传目标") {
                    Text(destination.server.absoluteString).textSelection(.enabled)
                    Text("手机文件保留；服务器同名项目跳过，不自动覆盖。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(library.visibleRows) { row in
                    Button {
                        if tokens.contains(row.record.taskToken) { tokens.remove(row.record.taskToken) }
                        else { tokens.insert(row.record.taskToken) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: tokens.contains(row.record.taskToken) ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.record.video.name).foregroundStyle(.primary).lineLimit(2)
                                Text(row.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityValue(tokens.contains(row.record.taskToken) ? "已选择" : "未选择")
                }
                if library.visibleRows.isEmpty { Text("没有可上传的本地视频。") }
            }
            .navigationTitle("选择上传视频")
            .searchable(text: $search, prompt: "搜索本地视频")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(tokens.count == library.visibleTokens.count && !tokens.isEmpty ? "取消全选" : "全选") {
                        let visible = Set(library.visibleTokens)
                        tokens = tokens == visible ? [] : visible
                    }.disabled(library.visibleRows.isEmpty)
                    Button("上传（\(tokens.count)）") {
                        confirmed = library.visibleRows.filter { tokens.contains($0.record.taskToken) }.map {
                            LocalUploadSource(id: $0.id, taskToken: $0.record.taskToken,
                                              name: $0.record.video.name, size: $0.record.video.size)
                        }
                        confirm = true
                    }.disabled(tokens.isEmpty || library.restoring)
                        .accessibilityIdentifier("confirmSelectedUploadsButton")
                }
            }
            .onChange(of: search) { _, value in library.setSearch(value) }
            .onChange(of: library.visibleTokens) { _, visible in tokens.formIntersection(Set(visible)) }
            .confirmationDialog("上传这 \(confirmed.count) 个视频？", isPresented: $confirm, titleVisibility: .visible) {
                Button("确认上传到服务器") {
                    if upload(confirmed) { dismiss() } else { failedToQueue = true }
                }
                Button("取消", role: .cancel) { confirmed = [] }
            } message: {
                Text("目标：\(destination.server.absoluteString)\n按顺序上传完整文件，手机副本不会删除。")
            }
            .alert("未能加入上传队列", isPresented: $failedToQueue) {
                Button("确定", role: .cancel) { dismiss() }
            } message: { Text("请返回上传页面查看错误信息。") }
        }
    }
}
