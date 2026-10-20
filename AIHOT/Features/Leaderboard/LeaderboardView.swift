import SwiftUI

/// 「模型榜」Tab 根视图：五个分类分段切换 + 30 行榜单。
struct LeaderboardView: View {

    @ObservedObject var store: LeaderboardStore

    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedCategory: LeaderboardCategory = .overall
    @State private var webLink: WebLinkSheet?

    private static let rulesURL = URL(string: "https://aihot.news/leaderboard/rules")!
    private static let leaderboardPageURL = URL(string: "https://aihot.news/leaderboard")!

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.cardSpacing) {
                    categoryPicker

                    if let header = store.headerText(for: selectedCategory) {
                        Text(header)
                            .font(Typography.meta)
                            .foregroundColor(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let notice = store.notice {
                        NoticeBanner(notice: notice)
                    }

                    listContent
                }
                .padding(.horizontal, Metrics.horizontalPadding)
                .padding(.bottom, 32)
            }
            .background(Theme.background.ignoresSafeArea())
            .refreshable { await store.refresh(category: selectedCategory) }
            .navigationTitle("AI 模型榜")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        webLink = WebLinkSheet(url: LeaderboardView.rulesURL)
                    } label: {
                        Text("怎么算")
                            .font(Typography.meta)
                            .foregroundColor(Theme.accent)
                    }
                    .accessibilityLabel("评分规则")
                }
            }
            .navigationDestination(for: LeaderboardModel.self) { model in
                LeaderboardDetailView(store: store, slug: model.slug, fallbackName: model.name)
            }
        }
        .tint(Theme.accent)
        .task { await store.refresh(category: selectedCategory) }
        // 切分类立刻拉这个分类（refresh 内部自己节流）
        .onChange(of: selectedCategory) { category in
            Task { await store.refresh(category: category) }
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task { await store.refresh(category: selectedCategory) }
        }
        .webLinkSheet(item: $webLink)
    }

    // MARK: - 分类切换

    private var categoryPicker: some View {
        Picker("分类", selection: $selectedCategory) {
            ForEach(LeaderboardCategory.allCases) { category in
                Text(category.title).tag(category)
            }
        }
        .pickerStyle(.segmented)
        .padding(.top, 4)
    }

    // MARK: - 列表

    @ViewBuilder
    private var listContent: some View {
        if let board = store.board(for: selectedCategory), !board.models.isEmpty {
            modelList(board.models)
            attributionFooter(updatedText: board.updatedText)
        } else if store.hasLoaded {
            EmptyStateView(
                title: "暂时取不到这个榜",
                message: store.notice?.message ?? "下拉即可重试，或稍后再来看看。",
                actionTitle: "重新加载",
                action: { Task { await store.refresh(category: selectedCategory) } }
            )
        } else {
            ForEach(0..<3, id: \.self) { _ in
                SkeletonCard()
            }
        }
    }

    private func modelList(_ models: [LeaderboardModel]) -> some View {
        VStack(spacing: 0) {
            ForEach(models.indices, id: \.self) { index in
                let model = models[index]
                NavigationLink(value: model) {
                    LeaderboardRowView(model: model)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)

                if index < models.count - 1 {
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

    /// 页脚署名：模型榜同样是 AIHOT 的内容，来源回链是硬要求。
    private func attributionFooter(updatedText: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Hairline()
            HStack(spacing: 4) {
                Text("数据来源：")
                Button {
                    webLink = WebLinkSheet(url: LeaderboardView.leaderboardPageURL)
                } label: {
                    Text("AIHOT 模型榜").underline()
                }
                if let updatedText = updatedText {
                    Text("· \(updatedText) 更新")
                }
            }
            .font(Typography.meta)
            .foregroundColor(Theme.textTertiary)

            Text("内容版权归 AIHOT 及各评测机构所有，本 App 仅供个人使用。")
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(.top, 10)
    }
}

/// 榜单一行：名次 + 名字/厂商 + 价格摘要 | 评分。
struct LeaderboardRowView: View {

    let model: LeaderboardModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RankNumber(rank: model.rank)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.name)
                    .font(Typography.rowTitle)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let meta = metaLine, !meta.isEmpty {
                    Text(meta)
                        .font(Typography.meta)
                        .foregroundColor(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(priceLine)
                    .font(.system(size: 11))
                    .foregroundColor(priceAllUnavailable ? Theme.textTertiary : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                if let score = model.score {
                    Text(String(format: "%.1f", score))
                        .font(Typography.heatSmall)
                        .foregroundColor(Theme.accent)
                        .monospacedDigit()
                }
                if let coverage = model.coveragePercent {
                    Text("覆盖 \(coverage)%")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                }
            }
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private var metaLine: String? {
        var parts: [String] = []
        if let provider = model.provider, !provider.isEmpty {
            parts.append(provider)
        }
        if let released = model.releasedISO {
            parts.append("\(released) 上线")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 缓存/输入/输出三档价格；「待核验」（解析为 nil）显示占位灰字。
    private var priceLine: String {
        let slots = [model.cachePrice, model.inputPrice, model.outputPrice]
        if slots.allSatisfy({ $0 == nil }) {
            return "缓存/输入/输出 待核验"
        }
        return slots
            .map { $0 ?? "待核验" }
            .joined(separator: " / ")
    }

    private var priceAllUnavailable: Bool {
        model.cachePrice == nil && model.inputPrice == nil && model.outputPrice == nil
    }
}
