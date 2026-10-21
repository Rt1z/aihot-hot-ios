import SwiftUI

/// 一期报告的正文渲染 —— Tab 首页与往期详情页的**唯一**内容来源。
///
/// `overview`/`sections[].summary` 为 nil 时整块省略、不留占位（老期次真的没有，
/// 规则 19）；分栏 `label` 原样渲染不归一化（老期是主题句、新期是分类名）。
///
/// 分栏标题对齐官网那一版「01 / 模型发布/更新」：编号 + 加粗的名字，
/// 而不是 `SectionTitle` 那种 13pt 灰字（那个是给模型榜与往期分组用的，
/// 在这里太不显眼，改它又会连带改坏那些页 —— 所以另起一个组件）。
struct ReportIssueView: View {

    let report: PeriodReport

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

            ForEach(report.sections.indices, id: \.self) { sectionIndex in
                sectionView(report.sections[sectionIndex], number: sectionIndex + 1)
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

    private func sectionView(_ section: PeriodReport.Section, number: Int) -> some View {
        // 老期次的 summary 真的是 nil（规则 19）；空串也当没有，不留占位
        let summary: String? = (section.summary ?? "").isEmpty ? nil : section.summary
        return VStack(alignment: .leading, spacing: 8) {
            ReportSectionHeader(number: number, label: section.label)

            // 标题之外什么都没有的分栏不画卡片（一条空框框比整块省略更难看）
            if summary != nil || !section.items.isEmpty {
                VStack(spacing: 0) {
                    if let summary = summary {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("本版导读")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Theme.accent)
                            Text(summary)
                                .font(.system(size: 13))
                                .foregroundColor(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)

                        if !section.items.isEmpty {
                            Hairline()
                        }
                    }

                    ForEach(section.items.indices, id: \.self) { itemIndex in
                        ReportItemRow(item: section.items[itemIndex])
                        if itemIndex < section.items.count - 1 {
                            Hairline().padding(.leading, 14)
                        }
                    }
                }
                .cardBackground()
            }
        }
    }
}

/// 一块分栏的标题：`01` + 分栏名（官网的「模型发布/更新」那种）。
///
/// 编号复用 `Typography.rankSmall`（13pt 粗体等宽）—— 榜单名次用的就是它，
/// 等宽数字让「01/02/10」对齐；名字比正文大一号、加粗、用主文字色。
struct ReportSectionHeader: View {

    let number: Int
    let label: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(format: "%02d", number))
                .font(Typography.rankSmall)
                .foregroundColor(Theme.accent)

            Text(label)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }
}

/// 一条条目：标题 + 摘要 + 「来源 · 时间」，整行推入 `ReportItemDetailView`
/// —— 链接与阅读器都在那一页里决定（本行不再自己开弹窗）。
private struct ReportItemRow: View {

    let item: PeriodReport.Item

    var body: some View {
        NavigationLink(value: item) {
            HStack(alignment: .top, spacing: 10) {
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

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
}
