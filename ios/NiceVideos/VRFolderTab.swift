import SwiftUI
import AVFoundation
import QuickLookThumbnailing
import UniformTypeIdentifiers
import UIKit

@MainActor struct VRFolderTab: View {
    @StateObject private var library: VRFolderLibrary
    let onPlay: (PickedVideoFile) -> Void

    @State private var picker: PickerTarget?
    @State private var restored = false
    @State private var pendingRemoval: VRFolderRoot?
    @State private var openTask: Task<Void, Never>?
    @State private var openingID: String?
    @State private var playbackError: String?

    init(onPlay: @escaping (PickedVideoFile) -> Void) {
        self.onPlay = onPlay
        #if DEBUG
        _library = StateObject(wrappedValue: VRFolderLibrary(defaults: VRFolderUITestFixture.isolatedDefaults ?? .standard))
        #else
        _library = StateObject(wrappedValue: VRFolderLibrary())
        #endif
    }

    private static let background = Color(red: 0.045, green: 0.047, blue: 0.058)
    private static let panel = Color(red: 0.095, green: 0.100, blue: 0.117)
    private enum PickerTarget: Identifiable {
        case folder(UUID?), video
        var id: String {
            switch self {
            case .folder(let id): return "folder-" + (id?.uuidString ?? "new")
            case .video: return "video"
            }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if library.currentRoot == nil { sources }
                if library.currentRoot != nil { folderHeader }
                if let message = library.errorMessage {
                    folderError(message)
                } else if library.isLoading {
                    HStack { Spacer(); ProgressView("正在读取文件夹…"); Spacer() }
                        .padding(.vertical, 50)
                } else if library.currentRoot != nil {
                    folderContents
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 22)
        }
        .background(Self.background.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .navigationTitle(library.currentRoot == nil ? "VR 片库" : library.path.last ?? library.currentRoot?.name ?? "VR 片库")
        .navigationBarTitleDisplayMode(library.currentRoot == nil ? .large : .inline)
        .toolbarBackground(Self.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if let root = library.currentRoot {
                ToolbarItem(placement: .topBarLeading) {
                    Button { cancelOpen(); library.back() } label: {
                        Label("上一级", systemImage: "chevron.backward")
                    }
                    .accessibilityIdentifier("vrFolderBackButton")
                }
                ToolbarItem(placement: .topBarTrailing) { folderMenu(root) }
            }
        }
        .sheet(item: $picker) { target in
            switch target {
            case .folder(let prior):
                VRDirectoryPicker { url in
                    if let url { library.authorize(url, replacing: prior) }
                    picker = nil
                }
            case .video:
                VideoDocumentPicker { selection in
                    picker = nil
                    if let selection { open(selection, id: UUID().uuidString) }
                }
            }
        }
        .alert("无法打开视频", isPresented: Binding(get: { playbackError != nil },
                                               set: { if !$0 { playbackError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(playbackError ?? "") }
        .confirmationDialog("从 VR 片库移除这个文件夹？", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible, presenting: pendingRemoval) { root in
            Button("移除文件夹记录", role: .destructive) {
                cancelOpen(); library.forget(root); pendingRemoval = nil
            }
            Button("取消", role: .cancel) {}
        } message: { root in Text("原文件仍保存在「文件」的 \(root.name) 中。") }
        .task {
            guard !restored else { return }
            restored = true
            library.restoreLastSelection()
        }
        .onDisappear { cancelOpen() }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                sourceCard("选择文件夹", detail: "浏览文件夹里的影片", icon: "folder.fill",
                           color: .cyan, id: "vrChooseFolderButton") { chooseFolder() }
                sourceCard("打开视频", detail: "从「文件」直接播放", icon: "play.rectangle.fill",
                           color: .mint, id: "vrOpenVideoButton") { cancelOpen(); picker = .video }
            }
            if !library.roots.isEmpty {
                Text("我的文件夹").font(.title3.bold()).padding(.top, 12)
                ForEach(library.roots) { root in
                    HStack(spacing: 0) {
                        Button {
                            cancelOpen(); library.select(root)
                        } label: {
                            HStack(spacing: 13) {
                                Image(systemName: "folder.fill").font(.title3).foregroundStyle(.cyan)
                                Text(root.name).font(.body.weight(.medium)).lineLimit(2)
                                Spacer()
                            }
                            .padding(.leading, 16).frame(minHeight: 62).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityIdentifier("vrRoot-" + root.name)
                        Menu {
                            Button("重新选择文件夹") { chooseFolder(replacing: root.id) }
                            Button("移除文件夹记录", role: .destructive) { pendingRemoval = root }
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 48, height: 50)
                        }
                        .accessibilityLabel("管理\(root.name)")
                    }
                    .background(Self.panel, in: RoundedRectangle(cornerRadius: 12))
                }
            } else if !library.isLoading && library.errorMessage == nil {
                Text("选择一次文件夹，以后在这里点影片就能进入 VR 播放。")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.white)
        .padding(.top, 12)
    }

    private func sourceCard(_ title: String, detail: String, icon: String, color: Color,
                            id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: icon).font(.title2.weight(.medium)).foregroundStyle(color)
                    .padding(.bottom, 8)
                Text(title).font(.headline).foregroundStyle(.white)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).background(Self.panel, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier(id)
    }

    private var folderHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let root = library.currentRoot {
                Text(([root.name] + library.path).joined(separator: "  ›  "))
                    .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
            }
            if !library.isLoading && library.errorMessage == nil {
                let videos = library.entries.lazy.filter { !$0.isDirectory }.count
                let folders = library.entries.count - videos
                Text(folders > 0 ? "\(videos) 部视频 · \(folders) 个子文件夹" : "\(videos) 部视频")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 10).padding(.bottom, 14)
    }

