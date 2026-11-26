import SwiftUI
import AVFoundation
import QuickLookThumbnailing
import UniformTypeIdentifiers
import UIKit

@MainActor struct VRFolderTab: View {
    @StateObject private var library: VRFolderLibrary
    let onPlay: (PickedVideoFile, PlaybackStartMode) -> Void

    @State private var picker: PickerTarget?
    @State private var showsAfterglowSettings = false
    @State private var showsCopyCreator = false
    @State private var finishedCopy: PickedVideoFile?
    @State private var pendingVideo: (PickedVideoFile.Selection, PlaybackStartMode)?
    @State private var restored = false
    @State private var pendingRemoval: VRFolderRoot?
    @State private var openTask: Task<Void, Never>?
    @State private var openingID: String?
    @State private var playbackError: String?

    init(onPlay: @escaping (PickedVideoFile, PlaybackStartMode) -> Void) {
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
        case folder(UUID?), video(PlaybackStartMode)
        var id: String {
            switch self {
            case .folder(let id): return "folder-" + (id?.uuidString ?? "new")
            case .video(let mode): return mode == .afterglow ? "afterglowVideo" : "video"
            }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                afterglowActions
                Button {
                    cancelOpen()
                    showsCopyCreator = true
                } label: {
                    Label("制作兼容副本", systemImage: "film.stack")
                        .font(.subheadline).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.horizontal, 16)
                .accessibilityIdentifier("makeCompatibleCopy")
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
        .sheet(item: $picker, onDismiss: {
            if let (selection, mode) = pendingVideo {
                pendingVideo = nil
                open(selection, id: UUID().uuidString, startMode: mode)
            }
        }) { target in
            switch target {
            case .folder(let prior):
                VRDirectoryPicker { url in
                    if let url { library.authorize(url, replacing: prior) }
                    picker = nil
                }
            case .video(let mode):
                VideoDocumentPicker { selection in
                    if let selection { pendingVideo = (selection, mode) }
                    picker = nil
                }
            }
        }
        .sheet(isPresented: $showsAfterglowSettings) { AfterglowPresetView() }
        .sheet(isPresented: $showsCopyCreator, onDismiss: {
            if let file = finishedCopy {
                finishedCopy = nil
                onPlay(file, .afterglow)
            }
        }) {
            VRCompatibleCopySheet { file in
                finishedCopy = file
                showsCopyCreator = false
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

    private var afterglowActions: some View {
        HStack(spacing: 8) {
            Button {
                cancelOpen()
                picker = .video(.afterglow)
            } label: {
                Label("Afterglow XR 播放", systemImage: "eyeglasses")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityHint("选择一个视频并按预设直接播放")
            .accessibilityIdentifier("afterglowOpenVideo")
            Button { showsAfterglowSettings = true } label: {
                Label("预设", systemImage: "slider.horizontal.3").frame(minHeight: 44)
            }
            .accessibilityLabel("Afterglow XR 播放预设")
            .accessibilityIdentifier("afterglowOpenSettings")
        }
        .buttonStyle(.plain).padding(.horizontal, 16)
        .background(Self.panel, in: RoundedRectangle(cornerRadius: 14))
        .padding(.top, 12)
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                sourceCard("选择文件夹", detail: "浏览文件夹里的影片", icon: "folder.fill",
                           color: .cyan, id: "vrChooseFolderButton") { chooseFolder() }
                sourceCard("打开视频", detail: "从「文件」直接播放", icon: "play.rectangle.fill",
                           color: .mint, id: "vrOpenVideoButton") { cancelOpen(); picker = .video(.panorama) }
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
                HStack(spacing: 4) {
                    VRFolderEntryRow(entry: entry, isOpening: openingID == entry.id,
                                     lease: { try? library.selection(for: entry) }) {
                        if entry.isDirectory { cancelOpen(); library.enter(entry) }
                        else { play(entry, startMode: .panorama) }
                    }
                    if !entry.isDirectory {
                        Button { play(entry, startMode: .afterglow) } label: {
                            Image(systemName: "eyeglasses").frame(width: 44, height: 48)
                        }
                        .buttonStyle(.plain).foregroundStyle(.mint)
                        .accessibilityLabel("用 Afterglow XR 播放 " + entry.name)
                        .accessibilityIdentifier("afterglowEntry-" + entry.name)
                    }
                }
                Divider().overlay(.white.opacity(0.09))
            }
        }
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

    private func play(_ entry: VRFolderEntry, startMode: PlaybackStartMode) {
        do { open(try library.selection(for: entry), id: entry.id, startMode: startMode) }
        catch { playbackError = error.localizedDescription }
    }

    private func open(_ selection: PickedVideoFile.Selection, id: String, startMode: PlaybackStartMode) {
        cancelOpen()
        openingID = id
        openTask = Task { @MainActor in
            do {
                let file = try await PickedVideoFile.open(selection)
                try Task.checkCancellation()
                openingID = nil
                openTask = nil
                onPlay(file, startMode)
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

struct VRDirectoryPicker: UIViewControllerRepresentable {
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

@MainActor private struct VRFolderEntryRow: View {
    let entry: VRFolderEntry
    let isOpening: Bool
    let lease: () -> PickedVideoFile.Selection?
    let open: () -> Void

    private final class Details {
        var image: UIImage?
        var duration: String?
        var dimensions: String?
    }
    @State private var details: Details?
    private static let cache: NSCache<NSString, Details> = {
        let cache = NSCache<NSString, Details>()
        cache.countLimit = 250
        cache.totalCostLimit = 12 * 1024 * 1024
        return cache
    }()

    private var key: String {
        "\(entry.id)|\(entry.byteCount ?? -1)|\(entry.modifiedAt?.timeIntervalSinceReferenceDate ?? 0)"
    }
    private var metadata: String {
        if entry.isDirectory { return "文件夹" }
        var parts = [entry.url.pathExtension.uppercased()]
        if let dimensions = details?.dimensions { parts.append(dimensions) }
        if let bytes = entry.byteCount { parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 13) {
                poster.frame(width: 86, height: 54)
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.name).font(.subheadline.weight(.semibold)).lineLimit(2).truncationMode(.middle)
                    Text(metadata).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 2)
                if isOpening { ProgressView() }
                else { Image(systemName: entry.isDirectory ? "chevron.right" : "play.fill")
                    .font(.caption).foregroundStyle(.secondary).padding(.trailing, 4) }
            }
            .padding(.vertical, 8).contentShape(Rectangle())
        }
        .foregroundStyle(.white).buttonStyle(.plain)
        .accessibilityLabel([entry.name, metadata, details?.duration].compactMap { $0 }.joined(separator: "，"))
        .accessibilityHint(entry.isDirectory ? "浏览子文件夹" : "直接进入 VR 播放")
        .accessibilityIdentifier("vrEntry-" + entry.name)
        .task(id: key) { await loadDetails() }
    }

    private var poster: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.14))
            if entry.isDirectory {
                Image(systemName: "folder.fill").font(.title3).foregroundStyle(.cyan)
            } else if let image = details?.image {
                GeometryReader { geometry in
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
            } else {
                Image(systemName: "film").font(.title2.weight(.light)).foregroundStyle(.secondary)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let duration = details?.duration {
                Text(duration).font(.caption2.monospacedDigit().weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 3))
                    .padding(3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
    }

    private func loadDetails() async {
        details = nil
        guard !entry.isDirectory, entry.canThumbnail else { return }
        let name = key as NSString
        if let hit = Self.cache.object(forKey: name) { details = hit; return }
        guard !Task.isCancelled, let selection = lease() else { return }
        defer { withExtendedLifetime(selection) {} }
        let asset = AVURLAsset(url: selection.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 258, height: 162)
        let value = Details()
        await withTaskCancellationHandler {
            if let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 {
                value.duration = PlaybackPosition.label(duration.seconds)
            }
            if !Task.isCancelled, let tracks = try? await asset.loadTracks(withMediaType: .video), let track = tracks.first,
               let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                if rect.width >= 1 && rect.height >= 1, let width = Int(exactly: rect.width.rounded()),
                   let height = Int(exactly: rect.height.rounded()) {
                    value.dimensions = "\(width) × \(height)"
                }
            }
            if !Task.isCancelled, let frame = try? await generator.image(at: .zero) {
                value.image = UIImage(cgImage: frame.image)
            }
        } onCancel: {
            asset.cancelLoading()
            generator.cancelAllCGImageGeneration()
        }
        // A provider can have its own preview even when AVFoundation cannot
        // decode the source. Unmaterialized cloud files never reach this path.
        if value.image == nil, !Task.isCancelled {
            let request = QLThumbnailGenerator.Request(fileAt: selection.url, size: CGSize(width: 86, height: 54),
                                                       scale: UIScreen.main.scale, representationTypes: .thumbnail)
            let thumbnails = QLThumbnailGenerator.shared
            value.image = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    thumbnails.generateBestRepresentation(for: request) { item, _ in
                        continuation.resume(returning: item?.uiImage)
                    }
                }
            } onCancel: { thumbnails.cancel(request) }
        }
        guard !Task.isCancelled, value.image != nil || value.dimensions != nil || value.duration != nil else { return }
        let cost: Int
        if let image = value.image?.cgImage { cost = image.bytesPerRow * image.height }
        else { cost = 1 }
        Self.cache.setObject(value, forKey: name, cost: cost)
        details = value
    }
}
