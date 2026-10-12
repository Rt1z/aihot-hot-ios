import Foundation

/// 轻量设置项（与 AboutView 里的 @AppStorage 共用同一批 key）。
enum AppSettings {

    static let appearanceKey = "aihot.appearance"
    static let enrichmentKey = "aihot.enrichment.enabled"

    enum Appearance: String, CaseIterable, Identifiable {
        case system
        case dark
        case light

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: return "跟随系统"
            case .dark: return "深色"
            case .light: return "浅色"
            }
        }
    }

    /// 默认开启：失败时 HotPageEnricher 会返回 nil，界面自动退回 API 字段。
    static var isEnrichmentEnabled: Bool {
        get {
            if let value = UserDefaults.standard.object(forKey: enrichmentKey) as? Bool {
                return value
            }
            return true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enrichmentKey)
        }
    }
}