    @ViewBuilder private var folderContents: some View {
        if library.entries.isEmpty {
            ContentUnavailableView("这个文件夹里没有视频", systemImage: "film.stack",
                                   description: Text("可以从上一级选择其他文件夹。"))
        } else {
            ForEach(library.entries) { entry in
                Button {
                    if entry.isDirectory { cancelOpen(); library.enter(entry) }
                    else {
                        do { open(try library.selection(for: entry), id: entry.id) }
                        catch { playbackError = error.localizedDescription }
                    }
                } label: {
                    HStack(spacing: 13) {
                        if entry.isDirectory {
                            RoundedRectangle(cornerRadius: 8).fill(Self.panel)
                                .overlay { Image(systemName: "folder.fill").foregroundStyle(.cyan).font(.title3) }
                                .frame(width: 86, height: 54)
                        } else {
                            VRFolderVideoPoster(entry: entry) { try? library.selection(for: entry) }
                                .frame(width: 86, height: 54)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.name).font(.subheadline.weight(.semibold))
                                .lineLimit(2).truncationMode(.middle)
                            Text(metadata(entry)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 2)
                        if openingID == entry.id { ProgressView() }
                        else { Image(systemName: entry.isDirectory ? "chevron.right" : "play.fill")
                            .font(.caption).foregroundStyle(.secondary).padding(.trailing, 4) }
                    }
                    .padding(.vertical, 8).contentShape(Rectangle())
                }
                .foregroundStyle(.white).buttonStyle(.plain)
                .accessibilityLabel(entry.name + "，" + metadata(entry))
                .accessibilityHint(entry.isDirectory ? "浏览子文件夹" : "直接进入 VR 播放")
                .accessibilityIdentifier("vrEntry-" + entry.name)
                Divider().overlay(.white.opacity(0.09))
            }
        }
    }

