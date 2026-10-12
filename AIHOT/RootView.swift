import SwiftUI

struct RootView: View {

    @AppStorage(AppSettings.appearanceKey) private var appearance: String = AppSettings.Appearance.system.rawValue

    // 三块界面都要看到同一份状态，所以在顶层各持有一个实例、按构造器往下传。
    // 这个代码库里没有 EnvironmentObject，不为了这两个 store 引入。
    @StateObject private var hot = HotTopicsStore()
    @StateObject private var favorites = FavoritesStore()

    var body: some View {
        TabView {
            HotListView(store: hot, favorites: favorites)
                .tabItem { Label("热点", systemImage: "flame") }

            FavoritesListView(hot: hot, favorites: favorites)
                .tabItem { Label("收藏", systemImage: "bookmark") }

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
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
