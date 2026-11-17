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

    // 搜索工具已统一为腾讯云元宝搜索（`TencentWSARunner`）。原来的五家顺序 /
    // 开关 / 旧单选键全部删除；元宝搜索的 SecretId / SecretKey 走 `AIChatSecretStore`。

    // MARK: - 周报/月报（Tab 角标）

    /// 每个栏目「上次看到的期号」。只用来算 Tab 角标，不参与内容判断；
    /// 与内容缓存分开存 —— 清缓存不该把「已读」也清掉。
    static func lastSeenReportKey(for kind: ReportKind) -> String {
        "aihot.reports.lastSeen.\(kind.rawValue)"
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

    // MARK: - 快捷指令：收藏并打开文章

    /// 一次性待处理标记：快捷指令冷启动 App 时，通知可能早于 RootView 订阅，
    /// 所以把「该打开哪篇文章」也落一次盘，RootView 启动/回前台时消费并清掉。
    static let pendingOpenLinkKey = "aihot.pendingOpenLink"

    static var pendingOpenLinkURL: String? {
        get { UserDefaults.standard.string(forKey: pendingOpenLinkKey) }
        set { UserDefaults.standard.set(newValue, forKey: pendingOpenLinkKey) }
    }

    // MARK: - 练习

    /// 上次用的写作形式：新练习默认沿用它（不做成设置项，用户感觉不到）。
    static let practiceModeKey = "aihot.practice.mode"

    static var practicePreferredMode: PracticeMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: practiceModeKey),
                  let mode = PracticeMode(rawValue: raw)
            else { return .structured }
            return mode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: practiceModeKey)
        }
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
