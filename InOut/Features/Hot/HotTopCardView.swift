import SwiftUI

/// 序号 1–3 的大卡：官网用「大卡 + 正文段落 + 头像行 + 热度指数」重点展示。
struct HotTopCardView: View {
    let item: HotTopic
    let digest: String?
    let info: HotPageEnrichment.RankInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RankNumber(rank: item.rank)
                BadgeRow(info: info)
                Spacer(minLength: 0)
                Text(RelativeTime.relative(item.latestAt))
                    .font(Typography.meta)
                    .foregroundColor(Theme.textTertiary)
            }

            Text(item.title)
                .font(Typography.cardTitle)
                .foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let digest = digest, !digest.isEmpty {
                Text(digest)
                    .font(Typography.body)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Hairline()

            HStack(alignment: .bottom, spacing: 10) {
                AvatarStack(
                    names: item.sourceNames ?? [],
                    overflowCount: item.sourceCount ?? 0,
                    size: 20
                )

                VStack(alignment: .leading, spacing: 2) {
                    let summary = SourceSummary.make(for: item)
                    if !summary.preview.isEmpty {
                        Text(summary.preview)
                            .font(Typography.meta)
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    if !summary.counts.isEmpty {
                        Text(summary.counts)
                            .font(Typography.meta)
                            .foregroundColor(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                HeatBlock(heat: info?.heat, participants: item.participantCount)
            }
        }
        .cardBackground()
        .contentShape(Rectangle())
    }
}

/// 徽章行：爆 / 新 / ↑x% / ↓x% / 持平
struct BadgeRow: View {
    let info: HotPageEnrichment.RankInfo?

    var body: some View {
        HStack(spacing: 6) {
            if let info = info {
                if info.isBreakout {
                    BadgeChip(text: "爆", color: Theme.breakout)
                }
                if info.isNew {
                    BadgeChip(text: "新", color: Theme.newBadge)
                }
                if let delta = info.delta {
                    BadgeChip(text: delta.text, color: deltaColor(delta))
                }
            }
        }
    }

    private func deltaColor(_ delta: HotPageEnrichment.Delta) -> Color {
        switch delta {
        case .up: return Theme.up
        case .down: return Theme.down
        case .flat: return Theme.neutralBadge
        }
    }
}

/// 右侧的数字块：有热度指数就显示官网那个数字；没有就显示真实的参与者数，
/// **不编造**官网才有的数值。
struct HeatBlock: View {
    let heat: Int?
    let participants: Int?
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if let heat = heat {
                Text("\(heat)")
                    .font(compact ? Typography.heatSmall : Typography.heat)
                    .foregroundColor(Theme.accent)
                    .monospacedDigit()
                Text("热度指数")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
            } else if let participants = participants, participants > 0 {
                Text("\(participants)")
                    .font(compact ? Typography.heatSmall : Typography.heat)
                    .foregroundColor(Theme.accent)
                    .monospacedDigit()
                Text("位参与者")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
            }
        }
    }
}
