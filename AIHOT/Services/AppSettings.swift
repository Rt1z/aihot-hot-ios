import Foundation

/// 轻量设置项（与 AboutView 里的 @AppStorage 共用同一批 key）。
enum AppSettings {

    static let appearanceKey = "aihot.appearance"
    static let enrichmentKey = "aihot.enrichment.enabled"
    /// 收藏的落盘位置。用 UserDefaults 而不是 Caches：见 FavoritesStore 的注释。
    static let favoritesKey = "aihot.favorites"

    // MARK: - AI 对话
    //
    // 只放非敏感项。API Key 走 Keychain（见 AIChatSecretStore）。
    // 两个协议各存各的地址与模型：切协议是「换一条线」，不该把另一条线的配置冲掉。
    // 也刻意不用「由一个 @AppStorage 算出另一个键」的写法 —— 那样每次 body 求值
    // 都会重建包装器，会读到陈旧值。

    static let aiChatProtocolKey = "aihot.aichat.protocol"
    static let aiChatAnthropicBaseURLKey = "aihot.aichat.anthropic.baseURL"
    static let aiChatAnthropicModelKey = "aihot.aichat.anthropic.model"
    static let aiChatOpenAIBaseURLKey = "aihot.aichat.openai.baseURL"
    static let aiChatOpenAIModelKey = "aihot.aichat.openai.model"
    /// 密钥降级存储用的前缀（正常情况走 Keychain）。
    static let aiChatFallbackSecretPrefix = "aihot.aichat.fallback."

    static var aiChatProtocol: AIChatProtocol {
        get {
            guard let raw = UserDefaults.standard.string(forKey: aiChatProtocolKey),
                  let value = AIChatProtocol(rawValue: raw)
            else { return .anthropicMessages }
            return value
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: aiChatProtocolKey)
        }
    }

    static func aiChatBaseURLKey(for chatProtocol: AIChatProtocol) -> String {
        switch chatProtocol {
        case .anthropicMessages: return aiChatAnthropicBaseURLKey
        case .openAICompatible: return aiChatOpenAIBaseURLKey
        }
    }

    static func aiChatModelKey(for chatProtocol: AIChatProtocol) -> String {
        switch chatProtocol {
        case .anthropicMessages: return aiChatAnthropicModelKey
        case .openAICompatible: return aiChatOpenAIModelKey
        }
    }

    /// AnySearch 的 Key。**可选**：不填就走匿名（限速更低），联网搜索照样能用。
    static func anySearchKey() -> String {
        AIChatSecretStore.shared.anySearchKey()
    }

    /// 按当前设置解析出一份可用配置；没配好（或没填 Key）返回 nil。
    static func currentAIChatConfig() -> AIChatConfig? {
        let defaults = UserDefaults.standard
        let chatProtocol = aiChatProtocol
        return AIChatConfig.resolve(
            chatProtocol: chatProtocol,
            baseURLRaw: defaults.string(forKey: aiChatBaseURLKey(for: chatProtocol)) ?? "",
            modelRaw: defaults.string(forKey: aiChatModelKey(for: chatProtocol)) ?? "",
            apiKey: AIChatSecretStore.shared.key(for: chatProtocol)
        )
    }

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
