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

    var body: some View {
        TabView {
            HotListView(store: hot, favorites: favorites)
                .tabItem { Label("热点", systemImage: "flame") }

            FavoritesListView(hot: hot, favorites: favorites)
                .tabItem { Label("收藏", systemImage: "bookmark") }

            // 模型榜/周报插在收藏和设置之间：「设置」保持最后是 iOS 惯例。
            // 注意 AIHOTUITests 按下标取「设置」Tab，插位要同步改那边的 boundBy。
            LeaderboardView(store: leaderboard)
                .tabItem { Label("模型榜", systemImage: "chart.bar.xaxis") }

            ReportTabView(store: reports)
                .tabItem { Label("周报", systemImage: "newspaper") }
                // 有新一期就挂「新」；两边期号缺失时 `ReportUnread` 一律返回 false
                // （新装用户第一次看到某一期只补基线，不挂角标）。
                .badge(reportBadge)

            AboutView(store: hot, favorites: favorites, reports: reports)
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .tint(Theme.accent)
        .preferredColorScheme(colorScheme)
        // 角标只查「最新一期」（不拉索引、不动 Tab 的刷新节流），失败保持安静。
        .task { await reports.checkForNewReports() }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task { await reports.checkForNewReports() }
        }
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
struct AIHOTApp: App {

    init() {
        // UI 测试钩子：带这个启动参数就重置搜索工具的顺序/开关，让用例从确定
        // 状态出发（用例**首次**启动传，验证持久化的第二次启动不传）。
        // 只有 Xcode / 模拟器能塞启动参数，AltStore 正常安装使用永远见不到这个分支。
        if ProcessInfo.processInfo.arguments.contains("uitests-reset-search-settings") {
            AppSettings.resetSearchToolsForUITests()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
