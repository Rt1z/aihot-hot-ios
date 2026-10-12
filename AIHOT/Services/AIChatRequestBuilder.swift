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

/// 当前这一轮里已经发生过的一次「模型要工具 → 我们给结果」往返。
///
/// 只存在于**当前这一轮**内：跨轮的历史是纯文本（见 `AIChatRequestBuilder` 顶部说明）。
struct AIChatToolRound {
    /// 模型在发起工具调用前写的话（可能为空）。
    let assistantText: String
    let calls: [AIChatToolCall]
    let results: [AIChatToolResultPayload]

    struct AIChatToolResultPayload {
        let toolUseID: String?
        let text: String
        let isError: Bool
    }
}

/// 两套协议的请求体与请求头。全是纯函数，便于单测。
///
/// 所有「有风险、可能需要一句话改掉」的值都收在这个文件里，并且都带注释。
///
/// 关于多轮历史：**跨轮只回传文本**，只在本轮跑工具时才带上工具块。
/// - 纯文本历史是完全合法的对话形状；
/// - Anthropic「保留 thinking」的历史校验只校验你**回传的** thinking 块 ——
///   一个都不回传，就完全不在它的射程内；
/// - 本轮的工具块是我们自己按流式分片拼出来的（`AIChatToolCallAccumulator`），
///   不是从别处搬来的，所以不存在签名对不上的问题。
enum AIChatRequestBuilder {

    // MARK: - 可能要改的常量

    /// 关掉它会去掉 `fallbacks` 与对应的 beta 头。
    ///
    /// 官方文档把 `fallbacks: "default"` + `anthropic-beta:
    /// server-side-fallback-2026-07-01` 写成 claude-opus-5-5 的默认推荐：被审核
    /// 拒绝时会自动换个模型重跑一次。**如果每次请求都 400 且报错里提到
    /// fallback / anthropic-beta，把这里改成 false 即可**（README 也写了这条）。
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

    // MARK: - 工具声明（两条协议各自的形状）

