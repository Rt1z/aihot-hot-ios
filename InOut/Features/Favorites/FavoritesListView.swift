import SwiftUI

/// 收藏 tab。
///
/// 用 `List` 而不是榜单页那套 `ScrollView` + 卡片，是为了拿到系统自带的左滑操作。
/// 行内容本身仍复用同一套 Theme 与组件。
struct FavoritesListView: View {

    @ObservedObject var hot: HotTopicsStore
    @ObservedObject var favorites: FavoritesStore
    /// 练习本的入口挂在这一页（不新增 Tab：第 6 个会被 iOS 收进「更多」）。
    @ObservedObject var practice: PracticeStore
    /// 快捷指令「收藏并打开」留下的文章 URL：非 nil 时自动 push 详情。
    @Binding var pendingOpenLinkURL: String?

    @State private var showAddLink = false
    @State private var showPracticeBook = false
    @State private var pendingLink: SavedLink?
    @State private var pendingLinkFavoritedAt: Date?
    @State private var showPendingLink = false

    var body: some View {
        NavigationStack {
            content
                .background(Theme.background.ignoresSafeArea())
                .navigationTitle("收藏")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showAddLink = true
                        } label: {
                            Image(systemName: "plus")
                                .font(Typography.toolbarIcon)
                                .foregroundColor(Theme.accent)
                        }
                        .accessibilityLabel("添加链接")
                        .accessibilityIdentifier("favorites-add-link")
                    }
                }
                .navigationDestination(isPresented: $showPracticeBook) {
                    PracticeListView(store: practice)
                }
                .navigationDestination(isPresented: $showPendingLink) {
                    if let link = pendingLink {
                        SavedLinkDetailView(
                            link: link,
                            favoritedAt: pendingLinkFavoritedAt ?? Date(),
                            favorites: favorites,
                            practice: practice
                        )
                    }
                }
                .navigationDestination(for: HotTopic.self) { item in
                    StoryDetailView(
                        item: item,
                        favorites: favorites,
                        practice: practice,
                        prefetchedDigest: hot.digest(for: item)
                    )
                }
                .sheet(isPresented: $showAddLink) {
                    AddLinkSheet(favorites: favorites)
                }
                .task { openPendingLinkIfNeeded() }
                .onChange(of: pendingOpenLinkURL) { _ in openPendingLinkIfNeeded() }
        }
        .tint(Theme.accent)
    }

    /// 消费 RootView 传下来的待打开文章：找到收藏里的这条，push 详情，清掉请求。
    ///
    /// 找不到就留着请求（收藏可能还没 reload 完）；下一次 onChange / task 再试。
    private func openPendingLinkIfNeeded() {
        guard let raw = pendingOpenLinkURL,
              let normalized = SharedLinkURL.normalized(raw)?.absoluteString,
              let favorite = favorites.items.first(where: {
                  $0.kind == .link && $0.link?.url == normalized
              }),
              let link = favorite.link
        else { return }

        pendingLink = link
        pendingLinkFavoritedAt = favorite.favoritedAt
        showPendingLink = true
        pendingOpenLinkURL = nil
    }

    /// 练习本入口：用 Button + `navigationDestination(isPresented:)` 而不是
    /// 包成 NavigationLink —— 放进 List 后 NavigationLink 会再叠一个系统 chevron，
    /// 卡片自带的那个就重复了。练习本是独立于收藏的用户数据，收藏为空时也要在。
    private var practiceBookLink: some View {
        Button {
            showPracticeBook = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "book.closed")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.accent)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.accent.opacity(0.12)))

                VStack(alignment: .leading, spacing: 2) {
                    Text("练习本")
                        .font(Typography.rowTitle)
                        .foregroundColor(Theme.textPrimary)
                    Text(practiceSubtitle)
                        .font(Typography.meta)
                        .foregroundColor(Theme.textTertiary)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .accessibilityIdentifier("practice-book-row")
    }

    private var practiceSubtitle: String {
        let stats = practice.stats()
        if stats.total == 0 {
            return "还没练过：在详情页点「练一练」"
        }
        return "共 \(stats.total) 篇 · 本周 \(stats.thisWeek) 篇 · 连续 \(stats.streakDays) 天"
    }

    @ViewBuilder
    private var content: some View {
        if favorites.items.isEmpty {
            VStack(spacing: 0) {
                practiceBookLink
                Spacer(minLength: 0)
                EmptyStateView(
                    title: "还没有收藏",
                    message: "在热点详情页点右上角书签；网页链接用右上角的「+」添加。没有网络也能看。",
                    actionTitle: "添加链接",
                    action: { showAddLink = true },
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
            // 练习本入口放进列表里，才和收藏一起滚动（之前挂在 List 外面是固定的）。
            practiceBookLink
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            ForEach(favorites.items) { favorite in
                favoriteRow(favorite)
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

    /// 热点与链接混在同一个列表里，按它们共同的插入顺序排列。
    @ViewBuilder
    private func favoriteRow(_ favorite: FavoritesStore.Favorite) -> some View {
        switch favorite.kind {
        case .topic:
            if let topic = favorite.topic {
                NavigationLink(value: topic) {
                    FavoriteRowView(
                        topic: topic,
                        favoritedAt: favorite.favoritedAt,
                        info: liveHeatInfo(for: topic)
                    )
                }
            }
        case .link:
            if let link = favorite.link {
                NavigationLink {
                    SavedLinkDetailView(
                        link: link,
                        favoritedAt: favorite.favoritedAt,
                        favorites: favorites,
                        practice: practice
                    )
                } label: {
                    SavedLinkRowView(link: link, favoritedAt: favorite.favoritedAt)
                }
                .accessibilityIdentifier("saved-link-row")
            }
        }
    }

    /// 只有这条**仍在当前榜单里**时才给实时热度。
    ///
    /// 不能直接拿收藏项自己那个 `rank` 去查 `enrichmentInfo(for:)`：名次早变了，
    /// 那样查出来的是**现在排在那个位置的那条内容**的热度指数，属于张冠李戴。
    /// 所以先用 id 在当前榜单里找到同一条，再按它的（当前）名次去查。
    private func liveHeatInfo(for topic: HotTopic) -> HotPageEnrichment.RankInfo? {
        guard let current = hot.items.first(where: { $0.id == topic.id }) else { return nil }
        return hot.enrichmentInfo(for: current)
    }
}
