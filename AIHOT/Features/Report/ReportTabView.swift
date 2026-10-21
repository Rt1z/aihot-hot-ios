import SwiftUI

/// 「周报」Tab 根视图：周报/月报分段切换 + 所选一期的全文 + 往期按月分组。
///
/// 与模型榜相反，这里的数据走公开 JSON 接口（带 ETag、s-maxage=300，规则 19），
/// 结构对齐 `LeaderboardView`：Tab 内自带 NavigationStack，下拉/前台/切段都会刷新。
///
/// **两个切换各管一件事**：分段控件（`selectedKind`）管**栏目** —— 最新一期、
/// 往期列表、下拉里的期次全是同一栏；分段控件**正下方**的下拉管「**看哪一期**」
/// （`selectedPeriod`）—— 列出当前栏的期次，选中往期就把上方正文就地换成那一期。
/// 切栏目时选择重置回最新一期：期号是栏目内的（周报 W41 与月报 2026-09 不是一回事）。
struct ReportTabView: View {

    @ObservedObject var store: ReportStore

    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedKind: ReportKind = .weekly
    /// 下拉选中的期号；nil = 看最新一期。往期不可变，选回去不用重新请求。
    @State private var selectedPeriod: String?
    @State private var olderReport: PeriodReport?
    @State private var isLoadingOlder = false
    @State private var webLink: WebLinkSheet?
    /// Tab 切走后本视图仍然活着（TabView 不销毁），所以「已读」只能在本视图
    /// 真正可见时写 —— 否则在别的 Tab 里收到角标检查结果也会被顺手清掉。
    @State private var isVisible = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.cardSpacing) {
                    kindPicker

                    // 「看哪一期」的下拉就贴在分段控件下面（两行控件挨在一起才是
                    // 一组切换），右对齐 —— 这一行没有别的内容，靠左会像标题
                    HStack {
                        Spacer(minLength: 8)
                        if !store.state(for: selectedKind).entries.isEmpty {
                            issueMenu
                        }
                    }

                    if let header = headerText {
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

                    issueSection

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
                // 按条目自己的栏取数：索引条目自带栏目，不要拿当前分段去猜
                // （用 selectedKind 一旦与条目不同栏就会打错端点）
                ReportDetailView(store: store, kind: entry.kind ?? selectedKind, entry: entry)
            }
            .navigationDestination(for: PeriodReport.Item.self) { item in
                ReportItemDetailView(store: store, item: item)
            }
        }
        .tint(Theme.accent)
        // 冷启动只拉当前分段（月报等用户切过去再拉），见规则 19。
        .task { await store.loadIfNeeded(kind: selectedKind) }
        // 下拉选中的期次变了才取数：往期不可变，store 内存永久缓存，回看不打网络。
        // 切栏目也会换 key（selectionKey 里带着 selectedKind），旧任务随之取消。
        .task(id: issueSelectionKey) { await loadSelectedIssue() }
        .onAppear {
            isVisible = true
            store.markSeen(selectedKind)
        }
        .onDisappear { isVisible = false }
        // 切周期立刻拉那个周期（refresh 内部自己节流），并把这个周期记为已读
        .onChange(of: selectedKind) { kind in
            // 期号是栏目内的，切栏目就回最新一期（否则会拿周报的期号去打月报端点）
            selectedPeriod = nil
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

    /// 页头那行期号信息：跟着**正在看的那一期**走（下拉选了往期就说往期的）。
    private var headerText: String? {
        if let period = selectedPeriod,
           let entry = store.state(for: selectedKind).entries.first(where: { $0.periodKey == period }) {
            var parts: [String] = [issueTitle(entry)]
            if let range = ReportPeriod.rangeText(start: entry.periodStart, end: entry.periodEnd) {
                parts.append(range)
            }
            return parts.joined(separator: " · ")
        }
        return store.headerText(for: selectedKind)
    }

    /// 「网页版」：跟页头行同一次出现（同模型榜「怎么算」的位次，不占顶栏）。
    private var webButton: some View {
        Button {
            webLink = WebLinkSheet(url: currentWebURL)
        } label: {
            Text("网页版")
                .font(Typography.meta)
                .foregroundColor(Theme.accent)
        }
        .accessibilityLabel("在网页查看本期报告")
    }

    /// 回链跟着**正在看的那一期**：往期优先用索引条目里的回链，取不到就用
    /// 已取到的全文回链，再不行退回栏目页 —— 这个按钮是唯一逃生口，必须总能点。
    private var currentWebURL: URL {
        if let period = selectedPeriod {
            let state = store.state(for: selectedKind)
            if let link = state.entries.first(where: { $0.periodKey == period })?.links?.aihot,
               let url = URL(string: link) {
                return url
            }
            if let link = olderReport?.links?.aihot, let url = URL(string: link) {
                return url
            }
        }
        return store.webURL(for: selectedKind)
    }

    // MARK: - 正在看的那一期

    @ViewBuilder
    private var issueSection: some View {
        if selectedPeriod != nil {
            olderSection
        } else {
            latestSection
        }
    }

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

    /// 下拉选中的往期某一期：就地替换「最新一期」那一块。
    @ViewBuilder
    private var olderSection: some View {
        if let report = olderReport {
            ReportIssueView(report: report)
        } else if isLoadingOlder {
            ForEach(0..<3, id: \.self) { _ in
                SkeletonCard()
            }
        } else {
            EmptyStateView(
                title: "暂时取不到这一期",
                message: "网络或接口异常，稍后重试；也可以点「网页版」直接看官网。",
                actionTitle: "重新加载",
                action: { Task { await loadSelectedIssue() } },
                systemImage: "newspaper"
            )
        }
    }

    private var issueSelectionKey: String {
        selectedKind.rawValue + "|" + (selectedPeriod ?? "")
    }

    private func loadSelectedIssue() async {
        guard let period = selectedPeriod else {
            olderReport = nil
            isLoadingOlder = false
            return
        }
        isLoadingOlder = true
        // 先把栏目抓在手里：await 期间用户可能切了分段，那份结果就过期了
        let kind = selectedKind
        let report = await store.report(kind: kind, period: period)
        guard kind == selectedKind, period == selectedPeriod else { return }
        olderReport = report
        isLoadingOlder = false
    }

    // MARK: - 往期

    @ViewBuilder
    private var pastSection: some View {
        let entries = store.state(for: selectedKind).entries

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
        } else if !store.state(for: selectedKind).hasLoaded {
            // 还没拉过（冷启动只拉当前分段，规则 19）—— 不给骨架屏的话，
            // 切过去会是一片空白，像坏了
            ForEach(0..<2, id: \.self) { _ in
                SkeletonCard()
            }
        }
        // 已经拉过但没有往期：原因（索引失败/被限流）由页面顶部的横幅说了，
        // 这里不再重复一句，也不留永远转不动的骨架屏
    }

    /// 标题跟着分段控件那一栏走（选期的下拉在分段控件下面，不在这儿）。
    private var pastHeader: some View {
        SectionTitle(text: "往期" + selectedKind.title)
    }

    /// 按钮上写的是**当前正在看**的那一期；点开列出「最新一期」+ 往期各期（按月分组）。
    private var issueMenu: some View {
        let entries = store.state(for: selectedKind).entries
        return Menu {
            Button {
                selectedPeriod = nil
            } label: {
                if selectedPeriod == nil {
                    Label("最新一期", systemImage: "checkmark")
                } else {
                    Text("最新一期")
                }
            }
            ForEach(Array(ReportPeriod.groupByMonth(entries).enumerated()), id: \.offset) { _, group in
                Section(group.title) {
                    ForEach(group.entries) { entry in
                        Button {
                            selectedPeriod = entry.periodKey
                        } label: {
                            if entry.periodKey == selectedPeriod {
                                Label(issueTitle(entry), systemImage: "checkmark")
                            } else {
                                Text(issueTitle(entry))
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(currentIssueTitle)
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
        .accessibilityLabel("选择要查看的期次")
    }

    /// 下拉按钮上写的那一期：选了往期写期号，否则「最新一期」。
    private var currentIssueTitle: String {
        guard let period = selectedPeriod else { return "最新一期" }
        if let entry = store.state(for: selectedKind).entries.first(where: { $0.periodKey == period }) {
            return issueTitle(entry)
        }
        return ReportPeriod.title(periodKey: period) ?? period
    }

    private func issueTitle(_ entry: ReportEntry) -> String {
        guard let key = entry.periodKey else { return "未知期号" }
        return ReportPeriod.title(periodKey: key) ?? key
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
                    webLink = WebLinkSheet(url: currentWebURL)
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
