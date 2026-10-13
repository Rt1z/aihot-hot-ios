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
    /// 旧的搜索工具**单选**键（二选一时代的遗留）：**只读、仅作首次迁移的来源**，
    /// 用户第一次 reorder/toggle 之后 order 键落盘，这个键就被永久忽略，新代码不写它。
    /// Key 本身走 Keychain（见 AIChatSecretStore），这里存的只是「选了哪家」。
    static let aiChatSearchToolKey = "aihot.aichat.searchTool"
    /// 搜索工具的优先顺序（[rawValue]，数组顺序即优先级）。nil = 还没动过 → 读旧单选键迁移。
    static let aiChatSearchToolOrderKey = "aihot.aichat.searchToolOrder"
    /// 停用的搜索工具（[rawValue]，去重）。缺键 = 全启用（老用户无感）。
    static let aiChatSearchToolDisabledKey = "aihot.aichat.searchToolDisabled"
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

    /// 设置页里五家搜索工具（web_search / read_url 由谁执行、按什么顺序回退）。
    /// 工具声明（AIChatRequestBuilder）是提供方无关的，改顺序只换「谁来执行工具」，
    /// 请求体一行不动。**声明顺序 = 规范默认顺序**（anySearch 保持第一，老用户无感）。
    enum SearchToolProvider: String, CaseIterable, Identifiable {
        case anySearch
        case tavily
        case serpapi
        case exa
        case serper

        var id: String { rawValue }

        var title: String {
            switch self {
            case .anySearch: return "AnySearch"
            case .tavily: return "Tavily"
            case .serpapi: return "SerpAPI"
            case .exa: return "Exa"
            case .serper: return "Serper"
            }
        }

        /// 能不能替模型读网页正文（`read_url`）。SerpAPI / Serper 没有正文抽取产品，
        /// 链会自动跳过它们（能力矩阵，见 SearchToolChain）。
        var supportsReadURL: Bool {
            switch self {
            case .anySearch, .tavily, .exa: return true
            case .serpapi, .serper: return false
            }
        }

        /// 是不是必须填 Key 才能参与（AnySearch 可匿名：留空 Key 照样干活）。
        var requiresKey: Bool {
            switch self {
            case .anySearch: return false
            case .tavily, .serpapi, .exa, .serper: return true
            }
        }

        /// 设置页行内的能力标签。
        var capabilityTitle: String {
            supportsReadURL ? "搜索 + 读网页" : "仅搜索"
        }
    }

    // MARK: - 搜索工具顺序与开关（纯函数，镜像 15 钉）

    /// 规范化存储里的顺序：丢未知 rawValue、按首次出现去重、缺的追加到末尾
    /// （**前向兼容将来新增的提供方**）。`stored == nil`（用户从没 reorder 过）时
    /// 读旧的单选键：旧值排最前，其余按 allCases 补齐 —— 升级首启老用户的二选一
    /// 选择自动变成第一顺位。`stored == []` 也自愈为规范顺序。
    static func normalizeSearchToolOrder(stored: [String]?, legacySingleRaw: String?) -> [SearchToolProvider] {
        var seen = Set<SearchToolProvider>()
        var order: [SearchToolProvider] = []
        func append(_ provider: SearchToolProvider) {
            guard !seen.contains(provider) else { return }
            seen.insert(provider)
            order.append(provider)
        }
        if let stored = stored {
            for raw in stored {
                if let provider = SearchToolProvider(rawValue: raw) {
                    append(provider)
                }
            }
        } else if let legacy = legacySingleRaw, let provider = SearchToolProvider(rawValue: legacy) {
            append(provider)
        }
        for provider in SearchToolProvider.allCases {
            append(provider)
        }
        return order
    }

    /// 规范化停用列表：丢未知、去重。`nil`（用户从没动过开关）= 全启用 = 空集。
    static func normalizeSearchToolDisabled(stored: [String]?) -> Set<SearchToolProvider> {
        guard let stored = stored else { return [] }
        var disabled: Set<SearchToolProvider> = []
        for raw in stored {
            if let provider = SearchToolProvider(rawValue: raw) {
                disabled.insert(provider)
            }
        }
        return disabled
    }

    /// 搜索工具的优先顺序（数组顺序即优先级，链按它回退）。**读-穿规范化、不回写**：
    /// 用户第一次 reorder 时 order 键才落盘，此后旧单选键被永久忽略。
    static var searchToolOrder: [SearchToolProvider] {
        get {
            let defaults = UserDefaults.standard
            return normalizeSearchToolOrder(
                stored: defaults.stringArray(forKey: aiChatSearchToolOrderKey),
                legacySingleRaw: defaults.string(forKey: aiChatSearchToolKey)
            )
        }
        set {
            let rawValues = normalizeSearchToolOrder(stored: newValue.map(\.rawValue), legacySingleRaw: nil)
                .map(\.rawValue)
            UserDefaults.standard.set(rawValues, forKey: aiChatSearchToolOrderKey)
        }
    }

    /// 停用集合（缺键 = 全启用）。读-穿规范化、不回写。
    static var searchToolDisabled: Set<SearchToolProvider> {
        get {
            normalizeSearchToolDisabled(
                stored: UserDefaults.standard.stringArray(forKey: aiChatSearchToolDisabledKey)
            )
        }
        set {
            let rawValues = normalizeSearchToolDisabled(stored: newValue.map(\.rawValue))
                .map(\.rawValue)
                .sorted()
            UserDefaults.standard.set(rawValues, forKey: aiChatSearchToolDisabledKey)
        }
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
