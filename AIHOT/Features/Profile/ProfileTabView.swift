import SwiftUI

/// 「个人」tab：收藏与设置的入口，外加订阅的概况。
///
/// 这里是**最后一个 tab**（下标 4），`AIHOTUITests` 仍按下标取它；
/// 但设置已经变成二级页，用例要多点一步（见 SearchToolSettingsUITests）。
/// 这个视图持有本 tab 唯一的 `NavigationStack`，被 push 的收藏/设置不再自带栈。
struct ProfileTabView: View {

    @ObservedObject var hot: HotTopicsStore
    @ObservedObject var favorites: FavoritesStore
    @ObservedObject var reports: ReportStore
    @ObservedObject var subscriptions: SubscriptionStore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        FavoritesListView(hot: hot, favorites: favorites)
                    } label: {
                        HStack {
                            Label("收藏", systemImage: "bookmark")
                            Spacer()
                            Text("\(favorites.items.count) 条")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                    .accessibilityIdentifier("profile-favorites")

                    NavigationLink {
                        AboutView(
                            store: hot,
                            favorites: favorites,
                            reports: reports,
                            subscriptions: subscriptions
                        )
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("profile-settings")
                } header: {
                    Text("我的")
                } footer: {
                    Text("收藏、设置与对话记录只保存在这台 iPhone 上。")
                }

                Section("订阅") {
                    LabeledContent("公众号", value: "\(subscriptions.enabledWeChatCount) 个")
                    LabeledContent("B 站", value: "\(subscriptions.enabledBilibiliCount) 个")
                    LabeledContent("内容", value: "\(subscriptions.items.count) 条")
                    LabeledContent("更新", value: subscriptions.lastUpdatedText)
                }

                Section("关于") {
                    LabeledContent("版本", value: versionText)
                    LabeledContent("用途", value: "个人使用")
                }

                Section {
                    Text("内容版权归 AIHOT、微信公众号原作者与哔哩哔哩 UP 主所有。本 App 仅作个人阅读使用，不对外分发、不用于商业用途。")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .navigationTitle("个人")
            .navigationBarTitleDisplayMode(.large)
            // 收藏行点进去要能推到 story 详情；destination 注册在栈根，
            // 被 push 的 FavoritesListView 自己不再注册（避免两层栈/两层 destination）。
            .navigationDestination(for: HotTopic.self) { item in
                StoryDetailView(
                    item: item,
                    favorites: favorites,
                    prefetchedDigest: hot.digest(for: item)
                )
            }
        }
        .tint(Theme.accent)
    }

    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        return "\(version) (\(build))"
    }
}
