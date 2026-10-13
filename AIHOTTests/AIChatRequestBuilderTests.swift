import XCTest

@testable import AIHOT

/// 请求形状、地址归一化、以及响应体里的纯函数。
///
/// 这些是本地唯一能验证「线上请求长什么样」的地方 —— 真正的编译与联网都在 CI/真机上，
/// 所以把能断言的东西尽量断言掉。工具往返那两块尤其重要：两家的形状完全不同
/// （Anthropic 是 `tool_use` / `tool_result` 块，OpenAI 兼容是 `tool_calls` / `role:"tool"`），
/// 写错了模型就会一直重复调同一个工具。
final class AIChatRequestBuilderTests: XCTestCase {

    private func config(
        _ chatProtocol: AIChatProtocol,
        baseURLRaw: String = "",
        modelRaw: String = "",
        apiKey: String = "sk-test"
    ) throws -> AIChatConfig {
        try XCTUnwrap(
            AIChatConfig.resolve(
                chatProtocol: chatProtocol, baseURLRaw: baseURLRaw, modelRaw: modelRaw, apiKey: apiKey
            )
        )
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func sampleRound(text: String = "我先查一下。", isError: Bool = false) -> AIChatToolRound {
        let call = AIChatToolCall(
            index: 0,
            id: "call_1",
            name: AIChatToolName.webSearch,
            argumentsJSON: "{\"query\":\"Karpathy\"}"
        )
        return AIChatToolRound(
            assistantText: text,
            calls: [call],
            results: [
                AIChatToolRound.AIChatToolResultPayload(
                    toolUseID: "call_1",
                    text: "## Search Results\n1. …",
                    isError: isError
                )
            ]
        )
    }

    // MARK: - Anthropic 请求体

    func testAnthropicBodyShape() throws {
        let data = try XCTUnwrap(
            AIChatRequestBuilder.anthropicBody(
                config: try config(.anthropicMessages), system: "SYS", newsContext: "CTX",
                turns: [AIChatTurn(role: .user, text: "为什么火？")]
            )
        )
        let body = try json(data)

        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["max_tokens"] as? Int, 64_000)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["system"] as? String, "SYS")

        let thinking = try XCTUnwrap(body["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "adaptive")
        XCTAssertEqual(thinking["display"] as? String, "summarized", "不给可见摘要，流式下会长时间不出字")

        let output = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertEqual(output["effort"] as? String, "low")

        // 现在用的是**客户端工具**（执行端是 AnySearch），不再是 Anthropic 服务端工具
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 2)
        XCTAssertEqual(tools[0]["name"] as? String, "web_search")
        XCTAssertEqual(tools[1]["name"] as? String, "read_url")
        for tool in tools {
            XCTAssertNil(tool["type"], "客户端工具没有 type 字段")
            let schema = try XCTUnwrap(tool["input_schema"] as? [String: Any])
            XCTAssertEqual(schema["type"] as? String, "object")
        }

        // 这些不该出现：tool_choice/budget_tokens 在 claude-opus-5-5 上会 400
        XCTAssertNil(body["tool_choice"])
        XCTAssertNil(body["temperature"])

        if AIChatRequestBuilder.enableRefusalFallbacks {
            XCTAssertEqual(body["fallbacks"] as? String, "default")
        } else {
            XCTAssertNil(body["fallbacks"])
        }
    }

    /// 钉住「跨轮只回文本」这个不变量。
    ///
    /// 每条历史消息只能有 role 与**字符串** content。哪天有人开始把 thinking / 工具块
    /// 也放进历史，这条会红 —— 提醒他重新落进 Opus 5.5「保留 thinking」历史校验的射程
    /// （那条校验只校验你回传的 thinking 块）。工具块只允许出现在本轮的往返里，
    /// 形状由下面两条测试单独盯着。
    func testAnthropicHistoryIsTextOnlyAndCarriesContextInFirstUserTurn() throws {
        let turns = [
            AIChatTurn(role: .user, text: "为什么火？"),
            AIChatTurn(role: .assistant, text: "因为被多人转引。"),
            AIChatTurn(role: .user, text: "还有后续吗？"),
        ]
        let data = try XCTUnwrap(
            AIChatRequestBuilder.anthropicBody(
                config: try config(.anthropicMessages), system: "SYS", newsContext: "CTX", turns: turns
            )
        )
        let messages = try XCTUnwrap(try json(data)["messages"] as? [[String: Any]])

        XCTAssertEqual(messages.count, 3)
        for message in messages {
            XCTAssertEqual(message.keys.sorted(), ["content", "role"])
            XCTAssertNotNil(message["content"] as? String)
        }

        let first = try XCTUnwrap(messages[0]["content"] as? String)
        XCTAssertTrue(first.hasPrefix("CTX"))
        XCTAssertTrue(first.hasSuffix("为什么火？"))
        // 资料**只能出现一次**：后面的 user 轮原样不动。
        XCTAssertEqual(messages[1]["content"] as? String, "因为被多人转引。")
        XCTAssertEqual(messages[2]["content"] as? String, "还有后续吗？")
    }

