import SwiftUI

/// 周报/月报里**一条新闻**的详情页。
///
/// 刻意不发任何请求：正文用的就是周报 JSON 里已有的字段（标题、来源、
/// 发布时间、AI 导读）。站内条目页 `/items/{id}` 没有公开 JSON 接口 ——
/// 只有 HTML，正文还埋在 turbo-stream 载荷里（实测 2026-10-21），
/// 官网那份「AI 翻译正文」不在本页范围内。与其做高风险的 HTML 解析
/// （规则 18），不如把已有的「AI 导读」完整呈现：它本来就是官网
/// 这一块的顶部内容，字段与官网逐字同源。
///
/// 「打开原文」走系统阅读器（规则 14），旁边的「网页版」是唯一逃生口。
struct ReportItemDetailView: View {

    let item: PeriodReport.Item

    @State private var webLink: WebLinkSheet?

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
