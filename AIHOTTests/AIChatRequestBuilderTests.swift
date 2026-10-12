import XCTest

@testable import AIHOT

/// 请求形状、地址归一化、以及响应体里的纯函数。
///
/// 这些是本地唯一能验证「线上请求长什么样」的地方 —— 真正的编译与联网都在 CI/真机上，
/// 所以把能断言的东西尽量断言掉。
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

    // MARK: - Anthropic 请求体

    func testAnthropicBodyShape() throws {
        let config = try config(.anthropicMessages)
        let data = try XCTUnwrap(
            AIChatRequestBuilder.anthropicBody(
                config: config, system: "SYS", newsContext: "CTX",
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

        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 2)
        XCTAssertEqual(tools[0]["type"] as? String, "web_search_20260209")
        XCTAssertEqual(tools[0]["name"] as? String, "web_search")
        XCTAssertEqual(tools[1]["type"] as? String, "web_fetch_20260209")
        XCTAssertEqual(tools[1]["name"] as? String, "web_fetch")

        // 这些不该出现：tool_choice/budget_tokens 在 claude-opus-5-5 上会 400
        XCTAssertNil(body["tool_choice"])
        XCTAssertNil(body["temperature"])

        if AIChatRequestBuilder.enableRefusalFallbacks {
            XCTAssertEqual(body["fallbacks"] as? String, "default")
        } else {
            XCTAssertNil(body["fallbacks"])
        }
    }

    /// 钉住「只回传文本」这个不变量。
    ///
    /// 每条消息只能有 role 与**字符串** content。哪天有人开始把 thinking / 工具块
    /// 也回传，这条会红 —— 提醒他重新落进 Opus 5.5「保留 thinking」历史校验的射程
    /// （那条校验只校验你回传的 thinking 块）。
    func testAnthropicMessagesAreTextOnlyAndCarryContextInFirstUserTurn() throws {
        let config = try config(.anthropicMessages)
        let turns = [
            AIChatTurn(role: .user, text: "为什么火？"),
            AIChatTurn(role: .assistant, text: "因为被多人转引。"),
            AIChatTurn(role: .user, text: "还有后续吗？"),
        ]
        let data = try XCTUnwrap(
            AIChatRequestBuilder.anthropicBody(
                config: config, system: "SYS", newsContext: "CTX", turns: turns
            )
        )
        let body = try json(data)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])

        XCTAssertEqual(messages.count, 3)
        for message in messages {
            XCTAssertEqual(message.keys.sorted(), ["content", "role"])
            XCTAssertNotNil(message["content"] as? String)
        }
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["role"] as? String, "assistant")
        XCTAssertEqual(messages[2]["role"] as? String, "user")

        // 资料必须在第一条 user 消息里：web_fetch 只能抓对话里出现过的 URL
        let first = try XCTUnwrap(messages[0]["content"] as? String)
        XCTAssertTrue(first.hasPrefix("CTX"))
        XCTAssertTrue(first.hasSuffix("为什么火？"))
        XCTAssertEqual(messages[1]["content"] as? String, "因为被多人转引。")
    }

    // MARK: - OpenAI 兼容请求体

    func testOpenAICompatibleBodyHasNoServerTools() throws {
        let config = try config(
            .openAICompatible, baseURLRaw: "https://api.deepseek.com/v1", modelRaw: "deepseek-chat"
        )
        let data = try XCTUnwrap(
            AIChatRequestBuilder.openAICompatibleBody(
                config: config, system: "SYS", newsContext: "CTX",
                turns: [AIChatTurn(role: .user, text: "hi")]
            )
        )
        let body = try json(data)

        XCTAssertEqual(body["model"] as? String, "deepseek-chat")
        XCTAssertEqual(body["max_tokens"] as? Int, 4_096, "兼容优先：很多兼容模型上限更低")
        XCTAssertEqual(body["stream"] as? Bool, true)

        XCTAssertNil(body["tools"], "OpenAI 兼容那侧没有服务端搜索工具")
        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["fallbacks"])
        XCTAssertNil(body["output_config"])

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertEqual(messages.first?["content"] as? String, "SYS")
        XCTAssertEqual(messages.count, 2)
    }

    // MARK: - 请求头与地址

    func testHeaders() throws {
        let anthropicHeaders = AIChatRequestBuilder.headers(
            for: try config(.anthropicMessages, apiKey: "sk-ant-x")
        )
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
        XCTAssertNil(openAIHeaders["anthropic-version"])
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
        // 不自动补 /v1：DeepSeek 带不带都行，多数中转站必须带
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
        XCTAssertTrue(anthropic.supportsWebTools)

        // OpenAI 兼容那侧地址与模型都没有默认值：不填就是没配好
        XCTAssertNil(
            AIChatConfig.resolve(chatProtocol: .openAICompatible, baseURLRaw: "", modelRaw: "", apiKey: "k"),
            "空模型应解析不出"
        )
        XCTAssertNil(
            AIChatConfig.resolve(
                chatProtocol: .openAICompatible, baseURLRaw: "", modelRaw: "deepseek-chat", apiKey: "k"
            ),
            "空地址应解析不出 —— 这条也验证了它绝不自动补默认地址"
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
        let secure = try config(.anthropicMessages)
        XCTAssertFalse(secure.isPlainHTTP)
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
        // 有些中转站直接回纯文本
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
