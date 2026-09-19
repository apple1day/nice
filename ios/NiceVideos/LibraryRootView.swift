import SwiftUI
import Combine

// Presentation changes are infrequent. Download progress must not invalidate the
// entire tab hierarchy, and foreground activation must not scan the media folder.
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
    let store: VideoStore
    @StateObject private var presentation: LibraryPresentationModel
    init(store: VideoStore) {
        self.store = store
        _presentation = StateObject(wrappedValue: LibraryPresentationModel(store: store))
    }
    var body: some View {
        TabView {
            NavigationStack { OfflineView() }
                .tabItem { Label("本地", systemImage: "internaldrive") }
            NavigationStack { ServerCatalogView() }
                .tabItem { Label("服务器", systemImage: "server.rack") }
            NavigationStack { TransfersView() }
                .tabItem { Label("下载", systemImage: "arrow.down.circle") }
            NavigationStack { SettingsView() }
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .fullScreenCover(item: Binding(
            get: { presentation.playback }, set: { store.playback = $0 }
        )) { request in
            PlaybackScreen(request: request).environmentObject(store)
        }
        .alert("提示", isPresented: Binding(
            get: { presentation.playback == nil && presentation.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) { Button("确定", role: .cancel) { store.errorMessage = nil } }
        message: { Text(presentation.errorMessage ?? "") }
    }
}