    private static let searchSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "搜索关键词，简洁一点效果更好"],
        ],
        "required": ["query"],
    ]

    private static let readURLSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "url": ["type": "string", "description": "要读取的完整网址（http/https）"],
        ],
        "required": ["url"],
    ]

    private static let searchDescription =
        "联网搜索。需要最新信息、后续进展、或资料里没有的事实时用它；只给关键词，不要整句话。"

    private static let readURLDescription =
        "读取一个网页并转成 Markdown。可以读资料里给出的原文链接，或搜索结果里的某一条。"

    static var anthropicTools: [[String: Any]] {
        [
            [
                "name": AIChatToolName.webSearch,
                "description": searchDescription,
                "input_schema": searchSchema,
            ],
            [
                "name": AIChatToolName.readURL,
                "description": readURLDescription,
                "input_schema": readURLSchema,
            ],
        ]
    }

    static var openAICompatibleTools: [[String: Any]] {
        [
            [
                "type": "function",
                "function": [
                    "name": AIChatToolName.webSearch,
                    "description": searchDescription,
                    "parameters": searchSchema,
                ],
            ],
            [
                "type": "function",
                "function": [
                    "name": AIChatToolName.readURL,
                    "description": readURLDescription,
                    "parameters": readURLSchema,
                ],
            ],
        ]
    }

    // MARK: - 把资料拼进第一条 user 消息

    /// 把资料并进**第一条 user 消息**，其余原样。
    ///
    /// 为什么必须放进消息、而不是放进 system：这样 system 与 tools 逐字不变、
    /// messages 只追加，缓存前缀不会被打断；同时原文链接也就明确地「在对话里」，
    /// 模型可以直接把它的 URL 交给 read_url。
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
        turns: [AIChatTurn],
        toolRounds: [AIChatToolRound] = []
    ) -> Data? {
        var messages: [[String: Any]] = contextualTurns(turns, newsContext: newsContext).map {
            ["role": $0.role.rawValue, "content": $0.text]
        }
        for round in toolRounds {
            messages.append(anthropicAssistantMessage(round))
            messages.append(anthropicToolResultMessage(round))
        }

        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": anthropicMaxTokens,
            "stream": true,
            "system": system,
            "messages": messages,
            "tools": anthropicTools,
            // 自适应思考；display 默认是 omitted，那在流式下表现为「长时间不出字」，
            // 所以显式要一份可读摘要（这里只拿它点亮「思考中」状态，不显示内容）。
            "thinking": ["type": "adaptive", "display": "summarized"],
            "output_config": ["effort": effort],
        ]

        if enableRefusalFallbacks {
            body["fallbacks"] = "default"
        }

        return encode(body)
    }

    static func openAICompatibleBody(
        config: AIChatConfig,
        system: String,
        newsContext: String,
        turns: [AIChatTurn],
        toolRounds: [AIChatToolRound] = []
    ) -> Data? {
        var messages: [[String: Any]] = [["role": "system", "content": system]]
        messages += contextualTurns(turns, newsContext: newsContext).map {
            ["role": $0.role.rawValue, "content": $0.text]
        }
        for round in toolRounds {
            messages.append(openAIAssistantMessage(round))
            messages += openAIToolMessages(round)
        }

        // 只发必要的字段：中转站对可选字段的容忍度参差不齐，body 越简单越容易活下来。
        let body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "stream": true,
            "max_tokens": openAICompatibleMaxTokens,
            "tools": openAICompatibleTools,
        ]

        return encode(body)
    }

    // MARK: - 工具往返（两家的形状完全不同）

    /// Anthropic：助手那条要原样带上 `tool_use` 块，下一条 user 用 `tool_result` 回。
    static func anthropicAssistantMessage(_ round: AIChatToolRound) -> [String: Any] {
        var content: [[String: Any]] = []
        if !round.assistantText.isEmpty {
            content.append(["type": "text", "text": round.assistantText])
        }
        for call in round.calls {
            var block: [String: Any] = [
                "type": "tool_use",
                "name": call.name ?? "",
                "input": call.arguments,
            ]
            if let id = call.id { block["id"] = id }
            content.append(block)
        }
        return ["role": "assistant", "content": content]
    }

    static func anthropicToolResultMessage(_ round: AIChatToolRound) -> [String: Any] {
        let content: [[String: Any]] = round.results.map { result in
            var block: [String: Any] = ["type": "tool_result", "content": result.text]
            if let id = result.toolUseID { block["tool_use_id"] = id }
            if result.isError { block["is_error"] = true }
            return block
        }
        return ["role": "user", "content": content]
    }

    /// OpenAI 兼容：助手那条带 `tool_calls`，结果用 `role: "tool"` 一条条回。
    static func openAIAssistantMessage(_ round: AIChatToolRound) -> [String: Any] {
        let calls: [[String: Any]] = round.calls.map { call in
            [
                "id": call.id ?? "",
                "type": "function",
                "function": [
                    "name": call.name ?? "",
                    // 参数要回传**原始字符串**，不能回传解析后的对象
                    "arguments": call.argumentsJSON.isEmpty ? "{}" : call.argumentsJSON,
                ],
            ]
        }
        // 有 tool_calls 时 content 按官方形状是 null（空字符串有些中转站会不高兴）
        let content: Any = round.assistantText.isEmpty ? NSNull() : round.assistantText
        return ["role": "assistant", "content": content, "tool_calls": calls]
    }

    static func openAIToolMessages(_ round: AIChatToolRound) -> [[String: Any]] {
        round.results.compactMap { result in
            guard let id = result.toolUseID, !id.isEmpty else { return nil }
            return ["role": "tool", "tool_call_id": id, "content": result.text]
        }
    }

    private static func encode(_ body: [String: Any]) -> Data? {
        // sortedKeys：让同样的输入产出逐字节相同的 body。
        // 这样 system/tools 前缀稳定（缓存命中率不会被我们自己搞坏），
        // 单测里也能直接断言这几个键。
        try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}
