import SwiftUI

/// 模型详情页：概览评分/价格 + 四个领域卡 + 逐项公开成绩。
///
/// 「展开运行配置」和「测过但不计入」不做：前者 SSR 里没有（懒加载），
/// 后者解析面太花 —— 宁可少抽。顶栏「网页版」是回链也是唯一逃生口。
struct LeaderboardDetailView: View {

    @ObservedObject var store: LeaderboardStore

    let slug: String
    /// 榜单行带过来的名字：详情还没回来时标题不至于空白。
    let fallbackName: String

    @State private var detail: LeaderboardDetail?
    @State private var isLoading = true
    @State private var webLink: WebLinkSheet?

    private var pageURL: URL? {
        URL(string: "https://aihot.news/leaderboard/\(slug)")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let detail = detail {
                    headerCard(detail)
                    overviewGrid(detail)

                    if !detail.cards.isEmpty {
                        SectionTitle(text: "各领域表现")
                        categoryCards(detail.cards)
                    }

                    ForEach(Array(detail.groups.enumerated()), id: \.offset) { _, group in
                        benchmarkGroupSection(group)
                    }
                } else if isLoading {
                    ForEach(0..<3, id: \.self) { _ in
                        SkeletonCard()
                    }
                } else {
                    EmptyStateView(
                        title: "暂时取不到这个模型的详情",
                        message: "网络或榜单页面异常，稍后重试；也可以点右上角「网页版」直接看官网。",
                        actionTitle: "重新加载",
                        action: { Task { await load() } }
                    )
                }
            }
            .padding(.horizontal, Metrics.horizontalPadding)
            .padding(.bottom, 32)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(detail?.name ?? fallbackName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    if let url = pageURL {
                        webLink = WebLinkSheet(url: url)
                    }
                } label: {
                    Text("网页版")
                        .font(Typography.meta)
                        .foregroundColor(Theme.accent)
                }
                .accessibilityLabel("在网页查看这个模型")
            }
        }
        .task { await load() }
        .webLinkSheet(item: $webLink)
    }

    private func load() async {
        isLoading = true
        detail = await store.detail(slug: slug)
        isLoading = false
    }

    // MARK: - 顶卡

    private func headerCard(_ detail: LeaderboardDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let provider = detail.provider {
                    LetterAvatar(name: provider, size: 20)
                    Text(provider)
                        .font(Typography.meta)
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                if let updated = detail.updatedText {
                    Text("\(updated) 更新")
                        .font(Typography.meta)
                        .foregroundColor(Theme.textTertiary)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let score = detail.overallScore {
                    Text(String(format: "%.1f", score))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(Theme.accent)
                        .monospacedDigit()
                    Text("综合评分")
                        .font(Typography.meta)
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                if let rank = detail.overallRank {
                    BadgeChip(text: "综合第 \(rank) 名", color: Theme.accent)
                }
            }

            if let meta = headerMetaLine(detail), !meta.isEmpty {
                Text(meta)
                    .font(Typography.meta)
                    .foregroundColor(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }

    private func headerMetaLine(_ detail: LeaderboardDetail) -> String? {
        var parts: [String] = []
        if let released = detail.releasedText { parts.append(released) }
        if let coverage = detail.coveragePercent { parts.append("评测覆盖 \(coverage)%") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - 概览四格

    private func overviewGrid(_ detail: LeaderboardDetail) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                overviewCell(label: "上下文窗口", value: detail.contextWindowText)
                overviewCell(
                    label: "每百万 Token 输入 / 输出",
                    value: pricePair(input: detail.inputPrice, output: detail.outputPrice),
                    footnote: cacheFootnote(detail)
                )
            }
        }
        .cardBackground()
    }

    private func pricePair(input: String?, output: String?) -> String? {
        guard let input = input, let output = output else { return nil }
        return "\(input) / \(output)"
    }

    private func cacheFootnote(_ detail: LeaderboardDetail) -> String? {
        var parts: [String] = []
        if let cache = detail.cachePrice {
            parts.append("缓存 \(cache)")
        }
        if let usd = detail.originalUSDText {
            parts.append(usd)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func overviewCell(label: String, value: String?, footnote: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
            if let value = value {
                Text(value)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let footnote = footnote {
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 领域卡

    private func categoryCards(_ cards: [LeaderboardDetail.CategoryCard]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(cards.indices, id: \.self) { index in
                let card = cards[index]
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.category.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    if let score = card.score {
                        Text(String(format: "%.1f", score))
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundColor(Theme.accent)
                            .monospacedDigit()
                    }
                    if let line = cardMetaLine(card), !line.isEmpty {
                        Text(line)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardBackground()
            }
        }
    }

    private func cardMetaLine(_ card: LeaderboardDetail.CategoryCard) -> String? {
        var parts: [String] = []
        if let rank = card.rank { parts.append("第 \(rank) 名") }
        if let evalCount = card.evalCount { parts.append("\(evalCount) 项评测") }
        if let coverage = card.coveragePercent { parts.append("覆盖 \(coverage)%") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - 逐项成绩

    @ViewBuilder
    private func benchmarkGroupSection(_ group: LeaderboardDetail.BenchmarkGroup) -> some View {
        if !group.items.isEmpty {
            SectionTitle(text: "\(group.heading)成绩")
            VStack(spacing: 0) {
                ForEach(group.items.indices, id: \.self) { index in
                    BenchmarkRow(item: group.items[index])
                    if index < group.items.count - 1 {
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
}

/// 一项公开成绩：评测名 + 机构（可能带「旧型号作答」备注）| 原始成绩 + 折算分。
private struct BenchmarkRow: View {

    let item: LeaderboardDetail.Benchmark

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let source = item.source {
                    Text(source)
                        .font(Typography.meta)
                        .foregroundColor(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                if let scoreText = item.scoreText {
                    Text(scoreText)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundColor(Theme.textPrimary)
                        .monospacedDigit()
                }
                if let converted = item.converted {
                    Text("折算分 \(converted)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(14)
    }
}
