import SwiftUI

/// 一期报告的正文渲染 —— Tab 首页与往期详情页的**唯一**内容来源。
///
/// `overview`/`sections[].summary` 为 nil 时整块省略、不留占位（老期次真的没有，
/// 规则 19）；分栏 `label` 原样渲染不归一化（老期是主题句、新期是分类名）。
struct ReportIssueView: View {

    let report: PeriodReport
    /// 弹窗状态留在宿主视图（两处各自持 sheet identity 会打架），
    /// 这里只负责把「要开哪个链接」抛出去。
    let onOpenLink: (WebLinkSheet) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.cardSpacing) {
            if let headline = report.headline, !headline.isEmpty {
                Text(headline)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let meta = metaLine {
                Text(meta)
                    .font(Typography.meta)
                    .foregroundColor(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let overview = report.overview, !overview.isEmpty {
                Text(overview)
                    .font(.system(size: 15))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(report.sections.indices, id: \.self) { index in
                sectionView(report.sections[index])
            }
        }
        .padding(.top, 4)
    }

    /// 「10.12 – 10.18 · 生成于 10月19日 10:00」（缺哪项省哪项）。
    private var metaLine: String? {
        var parts: [String] = []
        if let range = ReportPeriod.rangeText(start: report.periodStart, end: report.periodEnd) {
            parts.append(range)
        }
        if let generated = report.generatedAt {
            parts.append("生成于 " + RelativeTime.absoluteShort(generated))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func sectionView(_ section: PeriodReport.Section) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: section.label)

            if let summary = section.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach(section.items.indices, id: \.self) { index in
                    ReportItemRow(item: section.items[index], onOpenLink: onOpenLink)
                    if index < section.items.count - 1 {
                        Hairline().padding(.leading, 14)
                    }
                }
            }
            .cardBackground()
        }
    }
}

/// 一条条目：标题 + 摘要 + 「来源 · 时间」，整行可点 ——
/// 优先原文（阅读器，规则 14），其次站内条目页（网页），都没有则不可点（不编造链接）。
private struct ReportItemRow: View {

    let item: PeriodReport.Item
    let onOpenLink: (WebLinkSheet) -> Void

    private var originalURL: URL? {
        item.links?.original.flatMap { URL(string: $0) }
    }

    private var aihotURL: URL? {
        item.links?.aihot.flatMap { URL(string: $0) }
    }

    private var isOpenable: Bool { originalURL != nil || aihotURL != nil }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let summary = item.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let meta = metaLine {
                    Text(meta)
                        .font(Typography.meta)
                        .foregroundColor(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isOpenable)
        .padding(14)
    }

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

    private func open() {
        if let url = originalURL {
            // 原文走系统阅读器；「网页版」逃生口在宿主视图的页脚/顶栏
            onOpenLink(WebLinkSheet(url: url, entersReader: true))
        } else if let url = aihotURL {
            // 站内条目页是网页应用没有正文，阅读器无意义 —— 永远走网页（规则 14）
            onOpenLink(WebLinkSheet(url: url))
        }
    }
}
