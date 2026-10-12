import SwiftUI

/// 收藏列表里的一行。
///
/// 刻意**不显示名次**：那是收藏当时的排名，榜单每天都在换，摆一个过期名次
/// 会让人以为它还排在第几位。改显示标题 + 来源/参与者数 + 收藏时间。
///
/// 右侧数字块复用 `HeatBlock`：`info` 只在「这条仍在当前榜单里」时才传进来
/// （见 `FavoritesListView.liveHeatInfo`）。拿不到实时热度就退回快照里的
/// 参与者数，**不编造数字**。
struct FavoriteRowView: View {

    let favorite: FavoritesStore.Favorite
    let info: HotPageEnrichment.RankInfo?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(favorite.topic.title)
                    .font(Typography.rowTitle)
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                let summary = SourceSummary.make(for: favorite.topic)
                if !summary.counts.isEmpty {
                    Text(summary.counts)
                        .font(Typography.meta)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }

                Text("收藏于 \(RelativeTime.absoluteShort(favorite.favoritedAt))")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
            }

            Spacer(minLength: 0)

            HeatBlock(
                heat: info?.heat,
                participants: favorite.topic.participantCount,
                compact: true
            )
        }
        .padding(.vertical, 4)
    }
}
