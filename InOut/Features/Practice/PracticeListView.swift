import SwiftUI

/// 练习本：全部练习记录 + 三个统计数字。
///
/// 从「收藏」tab push 进来（不新增 Tab：iOS 的 TabView 最多平铺 5 个，
/// 第 6 个会被收进「更多」）。历史**只读**：想再练一遍就走「再练一次」生成新记录，
/// 不在原地改写 —— 回看时看到的应该是当时那个你。
struct PracticeListView: View {

    @ObservedObject var store: PracticeStore

    var body: some View {
        Group {
            if store.entries.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("练习本")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var list: some View {
        List {
            Section {
                statsCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                ForEach(store.entries) { entry in
                    NavigationLink {
                        PracticeEntryView(store: store, entry: entry)
                    } label: {
                        row(entry)
                    }
                    .accessibilityIdentifier("practice-entry-row")
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            store.delete(id: entry.id)
                        } label: {
                            Label("删除这条练习", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("全部练习")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
    }

    private var statsCard: some View {
        let stats = store.stats()
        return HStack(spacing: 0) {
            stat(value: stats.total, label: "篇")
            statDivider
            stat(value: stats.thisWeek, label: "本周")
            statDivider
            stat(value: stats.streakDays, label: "连续天")
        }
        .frame(maxWidth: .infinity)
        .cardBackground()
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, 4)
    }

    private func stat(value: Int, label: String) -> some View {
        VStack(spacing: 3) {
            Text("\(value)")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(Theme.textPrimary)
            Text(label)
                .font(Typography.meta)
                .foregroundColor(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(width: 1, height: 28)
    }

    private func row(_ entry: PracticeEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entry.article.title)
                .font(Typography.rowTitle)
                .foregroundColor(Theme.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(RelativeTime.absoluteShort(entry.createdAt))
                Text(entry.mode.title)
                Text("\(entry.wordCount) 字")
                if entry.review != nil {
                    Label("已点评", systemImage: "sparkles")
                        .labelStyle(.titleAndIcon)
                }
                Spacer(minLength: 0)
            }
            .font(Typography.meta)
            .foregroundColor(Theme.textTertiary)
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        EmptyStateView(
            title: "练习本还是空的",
            message: "在热点或周报的详情页点右上角的「练一练」，写完就会收在这里。",
            systemImage: "square.and.pencil"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