    private func metadata(_ entry: VRFolderEntry) -> String {
        if entry.isDirectory { return "文件夹" }
        var parts = [entry.url.pathExtension.uppercased()]
        if let size = entry.byteCount { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func folderMenu(_ root: VRFolderRoot) -> some View {
        Menu {
            Button("刷新", systemImage: "arrow.clockwise") { cancelOpen(); library.refresh() }
            Button("更换文件夹", systemImage: "folder") { chooseFolder(replacing: root.id) }
                .accessibilityIdentifier("vrReplaceFolder")
            Button("返回片库", systemImage: "rectangle.grid.2x2") { cancelOpen(); library.showRoots() }
        } label: { Image(systemName: "ellipsis.circle") }
        .accessibilityLabel("文件夹操作").accessibilityIdentifier("vrFolderActions")
    }

    private func folderError(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("读取文件夹失败", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
            if library.needsReauthorization || library.currentRoot == nil {
                Button("重新选择文件夹") { chooseFolder(replacing: library.currentRoot?.id) }
            } else {
                Button("重试") { library.refresh() }
            }
        }.padding(.vertical, 20)
    }

    private func chooseFolder(replacing prior: UUID? = nil) {
        cancelOpen()
        #if DEBUG
        if VRFolderUITestFixture.chooseIfRequested(in: library, replacing: prior) { return }
        #endif
        picker = .folder(prior)
    }

    private func open(_ selection: PickedVideoFile.Selection, id: String) {
        cancelOpen()
        openingID = id
        openTask = Task { @MainActor in
            do {
                let file = try await PickedVideoFile.open(selection)
                try Task.checkCancellation()
                openingID = nil
                openTask = nil
                onPlay(file)
            } catch {
                guard !Task.isCancelled else { return }
                openingID = nil
                openTask = nil
                playbackError = error.localizedDescription
            }
        }
    }

    private func cancelOpen() {
        openTask?.cancel()
        openTask = nil
        openingID = nil
    }
}

private struct VRDirectoryPicker: UIViewControllerRepresentable {
    let onPick: (URL?) -> Void
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let finish: (URL?) -> Void
        init(_ finish: @escaping (URL?) -> Void) { self.finish = finish }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(urls.first)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(nil) }
    }
    func makeCoordinator() -> Coordinator { Coordinator(onPick) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}

@MainActor private struct VRFolderVideoPoster: View {
    let entry: VRFolderEntry
    let lease: () -> PickedVideoFile.Selection?
    @State private var poster: UIImage?
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 12 * 1024 * 1024
        return cache
    }()
    private var key: String {
        "\(entry.id)|\(entry.byteCount ?? -1)|\(entry.modifiedAt?.timeIntervalSinceReferenceDate ?? 0)"
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.14))
            if let poster {
                GeometryReader { geometry in
                    Image(uiImage: poster).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
            } else {
                Image(systemName: "film").font(.title2.weight(.light)).foregroundStyle(.secondary)
            }
        }.clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
        .task(id: key) {
            poster = nil
            guard entry.canThumbnail else { return }
            let name = key as NSString
            if let hit = Self.cache.object(forKey: name) { poster = hit; return }
            guard !Task.isCancelled, let selection = lease() else { return }
            // Decode a small poster only for files the provider reports as local.
            // Keep the folder grant alive until the asynchronous request has finished.
            defer { withExtendedLifetime(selection) {} }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: selection.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 258, height: 162)
            var result: UIImage?
            do {
                let frame = try await withTaskCancellationHandler {
                    try await generator.image(at: .zero)
                } onCancel: { generator.cancelAllCGImageGeneration() }
                result = UIImage(cgImage: frame.image)
            } catch {
                guard !Task.isCancelled else { return }
                let request = QLThumbnailGenerator.Request(fileAt: selection.url, size: CGSize(width: 86, height: 54),
                                                           scale: UIScreen.main.scale, representationTypes: .thumbnail)
                let thumbnails = QLThumbnailGenerator.shared
                result = await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        thumbnails.generateBestRepresentation(for: request) { item, _ in
                            continuation.resume(returning: item?.uiImage)
                        }
                    }
                } onCancel: { thumbnails.cancel(request) }
            }
            guard !Task.isCancelled, let result else { return }
            if let cg = result.cgImage { Self.cache.setObject(result, forKey: name, cost: cg.bytesPerRow * cg.height) }
            poster = result
        }
    }
}
