import SwiftUI

/// 「周报」Tab 根视图：周报/月报分段切换 + 最新一期全文 + 往期按月分组。
///
/// 与模型榜相反，这里的数据走公开 JSON 接口（带 ETag、s-maxage=300，规则 19），
/// 结构对齐 `LeaderboardView`：Tab 内自带 NavigationStack，下拉/前台/切段都会刷新。
///
/// 「最新一期」跟分段控件走；「往期」是官网的**另一个**板块，所以自带一个
/// 下拉，能独立切到另一栏（`pastKind`）。两者各拉各的、各节流各的。
struct ReportTabView: View {

    @ObservedObject var store: ReportStore

    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedKind: ReportKind = .weekly
    /// 往期那一块**独立**跟随一个栏目：官网的「最新一期」与「往期」是两个板块，
    /// 并成一个切换反而少了能力 —— 所以分段控件管最新一期，这里的下拉管往期。
    @State private var pastKind: ReportKind = .weekly
    @State private var webLink: WebLinkSheet?
    /// Tab 切走后本视图仍然活着（TabView 不销毁），所以「已读」只能在本视图
    /// 真正可见时写 —— 否则在别的 Tab 里收到角标检查结果也会被顺手清掉。
    @State private var isVisible = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.cardSpacing) {
                    kindPicker

                    if let header = store.headerText(for: selectedKind) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(header)
                                .font(Typography.meta)
                                .foregroundColor(Theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            webButton
                        }
                    } else {
                        webButton
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    if let notice = store.notice(for: selectedKind) {
                        NoticeBanner(notice: notice)
                    }

                    latestSection

                    pastSection

                    attributionFooter
                }
                .padding(.horizontal, Metrics.horizontalPadding)
                .padding(.bottom, 32)
            }
            .background(Theme.background.ignoresSafeArea())
            .refreshable { await store.refresh(kind: selectedKind) }
            .navigationTitle(selectedKind == .weekly ? "AI 周报" : "AI 月报")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: ReportEntry.self) { entry in
                // 按条目自己的栏取数：往期区块有独立下拉，索引条目从哪一栏来
                // 不再等于分段控件当前那一栏（用 selectedKind 会拿错接口）
                ReportDetailView(store: store, kind: entry.kind ?? selectedKind, entry: entry)
            }
            .navigationDestination(for: PeriodReport.Item.self) { item in
                ReportItemDetailView(item: item)
            }
        }
        .tint(Theme.accent)
        // 冷启动只拉当前分段（月报等用户切过去再拉），见规则 19。
        .task { await store.loadIfNeeded(kind: selectedKind) }
        .onAppear {
            isVisible = true
            store.markSeen(selectedKind)
        }
        .onDisappear { isVisible = false }
        // 切周期立刻拉那个周期（refresh 内部自己节流），并把这个周期记为已读
        .onChange(of: selectedKind) { kind in
            // 往期跟着分段走一次，之后可以自己再改（两块本就是两个板块）
            pastKind = kind
            store.markSeen(kind)
            Task { await store.refresh(kind: kind) }
        }
        // 停在本页时最新一期变了（角标检查或下拉刷新拿到新期）→ 立刻算已读
        .onChange(of: store.state(for: selectedKind).latest?.periodKey) { _ in
            if isVisible { store.markSeen(selectedKind) }
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task { await store.refresh(kind: selectedKind) }
        }
        .webLinkSheet(item: $webLink)
    }

    // MARK: - 周期切换

    private var kindPicker: some View {
        Picker("周期", selection: $selectedKind) {
            ForEach(ReportKind.allCases) { kind in
                Text(kind.title).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .padding(.top, 4)
    }

    /// 「网页版」：跟页头行同一次出现（同模型榜「怎么算」的位次，不占顶栏）。
    private var webButton: some View {
        Button {
            webLink = WebLinkSheet(url: store.webURL(for: selectedKind))
        } label: {
            Text("网页版")
                .font(Typography.meta)
                .foregroundColor(Theme.accent)
        }
        .accessibilityLabel("在网页查看本期报告")
    }

    // MARK: - 最新一期

    @ViewBuilder
    private var latestSection: some View {
        let state = store.state(for: selectedKind)
        if let report = state.latest {
            ReportIssueView(report: report)
        } else if state.hasLoaded {
            EmptyStateView(
                title: "暂时取不到最新一期",
                message: store.notice(for: selectedKind)?.message ?? "下拉即可重试，或稍后再来看看。",
                actionTitle: "重新加载",
                action: { Task { await store.refresh(kind: selectedKind) } },
                systemImage: "newspaper"
            )
        } else {
            ForEach(0..<3, id: \.self) { _ in
                SkeletonCard()
            }
        }
    }

    // MARK: - 往期

    @ViewBuilder
    private var pastSection: some View {
        let state = store.state(for: pastKind)
        let entries = state.entries

        pastHeader

        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.cardSpacing) {
                ForEach(Array(ReportPeriod.groupByMonth(entries).enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title)
                            .font(Typography.meta)
                            .foregroundColor(Theme.textTertiary)
                            .padding(.top, 6)

                        VStack(spacing: 0) {
                            ForEach(group.entries.indices, id: \.self) { index in
                                let entry = group.entries[index]
                                NavigationLink(value: entry) {
                                    ReportEntryRow(entry: entry)
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 14)

                                if index < group.entries.count - 1 {
                                    Hairline().padding(.leading, 14)
                                }
                            }
                        }
                        .cardBackground()
                    }
                }
            }
        } else if pastKind != selectedKind, state.hasLoaded || store.notice(for: pastKind) != nil {
            // 分段那一栏的失败由页面顶部的横幅负责，这里只补**另一栏**的情况 ——
            // 否则同一条提示会同时出现在两处。被限流（还没拉成）也算，不然骨架屏会一直转。
            Text(store.notice(for: pastKind)?.message ?? "往期\(pastKind.title)暂时取不到，下拉即可重试。")
                .font(Typography.meta)
                .foregroundColor(Theme.textTertiary)
                .padding(.top, 2)
        } else {
            // 还没拉过（冷启动只拉当前分段，规则 19）—— 不给骨架屏的话，
            // 下拉切过去会是一片空白，像坏了
            ForEach(0..<2, id: \.self) { _ in
                SkeletonCard()
            }
        }
    }

    /// 标题跟**往期自己**的那一栏走；右端按钮写的是「往点的那个」——
    /// 点它就是切过去，所以按钮上写目标栏目名，不是当前选中的。
    private var pastHeader: some View {
        HStack(spacing: 10) {
            SectionTitle(text: "往期" + pastKind.title)
            Spacer(minLength: 8)
            pastKindMenu
        }
    }

    private var otherKind: ReportKind {
        pastKind == .weekly ? .monthly : .weekly
    }

    private var pastKindMenu: some View {
        Menu {
            ForEach(ReportKind.allCases) { kind in
                Button {
                    pastKind = kind
                    // refresh 内部自己节流；这一栏从没拉过时会立即放行
                    Task { await store.refresh(kind: kind) }
                } label: {
                    if kind == pastKind {
                        Label("往期" + kind.title, systemImage: "checkmark")
                    } else {
                        Text("往期" + kind.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("往期" + otherKind.title)
                    .font(Typography.meta)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundColor(Theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(
                Capsule().stroke(Theme.border, lineWidth: 1)
            )
        }
        .accessibilityLabel("切换往期栏目")
    }

    // MARK: - 页脚

    /// 仿 `LeaderboardView.attributionFooter`（本地拼装，链到本期回链）——
    /// 不动共用的 `AttributionFooter`，它硬编码的是官网首页。
    private var attributionFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Hairline()
            HStack(spacing: 4) {
                Text("数据来源：")
                Button {
                    webLink = WebLinkSheet(url: store.webURL(for: selectedKind))
                } label: {
                    Text("AIHOT \(selectedKind.title)").underline()
                }
            }
            .font(Typography.meta)
            .foregroundColor(Theme.textTertiary)

            Text("内容版权归 AIHOT 及各原始来源所有，本 App 仅供个人使用。")
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(.top, 10)
    }
}

/// 往期一行：期号标题 + 区间 + headline 截断。
struct ReportEntryRow: View {

    let entry: ReportEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(titleLine)
                    .font(Typography.rowTitle)
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let range = ReportPeriod.rangeText(start: entry.periodStart, end: entry.periodEnd) {
                    Text(range)
                        .font(Typography.meta)
                        .foregroundColor(Theme.textTertiary)
                }

                if let headline = entry.headline, !headline.isEmpty {
                    Text(headline)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    /// 「2026 年第 41 周」；期号认不出就退回原文（宁可显示 2026-W41，不可显示错的中文）。
    private var titleLine: String {
        guard let key = entry.periodKey else { return "未知期号" }
        return ReportPeriod.title(periodKey: key) ?? key
    }
}
