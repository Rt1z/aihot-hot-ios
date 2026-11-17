import SwiftUI

struct RootView: View {

    @AppStorage(AppSettings.appearanceKey) private var appearance: String = AppSettings.Appearance.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    // 几块界面都要看到同一份状态，所以在顶层各持有一个实例、按构造器往下传。
    // 这个代码库里没有 EnvironmentObject，不为了这些 store 引入。
    @StateObject private var hot = HotTopicsStore()
    @StateObject private var favorites = FavoritesStore()
    @StateObject private var leaderboard = LeaderboardStore()
    @StateObject private var reports = ReportStore()
    /// 练习记录（用户数据）由顶层持有，按构造器下传 —— 详情页与收藏 tab
    /// 看到的是同一份列表。
    @StateObject private var practice = PracticeStore()

    /// 显式 selection：`aihot://add` 进来时要把用户带到收藏 tab。
    /// 顺序仍是 热点 | 周报 | 模型榜 | 收藏 | 设置。
    private enum Tab: Hashable {
        case hot
        case report
        case leaderboard
        case favorites
        case settings
    }

    @State private var selectedTab: Tab = .hot
    @State private var pendingAlert: PendingAlert?
    /// 待打开的文章 URL：由快捷指令 / `aihot://add` 设置，收藏页消费后自动 push 详情。
    @State private var pendingOpenLinkURL: String?

    /// 链接格式错误的提示。剪贴板确认走独立 sheet（里面用系统 PasteButton，
    /// 避免 iOS 16 的二次粘贴授权）。
    private enum PendingAlert: Identifiable {
        case invalidLink(String)

        var id: String { "invalid-link" }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            HotListView(store: hot, favorites: favorites, practice: practice)
                .tabItem { Label("热点", systemImage: "flame") }
                .tag(Tab.hot)

            ReportTabView(store: reports, practice: practice)
                .tabItem { Label("周报", systemImage: "newspaper") }
                // 有新一期就挂「新」；两边期号缺失时 `ReportUnread` 一律返回 false
                // （新装用户第一次看到某一期只补基线，不挂角标）。
                .badge(reportBadge)
                .tag(Tab.report)

            LeaderboardView(store: leaderboard)
                .tabItem { Label("模型榜", systemImage: "chart.bar.xaxis") }
                .tag(Tab.leaderboard)

            FavoritesListView(
                hot: hot,
                favorites: favorites,
                practice: practice,
                pendingOpenLinkURL: $pendingOpenLinkURL
            )
            .tabItem { Label("收藏", systemImage: "bookmark") }
            .tag(Tab.favorites)

            // 顺序：热点 | 周报 | 模型榜 | 收藏 | 设置，「设置」保持最后是 iOS 惯例。
            // 注意 InOutUITests 按下标取「设置」Tab，只要它还在最后就不必改 boundBy；
            // 插入/调换**设置之前**的 Tab 才要同步改那边的 boundBy。
            AboutView(store: hot, favorites: favorites, reports: reports)
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(Theme.accent)
        .preferredColorScheme(colorScheme)
        // 角标只查「最新一期」（不拉索引、不动 Tab 的刷新节流），失败保持安静。
        .task { await reports.checkForNewReports() }
        // 「收藏并打开」快捷指令的待处理文章（冷启动时通知可能早于订阅）：
        // 先立刻消费一次，再等半秒补一次 —— Intent 的 perform 可能比 RootView 还晚。
        .task { consumeOpenLinkRequest() }
        .task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            consumeOpenLinkRequest()
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            // 快捷指令 / 分享入口可能在另一个实例里写过收藏：回前台时重读一次
            favorites.reload()
            consumeOpenLinkRequest()
            Task { await reports.checkForNewReports() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .aihotOpenLink)) { _ in
            consumeOpenLinkRequest()
        }
        // 分享入口：aihot://add?url=…&title=…；快捷指令也可用 aihot://favorites
        .onOpenURL { handleIncomingLink($0) }
        .alert(item: $pendingAlert) { alert in
            switch alert {
            case .invalidLink(let message):
                return Alert(
                    title: Text("无法添加链接"),
                    message: Text(message),
                    dismissButton: .default(Text("好"))
                )
            }
        }
    }

    /// 把外部链接收进收藏，并切到收藏 tab 让用户看见。
    ///
    /// 标题缺省时先以域名入列表，再异步抓一次标题原地更新 —— 抓取失败不影响
    /// 收藏本身（标题不是链接的必需品）。
    private func handleIncomingLink(_ incoming: URL) {
        // aihot://favorites：快捷指令 / 其它 App 直接打开收藏页
        if incoming.scheme?.lowercased() == "aihot",
           incoming.host?.lowercased() == "favorites" {
            selectedTab = .favorites
            return
        }

        guard let outcome = SavedLinkImporter.importLink(from: incoming, into: favorites) else {
            pendingAlert = .invalidLink("链接格式不对。需要 aihot://add?url=…，且指向公开的 http/https 网页。")
            return
        }

        // 与快捷指令同一条路径：切到收藏，并直接打开这篇文章
        AppSettings.pendingOpenLinkURL = outcome.url
        consumeOpenLinkRequest()

        // 没带标题就先以域名入列表，再抓一次标题原地更新
        guard outcome.added, outcome.title == nil else { return }
        Task {
            if let url = URL(string: outcome.url),
               let title = await LinkTitleService.fetch(url: url) {
                favorites.updateLinkTitle(url: outcome.url, title: title)
            }
        }
    }

    /// 快捷指令「收藏并打开」的待处理文章：消费一次就清掉。
    /// 三个时机都要调（启动 / 回前台 / 收到通知），冷启动时才不会漏。
    private func consumeOpenLinkRequest() {
        guard let url = AppSettings.pendingOpenLinkURL else { return }
        AppSettings.pendingOpenLinkURL = nil
        favorites.reload()
        pendingOpenLinkURL = url
        selectedTab = .favorites
    }

    /// 显式写成 `Text?`：`.badge` 有好几个重载，直接传条件表达式会让类型推断犯难。
    private var reportBadge: Text? {
        reports.hasUnreadReport ? Text("新") : nil
    }

    private var colorScheme: ColorScheme? {
        switch AppSettings.Appearance(rawValue: appearance) ?? .system {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

@main
struct InOutApp: App {

    init() {
        // UI 测试钩子：预置一条收藏并留下「待打开」请求，钉住
        // 快捷指令「收藏并打开」的消费与自动 push 路径。
        // 只有 Xcode / 模拟器能塞启动参数，AltStore 正常安装使用永远见不到。
        let prefix = "uitests-open-link="
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }),
           let normalized = SharedLinkURL.normalized(String(argument.dropFirst(prefix.count))) {
            let store = FavoritesStore()
            store.add(link: SavedLink(url: normalized.absoluteString, title: "UITest Article"))
            AppSettings.pendingOpenLinkURL = normalized.absoluteString
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
