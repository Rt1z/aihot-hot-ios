import SwiftUI

struct RootView: View {

    @AppStorage(AppSettings.appearanceKey) private var appearance: String = AppSettings.Appearance.system.rawValue

    // 几块界面都要看到同一份状态，所以在顶层各持有一个实例、按构造器往下传。
    // 这个代码库里没有 EnvironmentObject，不为了这些 store 引入。
    @StateObject private var hot = HotTopicsStore()
    @StateObject private var favorites = FavoritesStore()
    @StateObject private var leaderboard = LeaderboardStore()

    var body: some View {
        TabView {
            HotListView(store: hot, favorites: favorites)
                .tabItem { Label("热点", systemImage: "flame") }

            FavoritesListView(hot: hot, favorites: favorites)
                .tabItem { Label("收藏", systemImage: "bookmark") }

            // 模型榜插在收藏和设置之间：「设置」保持最后是 iOS 惯例。
            // 注意 AIHOTUITests 按下标取「设置」Tab，插位要同步改那边的 boundBy。
            LeaderboardView(store: leaderboard)
                .tabItem { Label("模型榜", systemImage: "chart.bar.xaxis") }

            AboutView(store: hot, favorites: favorites)
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .tint(Theme.accent)
        .preferredColorScheme(colorScheme)
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
