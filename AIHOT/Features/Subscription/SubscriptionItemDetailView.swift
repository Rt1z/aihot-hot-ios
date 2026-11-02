import SwiftUI

/// 一条订阅内容的详情。
///
/// 不在 App 内抓正文：公众号与 B 站页面交给系统 `SFSafariViewController`，
/// 既不用维护两套网页解析，也不会为公众号多花一次调用。视频页不支持阅读器模式，
/// 所以这里统一 `entersReader: false`（规则 14 的「网页版」逃生口只在使用阅读器时需要）。
struct SubscriptionItemDetailView: View {

    let item: SubscriptionItem

    @State private var safariURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let cover = item.coverURL, let url = URL(string: cover) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            Rectangle().fill(Theme.surfaceElevated)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous))
                }

                HStack(spacing: 6) {
                    BadgeChip(
                        text: item.kind.badge,
                        color: item.kind == .wechat ? Theme.accent : Theme.newBadge
                    )
                    Text(item.sourceName)
                        .lineLimit(1)
                    Text("·")
                    Text(item.publishedAt.map { RelativeTime.absoluteShort($0) } ?? "时间未知")
                }
                .font(Typography.meta)
                .foregroundColor(Theme.textTertiary)

                Text(item.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if !item.summary.isEmpty {
                    Text(item.summary)
                        .font(Typography.body)
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let link = URL(string: item.link), !item.link.isEmpty {
                    Button {
                        safariURL = link
                    } label: {
                        Label("打开原文", systemImage: "safari")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }

                Text("内容版权归原作者所有；本 App 只提供跳转与摘要，不存储、不分发原文。")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            .padding(Metrics.horizontalPadding)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("订阅详情")
        .navigationBarTitleDisplayMode(.inline)
        .safariSheet(url: $safariURL)
    }
}
