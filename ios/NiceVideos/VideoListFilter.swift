import Foundation

// Favorite/watch flags belong to the device's download record. A server item
// without a local record has not been watched here and cannot be a favorite.
enum VideoListFilter: String, CaseIterable, Identifiable {
    case all, favorites, unwatched

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部"
        case .favorites: return "收藏"
        case .unwatched: return "未看"
        }
    }

    func matches(_ record: DownloadRecord?) -> Bool {
        switch self {
        case .all: return true
        case .favorites: return record?.isFavorite == true
        case .unwatched: return record?.hasWatched != true
        }
    }
}
