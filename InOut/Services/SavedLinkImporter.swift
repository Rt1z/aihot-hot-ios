import Foundation

/// 把 `aihot://add` 进来的链接收进收藏。
///
/// 从 `RootView` 里抽出来单独做一层，是为了让「解析 → 建 SavedLink → 去重入列表」
/// 这段能被单测直接跑，而不是只能靠一条受 TCC 限制、拉不起 App 的 UI 用例。
/// 这不是分享扩展的替代品 —— 它就是分享入口本身（见 `AddLinkSheet` 的说明）。
@MainActor
enum SavedLinkImporter {

    struct Outcome: Equatable {
        let url: String
        /// 调用方传进来的标题；nil 表示需要异步抓一次标题。
        let title: String?
        /// false = 这条已经在收藏里（不重复添加）。
        let added: Bool
    }

    static func importLink(from incoming: URL, into favorites: FavoritesStore) -> Outcome? {
        guard let input = SharedLinkInput.parse(incoming) else { return nil }
        let link = SavedLink(url: input.url.absoluteString, title: input.title)
        let added = favorites.add(link: link)
        return Outcome(url: link.url, title: input.title, added: added)
    }
}
