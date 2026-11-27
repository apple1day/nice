import SwiftUI
import Combine

// Presentation changes are infrequent. Download progress must not invalidate the
// entire tab hierarchy. File availability is refreshed separately on activation.
private final class LibraryPresentationModel: ObservableObject {
    @Published private(set) var playback: PlaybackRequest?
    @Published private(set) var errorMessage: String?
    private var subscriptions = Set<AnyCancellable>()
    init(store: VideoStore) {
        store.$playback.removeDuplicates { $0?.id == $1?.id }
            .sink { [weak self] in self?.playback = $0 }.store(in: &subscriptions)
        store.$errorMessage.removeDuplicates()
            .sink { [weak self] in self?.errorMessage = $0 }.store(in: &subscriptions)
    }
}

struct LibraryRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    let store: VideoStore
    @StateObject private var presentation: LibraryPresentationModel
    init(store: VideoStore) {
        self.store = store
        _presentation = StateObject(wrappedValue: LibraryPresentationModel(store: store))
    }
    var body: some View {
        TabView {
            NavigationStack {
                OfflineView()
                    .safeAreaInset(edge: .top, spacing: 0) { SigningExpiryBanner() }
            }
                .tabItem { Label("本地", systemImage: "internaldrive") }
            NavigationStack {
                VRFolderTab { file, startMode in
                    do { try store.playPickedFile(file, startMode: startMode) }
                    catch { store.errorMessage = error.localizedDescription }
                }
            }
                .toolbarBackground(Color(red: 0.05, green: 0.05, blue: 0.06), for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
                .toolbarColorScheme(.dark, for: .tabBar)
                .tabItem { Label("VR", systemImage: "eyeglasses").accessibilityIdentifier("vrFolderTab") }
            NavigationStack { ServerCatalogView() }
                .tabItem { Label("服务器", systemImage: "server.rack") }
            NavigationStack { TransfersView() }
                .tabItem { Label("下载", systemImage: "arrow.down.circle") }
            NavigationStack { LocalUploadView(store: store) }
                .tabItem { Label("上传", systemImage: "arrow.up.circle") }
            NavigationStack { SettingsView() }
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .task(id: scenePhase) {
            if scenePhase == .active { await store.refreshDownloadedFiles() }
        }
        .background { SigningLifecycleView() }
        .fullScreenCover(item: Binding(
            get: { presentation.playback }, set: { store.playback = $0 }
        ), onDismiss: store.openQueuedCompatibleCopy) { request in
            PlaybackScreen(request: request).environmentObject(store)
        }
        .alert("提示", isPresented: Binding(
            get: { presentation.playback == nil && presentation.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) { Button("确定", role: .cancel) { store.errorMessage = nil } }
        message: { Text(presentation.errorMessage ?? "") }
    }
}
