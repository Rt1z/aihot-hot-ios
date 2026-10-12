import Foundation

/// 一轮对话（只存文本，见下面的「只回文本」说明）。
struct AIChatTurn: Equatable {

    enum Role: String {
        case user
        case assistant
    }

    let role: Role
    let text: String
}

/// 两套协议的请求体与请求头。全是纯函数，便于单测。
///
/// 所有「有风险、可能需要一句话改掉」的值都收在这个文件里，并且都带注释。
enum AIChatRequestBuilder {

    // MARK: - 可能要改的常量

    /// 关掉它会去掉 `fallbacks` 与对应的 beta 头。
    ///
    /// 官方文档把这组（`fallbacks: "default"` + `anthropic-beta:
    /// server-side-fallback-2026-07-01`）写成 claude-opus-5-5 的默认推荐，被审核
    /// 拒绝时会自动换个模型重跑一次。但「它和流式 + 服务端工具同时使用」没有文档
    /// 背书。**如果每次请求都 400 且报错里提到 fallback / anthropic-beta，
    /// 把这里改成 false 即可**（README 也写了这条）。
    static let enableRefusalFallbacks = true

    private static let fallbackBetaHeader = "server-side-fallback-2026-07-01"
    private static let anthropicVersion = "2023-06-01"

    /// max_tokens 是上限不是目标。官方对流式请求建议给到 64000。
    static let anthropicMaxTokens = 64000

    /// OpenAI 兼容那侧取小值：很多兼容模型的输出上限更低，给大了会被直接拒掉。
    static let openAICompatibleMaxTokens = 4096

    /// 手机上的问答对延迟敏感，官方也说 chat 类用 low 就够。
    /// 这是这一版唯一的「快 / 深」旋钮，想让它想得更久就改成 medium/high。
    static let effort = "low"

    // MARK: - 地址

    static func chatEndpoint(for config: AIChatConfig) -> URL? {
        endpoint(base: config.baseURL, path: chatPath(config.chatProtocol))
    }

    static func modelsEndpoint(for config: AIChatConfig) -> URL? {
        endpoint(base: config.baseURL, path: modelsPath(config.chatProtocol))
    }

    private static func endpoint(base: URL, path: String) -> URL? {
        // 用字符串拼接而不是 appendingPathComponent：后者会把 "v1/messages" 当成
        // 单个组件去转义斜杠，行为不如直接拼可预期（baseURL 已经去掉了末尾斜杠）。
        URL(string: base.absoluteString + path)
    }

    private static func chatPath(_ chatProtocol: AIChatProtocol) -> String {
        switch chatProtocol {
        case .anthropicMessages: return "/v1/messages"
        case .openAICompatible: return "/chat/completions"
        }
    }

    private static func modelsPath(_ chatProtocol: AIChatProtocol) -> String {
        switch chatProtocol {
        case .anthropicMessages: return "/v1/models"
        case .openAICompatible: return "/models"
        }
    }

    // MARK: - 请求头

    static func headers(for config: AIChatConfig) -> [String: String] {
        switch config.chatProtocol {
        case .anthropicMessages:
            var headers = [
                "Content-Type": "application/json",
                "x-api-key": config.apiKey,
                "anthropic-version": anthropicVersion,
                "Accept": "text/event-stream",
                // URLSession 默认会要 gzip 再透明解压，那一层缓冲正是「SSE 一直
                // 不出字、结束时一次性冒出来」的经典成因。干脆不要压缩。
                "Accept-Encoding": "identity",
            ]
            if enableRefusalFallbacks {
                headers["anthropic-beta"] = fallbackBetaHeader
            }
            return headers

        case .openAICompatible:
            return [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(config.apiKey)",
                "Accept": "text/event-stream",
                "Accept-Encoding": "identity",
            ]
        }
    }

    // MARK: - 把资料拼进第一条 user 消息

    /// 把资料并进**第一条 user 消息**，其余原样。
    ///
    /// 为什么必须放进消息、而不是放进 system：Anthropic 的 `web_fetch` 只能抓
    /// **对话里已经出现过**的 URL。只写在 system 里属于模糊地带，很可能读不到原文，
    /// 那样「按需读原报道」就静默失效了（模型会改去搜网页、或者干脆说读不到）。
    /// 放进第一条 user 消息则是明确的。
    ///
    /// 顺带的好处：system 与 tools 逐字不变、messages 只追加，缓存前缀不会被打断。
    static func contextualTurns(_ turns: [AIChatTurn], newsContext: String) -> [AIChatTurn] {
        guard let index = turns.firstIndex(where: { $0.role == .user }) else { return turns }
        var result = turns
        result[index] = AIChatTurn(
            role: .user,
            text: newsContext + "\n\n---\n\n" + turns[index].text
        )
        return result
    }

    // MARK: - 请求体

    static func anthropicBody(
        config: AIChatConfig,
        system: String,
        newsContext: String,
        turns: [AIChatTurn]
    ) -> Data? {
        let messages = contextualTurns(turns, newsContext: newsContext).map {
            ["role": $0.role.rawValue, "content": $0.text]
        }

        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": anthropicMaxTokens,
            "stream": true,
            "system": system,
            "messages": messages,
            // 自适应思考；display 默认是 omitted，那在流式下表现为「长时间不出字」，
            // 所以显式要一份可读摘要（这里只拿它点亮「思考中」状态，不显示内容）。
            "thinking": ["type": "adaptive", "display": "summarized"],
            "output_config": ["effort": effort],
        ]

        if config.supportsWebTools {
            // 这两个是 Anthropic 托管的服务端工具：联网搜索与读取原文都由它完成，
            // 不需要额外的搜索 Key，App 里也不用写工具循环。
            // 别再单独声明 code_execution —— 会多出一个执行环境把模型搞乱。
            body["tools"] = [
                ["type": "web_search_20260209", "name": "web_search"],
                ["type": "web_fetch_20260209", "name": "web_fetch"],
            ]
        }

        if enableRefusalFallbacks {
            body["fallbacks"] = "default"
        }

        return encode(body)
    }

    static func openAICompatibleBody(
        config: AIChatConfig,
        system: String,
        newsContext: String,
        turns: [AIChatTurn]
    ) -> Data? {
        var messages: [[String: String]] = [["role": "system", "content": system]]
        messages += contextualTurns(turns, newsContext: newsContext).map {
            ["role": $0.role.rawValue, "content": $0.text]
        }

        // 只发这几个字段：中转站对可选字段的容忍度参差不齐，body 越简单越容易活下来。
        let body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "stream": true,
            "max_tokens": openAICompatibleMaxTokens,
        ]

        return encode(body)
    }

    private static func encode(_ body: [String: Any]) -> Data? {
        // sortedKeys：让同样的输入产出逐字节相同的 body。
        // 这样 system/tools 前缀稳定（缓存命中率不会被我们自己搞坏），
        // 单测里也能直接断言这几个键。
        try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}