    func testAnthropicToolRoundIsEchoedWithMatchingIDs() throws {
        let data = try XCTUnwrap(
            AIChatRequestBuilder.anthropicBody(
                config: try config(.anthropicMessages), system: "SYS", newsContext: "CTX",
                turns: [AIChatTurn(role: .user, text: "有后续吗？")],
                toolRounds: [sampleRound()]
            )
        )
        let messages = try XCTUnwrap(try json(data)["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3, "历史 1 条 + 助手 1 条 + 工具结果 1 条")

        let assistant = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(messages[1]["role"] as? String, "assistant")
        XCTAssertEqual(assistant[0]["type"] as? String, "text")
        XCTAssertEqual(assistant[0]["text"] as? String, "我先查一下。")
        XCTAssertEqual(assistant[1]["type"] as? String, "tool_use")
        XCTAssertEqual(assistant[1]["id"] as? String, "call_1")
        XCTAssertEqual(assistant[1]["name"] as? String, "web_search")
        let input = try XCTUnwrap(assistant[1]["input"] as? [String: Any])
        XCTAssertEqual(input["query"] as? String, "Karpathy", "参数要还原成对象")

        let results = try XCTUnwrap(messages[2]["content"] as? [[String: Any]])
        XCTAssertEqual(messages[2]["role"] as? String, "user")
        XCTAssertEqual(results[0]["type"] as? String, "tool_result")
        XCTAssertEqual(results[0]["tool_use_id"] as? String, "call_1")
        XCTAssertNotNil(results[0]["content"] as? String)
        XCTAssertNil(results[0]["is_error"], "成功的结果不带 is_error")
    }

    func testAnthropicFailedToolResultIsMarkedAsError() throws {
        let data = try XCTUnwrap(
            AIChatRequestBuilder.anthropicBody(
                config: try config(.anthropicMessages), system: "SYS", newsContext: "CTX",
                turns: [AIChatTurn(role: .user, text: "x")],
                toolRounds: [sampleRound(isError: true)]
            )
        )
        let messages = try XCTUnwrap(try json(data)["messages"] as? [[String: Any]])
        let results = try XCTUnwrap(messages[2]["content"] as? [[String: Any]])
        XCTAssertEqual(results[0]["is_error"] as? Bool, true, "失败要用 is_error 回传，模型才知道换个路子")
    }

    // MARK: - OpenAI 兼容请求体

    func testOpenAICompatibleBodyHasFunctionTools() throws {
        let data = try XCTUnwrap(
            AIChatRequestBuilder.openAICompatibleBody(
                config: try config(.openAICompatible, baseURLRaw: "https://api.deepseek.com/v1", modelRaw: "deepseek-chat"),
                system: "SYS", newsContext: "CTX", turns: [AIChatTurn(role: .user, text: "hi")]
            )
        )
        let body = try json(data)

        XCTAssertEqual(body["model"] as? String, "deepseek-chat")
        XCTAssertEqual(body["max_tokens"] as? Int, 4_096, "兼容优先：很多兼容模型上限更低")
        XCTAssertEqual(body["stream"] as? Bool, true)

        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 2)
        XCTAssertEqual(tools[0]["type"] as? String, "function")
        let function = try XCTUnwrap(tools[0]["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "web_search")
        XCTAssertNotNil(function["parameters"] as? [String: Any])

        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["fallbacks"])
        XCTAssertNil(body["output_config"])

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertEqual(messages.first?["content"] as? String, "SYS")
        XCTAssertEqual(messages.count, 2)
    }

    /// OpenAI 兼容侧的多轮：这条协议的历史形状与 Anthropic 是**分开写的**，
    /// 只钉住 Anthropic 那边不算数。system 之后必须是「问 / 答 / 问」三条，
    /// 资料只并进第一条 user，其余原样。
    func testOpenAICompatibleHistoryCarriesAssistantTurnsAndContextInFirstUserTurn() throws {
        let turns = [
            AIChatTurn(role: .user, text: "为什么火？"),
            AIChatTurn(role: .assistant, text: "因为被多人转引。"),
            AIChatTurn(role: .user, text: "还有后续吗？"),
        ]
        let data = try XCTUnwrap(
            AIChatRequestBuilder.openAICompatibleBody(
                config: try config(.openAICompatible), system: "SYS", newsContext: "CTX", turns: turns
            )
        )
        let messages = try XCTUnwrap(try json(data)["messages"] as? [[String: Any]])

        XCTAssertEqual(messages.count, 4, "system + 三轮历史")
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[2]["role"] as? String, "assistant")
        XCTAssertEqual(messages[3]["role"] as? String, "user")

        let first = try XCTUnwrap(messages[1]["content"] as? String)
        XCTAssertTrue(first.hasPrefix("CTX"))
        XCTAssertTrue(first.hasSuffix("为什么火？"))
        // 资料只能出现一次，而且历史轮不许被夹带成工具块（跨轮只回文本）。
        XCTAssertEqual(messages[2]["content"] as? String, "因为被多人转引。")
        XCTAssertEqual(messages[3]["content"] as? String, "还有后续吗？")
        for message in messages.dropFirst() {
            XCTAssertEqual(message.keys.sorted(), ["content", "role"])
            XCTAssertNotNil(message["content"] as? String)
        }
    }

    func testOpenAIToolRoundUsesToolRoleAndRawArguments() throws {
        let data = try XCTUnwrap(
            AIChatRequestBuilder.openAICompatibleBody(
                config: try config(.openAICompatible, baseURLRaw: "https://api.deepseek.com/v1", modelRaw: "m"),
                system: "SYS", newsContext: "CTX",
                turns: [AIChatTurn(role: .user, text: "有后续吗？")],
                toolRounds: [sampleRound()]
            )
        )
        let messages = try XCTUnwrap(try json(data)["messages"] as? [[String: Any]])
        // system + 历史 1 + 助手 1 + 工具结果 1
        XCTAssertEqual(messages.count, 4)

        let assistant = messages[2]
        XCTAssertEqual(assistant["role"] as? String, "assistant")
        XCTAssertEqual(assistant["content"] as? String, "我先查一下。")
        let calls = try XCTUnwrap(assistant["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls[0]["id"] as? String, "call_1")
        XCTAssertEqual(calls[0]["type"] as? String, "function")
        let function = try XCTUnwrap(calls[0]["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "web_search")
        XCTAssertEqual(
            function["arguments"] as? String, "{\"query\":\"Karpathy\"}",
            "参数要原样回传字符串，不能回传解析后的对象"
        )

        let toolMessage = messages[3]
        XCTAssertEqual(toolMessage["role"] as? String, "tool")
        XCTAssertEqual(toolMessage["tool_call_id"] as? String, "call_1")
        XCTAssertNotNil(toolMessage["content"] as? String)
    }

    func testOpenAIAssistantContentIsNullWhenThereIsNoText() throws {
        let data = try XCTUnwrap(
            AIChatRequestBuilder.openAICompatibleBody(
                config: try config(.openAICompatible, baseURLRaw: "https://x.example.com/v1", modelRaw: "m"),
                system: "SYS", newsContext: "CTX",
                turns: [AIChatTurn(role: .user, text: "x")],
                toolRounds: [sampleRound(text: "")]
            )
        )
        let messages = try XCTUnwrap(try json(data)["messages"] as? [[String: Any]])
        XCTAssertTrue(messages[2]["content"] is NSNull, "有 tool_calls 且没文本时，官方形状是 null")
    }

    // MARK: - 请求头与地址

    func testHeaders() throws {
        let anthropicHeaders = AIChatRequestBuilder.headers(for: try config(.anthropicMessages, apiKey: "sk-ant-x"))
        XCTAssertEqual(anthropicHeaders["x-api-key"], "sk-ant-x")
        XCTAssertEqual(anthropicHeaders["anthropic-version"], "2023-06-01")
        XCTAssertEqual(anthropicHeaders["Accept-Encoding"], "identity", "不要压缩：那层缓冲会让 SSE 攒到最后才出来")
        if AIChatRequestBuilder.enableRefusalFallbacks {
            XCTAssertEqual(anthropicHeaders["anthropic-beta"], "server-side-fallback-2026-07-01")
        } else {
            XCTAssertNil(anthropicHeaders["anthropic-beta"])
        }

        let openAIHeaders = AIChatRequestBuilder.headers(
            for: try config(.openAICompatible, baseURLRaw: "https://x.example.com/v1", modelRaw: "m", apiKey: "sk-y")
        )
        XCTAssertEqual(openAIHeaders["Authorization"], "Bearer sk-y")
        XCTAssertNil(openAIHeaders["x-api-key"])
    }

    func testEndpoints() throws {
        let anthropic = try config(.anthropicMessages)
        XCTAssertEqual(
            AIChatRequestBuilder.chatEndpoint(for: anthropic)?.absoluteString,
            "https://api.anthropic.com/v1/messages"
        )
        XCTAssertEqual(
            AIChatRequestBuilder.modelsEndpoint(for: anthropic)?.absoluteString,
            "https://api.anthropic.com/v1/models"
        )

        let relay = try config(.openAICompatible, baseURLRaw: "https://relay.example.com/v1/", modelRaw: "m")
        XCTAssertEqual(
            AIChatRequestBuilder.chatEndpoint(for: relay)?.absoluteString,
            "https://relay.example.com/v1/chat/completions"
        )
        XCTAssertEqual(
            AIChatRequestBuilder.modelsEndpoint(for: relay)?.absoluteString,
            "https://relay.example.com/v1/models"
        )
    }

    // MARK: - 地址归一化

    func testBaseURLNormalization() {
        XCTAssertEqual(
            AIChatConfig.normalizedBaseURL(from: "https://api.anthropic.com/")?.absoluteString,
            "https://api.anthropic.com"
        )
        XCTAssertEqual(
            AIChatConfig.normalizedBaseURL(from: "https://api.deepseek.com/v1")?.absoluteString,
            "https://api.deepseek.com/v1"
        )
        XCTAssertEqual(
            AIChatConfig.normalizedBaseURL(from: "https://relay.example.com/anthropic/v1/")?.absoluteString,
            "https://relay.example.com/anthropic/v1"
        )
        XCTAssertNil(AIChatConfig.normalizedBaseURL(from: "api.anthropic.com"))
        XCTAssertNil(AIChatConfig.normalizedBaseURL(from: "ftp://example.com"))
        XCTAssertNil(AIChatConfig.normalizedBaseURL(from: "   "))
        XCTAssertNil(AIChatConfig.normalizedBaseURL(from: "https://"))
    }

    func testResolveDefaultsPerProtocol() throws {
        let anthropic = try config(.anthropicMessages, baseURLRaw: "  ", modelRaw: "")
        XCTAssertEqual(anthropic.baseURL.absoluteString, "https://api.anthropic.com")
        XCTAssertEqual(anthropic.model, "claude-opus-5-5")

        // OpenAI 兼容那侧地址与模型都没有默认值：不填就是没配好
        XCTAssertNil(
            AIChatConfig.resolve(chatProtocol: .openAICompatible, baseURLRaw: "", modelRaw: "", apiKey: "k")
        )
        XCTAssertNil(
            AIChatConfig.resolve(
                chatProtocol: .openAICompatible, baseURLRaw: "", modelRaw: "deepseek-chat", apiKey: "k"
            ),
            "空地址应解析不出 —— 也验证了它绝不自动补默认地址"
        )
        XCTAssertNotNil(
            AIChatConfig.resolve(
                chatProtocol: .openAICompatible,
                baseURLRaw: "https://api.deepseek.com/v1",
                modelRaw: "deepseek-chat",
                apiKey: "k"
            )
        )
    }

    func testPlainHTTPIsFlagged() throws {
        let plain = try config(.anthropicMessages, baseURLRaw: "http://192.168.1.9:3000")
        XCTAssertTrue(plain.isPlainHTTP, "明文 HTTP 会被 ATS 拦，界面要能识别出来")
        XCTAssertFalse(try config(.anthropicMessages).isPlainHTTP)
    }

    // MARK: - 响应体里的纯函数

    func testCompleteTextForBothProtocols() throws {
        let anthropic = Data(#"{"content":[{"type":"thinking","thinking":"x"},{"type":"text","text":"甲"},{"type":"text","text":"乙"}]}"#.utf8)
        XCTAssertEqual(AIChatAPI.completeText(from: anthropic, chatProtocol: .anthropicMessages), "甲乙")

        let openAI = Data(#"{"choices":[{"message":{"content":"丙"}}]}"#.utf8)
        XCTAssertEqual(AIChatAPI.completeText(from: openAI, chatProtocol: .openAICompatible), "丙")
    }

    func testProblemMessageHandlesBothErrorShapes() {
        XCTAssertEqual(
            AIChatAPI.problemMessage(from: Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"Extra inputs are not permitted"}}"#.utf8)),
            "Extra inputs are not permitted"
        )
        XCTAssertEqual(
            AIChatAPI.problemMessage(from: Data(#"{"error":{"message":"Invalid API key"}}"#.utf8)),
            "Invalid API key"
        )
        XCTAssertEqual(AIChatAPI.problemMessage(from: Data("Bad gateway".utf8)), "Bad gateway")
        XCTAssertNil(AIChatAPI.problemMessage(from: Data()))
    }

    func testDescribeModelsChecksTheConfiguredModel() {
        let data = Data(#"{"data":[{"id":"claude-opus-5-5"},{"id":"claude-haiku-5-5"}]}"#.utf8)
        XCTAssertTrue(AIChatAPI.describeModels(data: data, wanted: "claude-opus-5-5").contains("已包含"))
        XCTAssertTrue(AIChatAPI.describeModels(data: data, wanted: "claude-opus-9-9").contains("请核对模型名"))
        XCTAssertTrue(AIChatAPI.describeModels(data: Data("{}".utf8), wanted: "x").contains("连接正常"))
    }
}
