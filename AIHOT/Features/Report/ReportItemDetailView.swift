import SwiftUI

/// 周报/月报里**一条新闻**的详情页。
///
/// 上半是周报 JSON 里已有的字段（标题、来源、发布时间、AI 导读 —— 与官网逐字同源）；
/// 下半是站内条目页 `/items/{id}` 的**完整正文**：那一页没有公开 JSON 接口
/// （`/api/v1/items/*` 全部 404，结构化载荷是 React Router 的 turbo-stream），
/// 只能整页抓 HTML，再由 `ReportItemBody` 从 `<div class="prose">` 里取出块。
///
/// **取不到正文不报错**：没链接、页面认不出、断网，三种都退回「AI 导读 + 打开原文」
/// 这一版（规则 18：宁可少显示，也不显示半个页面）。所以骨架屏只在**真的在取**的时候出现。
///
/// 「打开原文」走系统阅读器（规则 14），旁边的「网页版」是唯一逃生口。
struct ReportItemDetailView: View {

    let store: ReportStore
    let item: PeriodReport.Item

    @State private var webLink: WebLinkSheet?
    @State private var blocks: [ReportItemBody.Block]?
    /// 一进页面就先亮骨架：等 `.task` 跑起来再切成 true 反而会先闪一下空
    @State private var isLoadingBody = true
    @State private var didLoadBody = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.cardSpacing) {
                Text(item.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let meta = metaLine {
                    Text(meta)
                        .font(Typography.meta)
                        .foregroundColor(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let summary = item.summary, !summary.isEmpty {
                    guideCard(summary)
                }

                bodySection

                linkButtons

                footer
            }
            .padding(.horizontal, Metrics.horizontalPadding)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .background(Theme.background.ignoresSafeArea())
        // 顶栏不放大标题：正文第一行就是这条新闻的标题，再放一份只是重复
        .navigationBarTitleDisplayMode(.inline)
        .webLinkSheet(item: $webLink)
        // 正文里的行内链接不丢给系统 Safari：站内的永远走网页（网页应用没有正文，
        // 规则 14），外部的进阅读器 —— 与「打开原文」按钮同一个口径
        .environment(\.openURL, OpenURLAction { url in
            openInApp(url)
            return .handled
        })
        .task {
            guard !didLoadBody else { return }
            didLoadBody = true
            blocks = await store.itemBody(link: item.links?.aihot)
            isLoadingBody = false
        }
    }

    /// 「来源名 · 10月18日 09:12」（缺哪项省哪项）。
    private var metaLine: String? {
        var parts: [String] = []
        if let name = item.source?.name, !name.isEmpty {
            parts.append(name)
        }
        if let published = item.publishedAt {
            parts.append(RelativeTime.absoluteShort(published))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - 正文

    @ViewBuilder
    private var bodySection: some View {
        if let blocks = blocks {
            ReportItemBodyView(blocks: blocks)
                .padding(14)
                .cardBackground()
        } else if isLoadingBody {
            VStack(alignment: .leading, spacing: 10) {
                SkeletonBlock(height: 14, widthFraction: 0.92)
                SkeletonBlock(height: 14, widthFraction: 0.97)
                SkeletonBlock(height: 14, widthFraction: 0.88)
                SkeletonBlock(height: 14, widthFraction: 0.55)
            }
            .padding(14)
            .cardBackground()
        }
        // 既没取到也没在取 → 整块省略：下面的「打开原文」就是这一版的出口
    }

    private func openInApp(_ url: URL) {
        let host = url.host ?? ""
        let isAihot = host == "aihot.news" || host.hasSuffix(".aihot.news")
            || host == "aihot.virxact.com" || host.hasSuffix(".aihot.virxact.com")
        webLink = WebLinkSheet(url: url, entersReader: !isAihot)
    }

    private func guideCard(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 官网这一块就叫「AI 导读」，标签与正文同源
            Text("AI 导读")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.accent)
            Text(summary)
                .font(.system(size: 15))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardBackground()
    }

    // MARK: - 链接

    private var originalURL: URL? {
        item.links?.original.flatMap { URL(string: $0) }
    }

    private var aihotURL: URL? {
        item.links?.aihot.flatMap { URL(string: $0) }
    }

    @ViewBuilder
    private var linkButtons: some View {
        if originalURL != nil || aihotURL != nil {
            VStack(spacing: 10) {
                if let url = originalURL {
                    button(title: "打开原文", systemImage: "arrow.up.right.square") {
                        // 主入口直接进阅读器：去掉站点自己的导航与广告，只留正文
                        webLink = WebLinkSheet(url: url, entersReader: true)
                    }
                }
                if let url = aihotURL {
                    // 逃生口：阅读器抽得不好的页面，从这里退回站内条目页（网页，规则 14）
                    button(title: "网页版", systemImage: "safari") {
                        webLink = WebLinkSheet(url: url)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    /// 与 `StoryDetailView` 的 `LinkButton` 同一版式（那边是 private，这里照抄一份）。
    private func button(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textTertiary)
            }
            .foregroundColor(Theme.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
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
    }

    /// 署名回链（硬要求）：有站内条目页就指那一页，没有就退回官网首页。
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Hairline()
            HStack(spacing: 4) {
                Text("数据来源：")
                if let url = aihotURL ?? URL(string: "https://aihot.news") {
                    Button {
                        webLink = WebLinkSheet(url: url)
                    } label: {
                        Text("AIHOT").underline()
                    }
                }
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
