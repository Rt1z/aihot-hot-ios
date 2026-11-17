import SwiftUI

/// 往期某一期的详情页：`store.report(kind:period:)` 取全文，正文复用 `ReportIssueView`。
/// 已发布的期次不可变（store 内存永久缓存），所以只在首次进入时真正发请求。
struct ReportDetailView: View {

    @ObservedObject var store: ReportStore

    let kind: ReportKind
    let entry: ReportEntry

    @State private var report: PeriodReport?
    @State private var isLoading = true
    @State private var webLink: WebLinkSheet?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.cardSpacing) {
                if let report = report {
                    ReportIssueView(report: report)
                } else if isLoading {
                    ForEach(0..<3, id: \.self) { _ in
                        SkeletonCard()
                    }
                } else {
                    EmptyStateView(
                        title: "暂时取不到这一期",
                        message: "网络或接口异常，稍后重试；也可以点右上角「网页版」直接看官网。",
                        actionTitle: "重新加载",
                        action: { Task { await load() } },
                        systemImage: "newspaper"
                    )
                }
            }
            .padding(.horizontal, Metrics.horizontalPadding)
            .padding(.bottom, 32)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(titleText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    webLink = WebLinkSheet(url: pageURL)
                } label: {
                    Text("网页版")
                        .font(Typography.meta)
                        .foregroundColor(Theme.accent)
                }
                .accessibilityLabel("在网页查看这一期")
            }
        }
        .task { await load() }
        .webLinkSheet(item: $webLink)
    }

    /// 顶栏标题：「2026 年第 41 周」；期号认不出退回原文。
    private var titleText: String {
        guard let key = entry.periodKey else { return "往期报告" }
        return ReportPeriod.title(periodKey: key) ?? key
    }

    /// 回链优先级：已取到的全文 > 索引条目 > 栏目页兜底（「网页版」是唯一逃生口，必须总能点）。
    private var pageURL: URL {
        if let link = report?.links?.aihot ?? entry.links?.aihot, let url = URL(string: link) {
            return url
        }
        return URL(string: "https://aihot.news\(kind.webPath)")!
    }

    private func load() async {
        // 内存里已有（回看、或切栈回来）就直接用，不重发请求；
        // 期号缺失是数据坏（索引里没有 periodKey），直接落到空态
        guard report == nil, let period = entry.periodKey else {
            isLoading = false
            return
        }
        isLoading = true
        report = await store.report(kind: kind, period: period)
        isLoading = false
    }
}
