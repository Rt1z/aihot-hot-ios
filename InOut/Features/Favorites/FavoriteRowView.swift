import SwiftUI

/// 热点收藏的一行。
///
/// 刻意**不显示名次**：那是收藏当时的排名，榜单每天都在换，摆一个过期名次
/// 会让人以为它还排在第几位。改显示标题 + 来源/参与者数 + 收藏时间。
///
/// 右侧数字块复用 `HeatBlock`：`info` 只在「这条仍在当前榜单里」时才传进来
/// （见 `FavoritesListView.liveHeatInfo`）。拿不到实时热度就退回快照里的
/// 参与者数，**不编造数字**。
struct FavoriteRowView: View {

    let topic: HotTopic
    let favoritedAt: Date
    let info: HotPageEnrichment.RankInfo?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(topic.title)
                    .font(Typography.rowTitle)
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                let summary = SourceSummary.make(for: topic)
                if !summary.counts.isEmpty {
                    Text(summary.counts)
                        .font(Typography.meta)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }

                Text("收藏于 \(RelativeTime.absoluteShort(favoritedAt))")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
            }

            Spacer(minLength: 0)

            HeatBlock(
                heat: info?.heat,
                participants: topic.participantCount,
                compact: true
            )
        }
        .padding(.vertical, 4)
    }
}

/// 外部链接收藏的一行。
///
/// 没有热度、没有排名 —— 它不是榜单条目，摆任何数字都是编的。
/// 只显示标题、站点类型（公众号文章 / 链接）、域名与收藏时间。
struct SavedLinkRowView: View {

    let link: SavedLink
    let favoritedAt: Date

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: link.isWeChatArticle ? "text.book.closed" : "link")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.accent)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.accent.opacity(0.12)))

            VStack(alignment: .leading, spacing: 5) {
                Text(link.title)
                    .font(Typography.rowTitle)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)

                // 来源在左、收藏时间在右，同一行。来源太长就把来源截断，
                // 时间给 layoutPriority 保证不会被挤没。
                HStack(spacing: 8) {
                    Text(link.sourceLine)
                        .font(Typography.meta)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text("收藏于 \(RelativeTime.absoluteShort(favoritedAt))")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}
