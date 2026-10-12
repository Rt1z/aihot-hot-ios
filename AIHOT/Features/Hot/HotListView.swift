import SwiftUI

struct HotListView: View {

    /// 由 RootView 注入：榜单数据要在收藏 tab 里也用得到（摘要、当前热度）。
    @ObservedObject var store: HotTopicsStore
    /// 只是往下传给详情页，本页自己不读它，所以是 let 而不是 @ObservedObject。
    let favorites: FavoritesStore

    @Environment(\.scenePhase) private var scenePhase

    @State private var safariURL: URL?
    @State private var showHowItWorks = false

    private static let hotPageURL = URL(string: "https://aihot.news/hot")!

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.cardSpacing) {
                    headerBlock

                    if let notice = store.notice {
                        NoticeBanner(notice: notice)
                    }

                    listContent
                }
                .padding(.horizontal, Metrics.horizontalPadding)
                .padding(.bottom, 32)
            }
            .background(Theme.background.ignoresSafeArea())
            .refreshable { await store.refresh() }
            .navigationTitle("AI 热点榜")
            .navigationBarTitleDisplayMode(.large)
            // 这里原来有个右上角 ⓘ 通往「关于」，现在「关于」是底部的设置 tab，
            // 少了这个入口，也就少了两个通往同一页的路径。
            .navigationDestination(for: HotTopic.self) { item in
                StoryDetailView(
                    item: item,
                    favorites: favorites,
                    prefetchedDigest: store.digest(for: item)
                )
            }
        }
        .tint(Theme.accent)
        .task { await store.loadIfNeeded() }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task { await store.refresh() }
        }
        .safariSheet(url: $safariURL)
    }

    // MARK: - 榜单头

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("过去 48 小时，AI 圈讨论最多的 10 件事")
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text(store.lastUpdatedText)
                Text("·")
                Text("按讨论热度排序")
                Spacer(minLength: 8)
                Button {
                    showHowItWorks = true
                } label: {
                    Text("怎么算").underline()
                }
            }
            .font(Typography.meta)
            .foregroundColor(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
        .sheet(isPresented: $showHowItWorks) {
            SafariView(url: HotListView.hotPageURL)
                .ignoresSafeArea()
        }
    }

    // MARK: - 列表

    @ViewBuilder
    private var listContent: some View {
        if store.items.isEmpty {
            if store.hasLoaded {
                EmptyStateView(
                    title: "暂时没有榜单数据",
                    message: store.notice?.message ?? "下拉即可重试，或稍后再来看看。",
                    actionTitle: "重新加载",
                    action: { Task { await store.refresh() } }
                )
            } else {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonCard()
                }
            }
        } else {
            if !store.topItems.isEmpty {
                SectionTitle(text: "实时热度")
                ForEach(store.topItems) { item in
                    NavigationLink(value: item) {
                        HotTopCardView(
                            item: item,
                            digest: store.digest(for: item),
                            info: store.enrichmentInfo(for: item)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if !store.restItems.isEmpty {
                SectionTitle(text: "继续看 No.04–10")
                restList
            }

            AttributionFooter(updatedText: store.lastUpdatedText)
        }
    }

    private var restList: some View {
        let rows = store.restItems
        return VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                let item = rows[index]
                NavigationLink(value: item) {
                    HotRowView(
                        item: item,
                        digest: store.digest(for: item),
                        info: store.enrichmentInfo(for: item)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)

                if index < rows.count - 1 {
                    Hairline().padding(.leading, 14)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous))
    }
}

/// 页脚署名：AIHOT 的使用条款要求保留来源与链接。
struct AttributionFooter: View {
    let updatedText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Hairline()
            HStack(spacing: 4) {
                Text("数据来源：")
                Link("AIHOT", destination: URL(string: "https://aihot.news")!)
                    .foregroundColor(Theme.accent)
                Text("· \(updatedText)")
            }
            .font(Typography.meta)
            .foregroundColor(Theme.textTertiary)

            Text("内容版权归 AIHOT 及各原始来源所有，本 App 仅供个人使用。")
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(.top, 10)
    }
}
