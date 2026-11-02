import SwiftUI

/// 订阅 tab：公众号 + B 站内容，按 科技 / 健康 / 成长 / 职业 / 周边 分组。
///
/// `isActive` 由 RootView 的 tab 选择传入：TabView 会保留所有 tab 的视图，
/// 只有用户真的切到订阅页时才允许自动刷新 —— 公众号是按次计费的。
struct SubscriptionTabView: View {

    @ObservedObject var store: SubscriptionStore
    /// 当前 tab 是否被选中。false 时不做自动刷新（手动下拉仍然可用，因为看不见也划不到）。
    let isActive: Bool

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                    header
                    banners
                    content
                    attribution
                }
                .padding(.horizontal, Metrics.horizontalPadding)
                .padding(.vertical, 12)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("订阅")
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await store.refresh(manual: true) }
            .navigationDestination(for: SubscriptionItem.self) { item in
                SubscriptionItemDetailView(item: item)
            }
            .task(id: isActive) {
                guard isActive else { return }
                await store.refreshIfNeeded()
            }
            .onChange(of: scenePhase) { phase in
                guard phase == .active, isActive else { return }
                Task { await store.refreshIfNeeded() }
            }
        }
        .tint(Theme.accent)
    }

    // MARK: - 页头

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("公众号 + B 站")
                    .font(Typography.sectionTitle)
                    .foregroundColor(Theme.textSecondary)
                Spacer(minLength: 0)
                if store.isRefreshing {
                    ProgressView().scaleEffect(0.7)
                }
            }
            Text(metaText)
                .font(Typography.meta)
                .foregroundColor(Theme.textTertiary)
        }
        .padding(.top, 4)
    }

    private var metaText: String {
        let counts = store.sourceCounts
        var parts: [String] = []
        if counts.wechat > 0 { parts.append("公众号 \(counts.wechat) 个") }
        if counts.bilibili > 0 { parts.append("B 站 \(counts.bilibili) 个") }
        parts.append("更新 \(store.lastUpdatedText)")
        return parts.joined(separator: " · ")
    }

    // MARK: - 横幅

    @ViewBuilder
    private var banners: some View {
        if let notice = store.configNotice {
            NoticeBanner(notice: notice)
        }
        if !store.configWarnings.isEmpty {
            NoticeBanner(
                notice: HotTopicsStore.Notice(
                    kind: .failed,
                    message: "配置里有条目被跳过：" + store.configWarnings.joined(separator: "；")
                )
            )
        }
        if let notice = store.notice(for: .wechat) {
            NoticeBanner(notice: notice)
        }
        if let notice = store.notice(for: .bilibili) {
            NoticeBanner(notice: notice)
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if store.items.isEmpty && !store.hasLoaded {
            VStack(spacing: Metrics.cardSpacing) {
                SkeletonCard()
                SkeletonCard()
                SkeletonCard()
            }
        } else if store.items.isEmpty {
            EmptyStateView(
                title: emptyTitle,
                message: emptyMessage,
                systemImage: "square.stack"
            )
        } else {
            ForEach(SubscriptionGrouping.sections(items: store.items)) { section in
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(text: "\(section.topic.title) · \(section.items.count)")
                    sectionCard(section)
                }
            }
        }
    }

    private var emptyTitle: String {
        if AppSettings.subscriptionConfigURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "还没配置订阅"
        }
        if let config = store.config, config.enabledSources.isEmpty {
            return "配置里还没有启用的订阅源"
        }
        return "还没有内容"
    }

    private var emptyMessage: String {
        if AppSettings.subscriptionConfigURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "到「个人 → 设置 → 订阅」填写配置文件地址与 RSSHub 地址，再回到这里下拉刷新。"
        }
        if let config = store.config, config.enabledSources.isEmpty {
            return "检查电脑上的 subscriptions.json，至少保留一条启用的公众号或 B 站订阅。"
        }
        return "下拉刷新试试；如果一直为空，到「个人 → 设置 → 订阅」点「检查订阅配置」。"
    }

    private func sectionCard(_ section: SubscriptionSection) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                NavigationLink(value: item) {
                    SubscriptionRowView(item: item)
                }
                .buttonStyle(.plain)
                if index < section.items.count - 1 {
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
    }

    private var attribution: some View {
        Text("内容版权归微信公众号原作者与哔哩哔哩 UP 主所有；本 App 仅作个人阅读，不存储、不分发内容。公众号经 Dajiala 接口读取，B 站经你自建的 RSSHub 读取。")
            .font(.system(size: 11))
            .foregroundColor(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
            .padding(.bottom, 12)
    }
}

// MARK: - 行

struct SubscriptionRowView: View {

    let item: SubscriptionItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(Typography.rowTitle)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if !item.summary.isEmpty {
                    Text(item.summary)
                        .font(Typography.meta)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: 6) {
                    BadgeChip(
                        text: item.kind.badge,
                        color: item.kind == .wechat ? Theme.accent : Theme.newBadge
                    )
                    Text(item.sourceName)
                        .lineLimit(1)
                    Text("·")
                    if item.publishedAt != nil {
                        Text(RelativeTime.relative(item.publishedAt))
                    } else {
                        Text("时间未知")
                    }
                }
                .font(Typography.meta)
                .foregroundColor(Theme.textTertiary)
            }

            Spacer(minLength: 0)
            cover
        }
        .padding(14)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var cover: some View {
        if let cover = item.coverURL, let url = URL(string: cover) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    placeholder
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            placeholder
                .frame(width: 56, height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.surfaceElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Theme.border, lineWidth: 1)
                )
        }
    }

    private var placeholder: some View {
        LetterAvatar(name: item.sourceName, size: 24)
            .frame(width: 56, height: 56)
    }
}
