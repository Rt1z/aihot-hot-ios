import Foundation

/// App 支持的两条对话接口线。
enum AIChatProtocol: String, CaseIterable, Identifiable {
    case anthropicMessages
    case openAICompatible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anthropicMessages: return "Anthropic"
        case .openAICompatible: return "OpenAI 兼容"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .anthropicMessages: return "https://api.anthropic.com"
        case .openAICompatible: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropicMessages: return "claude-opus-5-5"
        case .openAICompatible: return ""
        }
    }

    var modelPlaceholder: String {
        switch self {
        case .anthropicMessages: return "claude-opus-5-5"
        case .openAICompatible: return "deepseek-chat"
        }
    }

    /// 「联网搜索」和「读原报道」是靠 Anthropic 的服务端工具做的，
    /// OpenAI 兼容那侧没有对应能力（要自己再接一个搜索服务 + 再一个 Key）。
    /// 设置界面要照实说，别让人以为切过去也能搜。
    var supportsWebTools: Bool {
        self == .anthropicMessages
    }
}

/// 一次对话要用到的全部配置（默认值已经解析好）。
struct AIChatConfig: Equatable {

    let chatProtocol: AIChatProtocol
    let baseURL: URL
    let model: String
    let apiKey: String

    var supportsWebTools: Bool { chatProtocol.supportsWebTools }

    /// 明文 HTTP 会被 iOS 的 ATS 拦掉（见 AIChatAPI 的错误翻译）。
    var isPlainHTTP: Bool {
        baseURL.scheme?.lowercased() == "http"
    }

    /// 把「用户填的原始字符串」解析成可用配置；缺项按所选协议的默认值补。
    ///
    /// 纯函数，便于单测 —— 这是设置页和请求构造共同的地基。
    static func resolve(
        chatProtocol: AIChatProtocol,
        baseURLRaw: String,
        modelRaw: String,
        apiKey: String
    ) -> AIChatConfig? {
        let urlText = baseURLRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveURL = urlText.isEmpty ? chatProtocol.defaultBaseURL : urlText
        guard let url = normalizedBaseURL(from: effectiveURL) else { return nil }

        let modelText = modelRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelText.isEmpty ? chatProtocol.defaultModel : modelText
        // OpenAI 兼容那侧没有默认模型，没填就是没配好
        guard !model.isEmpty else { return nil }

        return AIChatConfig(
            chatProtocol: chatProtocol,
            baseURL: url,
            model: model,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// 地址只做一件事：去掉末尾多余的 `/`。
    ///
    /// **刻意不自动补 `/v1`**：DeepSeek 带不带 `/v1` 都能用，而多数中转站必须带，
    /// 自动补一定会弄坏其中一个 —— 这两类我都没法在本地验证，所以宁可让用户自己填准，
    /// 界面上用占位符提示（「通常以 /v1 结尾」）。
    static func normalizedBaseURL(from raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty,
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty
        else { return nil }
        return url
    }
}
