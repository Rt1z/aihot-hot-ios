import SwiftUI

/// 收藏 tab。
///
/// 用 `List` 而不是榜单页那套 `ScrollView` + 卡片，是为了拿到系统自带的左滑操作。
/// 行内容本身仍复用同一套 Theme 与组件。
struct FavoritesListView: View {

    @ObservedObject var hot: HotTopicsStore
    @ObservedObject var favorites: FavoritesStore

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("收藏")
                .navigationBarTitleDisplayMode(.large)
                .navigationDestination(for: HotTopic.self) { item in
                    StoryDetailView(
                        item: item,
                        favorites: favorites,
                        prefetchedDigest: hot.digest(for: item)
                    )
                }
        }
        .tint(Theme.accent)
    }

    @ViewBuilder
    private var content: some View {
        if favorites.items.isEmpty {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                EmptyStateView(
                    title: "还没有收藏",
                    message: "在热点详情页点右上角的书签，就会收在这里；没有网络也能看。",
                    systemImage: "bookmark"
                )
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background.ignoresSafeArea())
        } else {
            list
        }
    }

    private var list: some View {
        List {
            ForEach(favorites.items) { favorite in
                NavigationLink(value: favorite.topic) {
                    FavoriteRowView(favorite: favorite, info: liveHeatInfo(for: favorite))
                }
                // 用 swipeActions 而不是 onDelete：onDelete 只能显示系统那条
                // 本地化的「删除」，而这里要说清楚取消的是收藏。
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        favorites.remove(id: favorite.id)
                    } label: {
                        Label("取消收藏", systemImage: "bookmark.slash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
    }

    /// 只有这条**仍在当前榜单里**时才给实时热度。
    ///
    /// 不能直接拿收藏项自己那个 `rank` 去查 `enrichmentInfo(for:)`：名次早变了，
    /// 那样查出来的是**现在排在那个位置的那条内容**的热度指数，属于张冠李戴。
    /// 所以先用 id 在当前榜单里找到同一条，再按它的（当前）名次去查。
    private func liveHeatInfo(for favorite: FavoritesStore.Favorite) -> HotPageEnrichment.RankInfo? {
        guard let current = hot.items.first(where: { $0.id == favorite.topic.id }) else { return nil }
        return hot.enrichmentInfo(for: current)
    }
}
