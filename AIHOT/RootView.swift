import SwiftUI

struct RootView: View {

    @AppStorage(AppSettings.appearanceKey) private var appearance: String = AppSettings.Appearance.system.rawValue

    var body: some View {
        HotListView()
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
