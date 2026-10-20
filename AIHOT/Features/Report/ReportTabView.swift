import SwiftUI

/// 「周报」Tab 根视图：周报/月报分段切换 + 最新一期全文 + 往期按月分组。
///
/// 与模型榜相反，这里的数据走公开 JSON 接口（带 ETag、s-maxage=300，规则 19），
/// 结构对齐 `LeaderboardView`：Tab 内自带 NavigationStack，下拉/前台/切段都会刷新。
struct ReportTabView: View {

    @ObservedObject var store: ReportStore

    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedKind: ReportKind = .weekly
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
                ReportDetailView(store: store, kind: selectedKind, entry: entry)
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
            ReportIssueView(report: report) { webLink = $0 }
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
        let entries = store.state(for: selectedKind).entries
        if !entries.isEmpty {
            SectionTitle(text: selectedKind == .weekly ? "往期周报" : "往期月报")

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
        }
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
