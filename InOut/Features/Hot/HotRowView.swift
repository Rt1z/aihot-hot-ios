import SwiftUI

/// 序号 4–10 的紧凑行。
struct HotRowView: View {
    let item: HotTopic
    let digest: String?
    let info: HotPageEnrichment.RankInfo?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RankNumber(rank: item.rank, compact: true)
                .frame(width: 26, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(Typography.rowTitle)
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let digest = digest, !digest.isEmpty {
                    Text(digest)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 6) {
                    let summary = SourceSummary.make(for: item)
                    if !summary.counts.isEmpty {
                        Text(summary.counts)
                            .font(Typography.meta)
                            .foregroundColor(Theme.textTertiary)
                            .lineLimit(1)
                    }

                    if let info = info {
                        if info.isBreakout {
                            BadgeChip(text: "爆", color: Theme.breakout)
                        }
                        if info.isNew {
                            BadgeChip(text: "新上榜", color: Theme.newBadge)
                        }
                        if let delta = info.delta {
                            BadgeChip(text: delta.text, color: deltaColor(delta))
                        }
                    }

                    Spacer(minLength: 0)

                    HeatBlock(heat: info?.heat, participants: item.participantCount, compact: true)
                }
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func deltaColor(_ delta: HotPageEnrichment.Delta) -> Color {
        switch delta {
        case .up: return Theme.up
        case .down: return Theme.down
        case .flat: return Theme.neutralBadge
        }
    }
}
