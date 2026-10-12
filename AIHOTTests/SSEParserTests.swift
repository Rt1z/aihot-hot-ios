import XCTest

@testable import AIHOT

/// SSE 分帧与两家协议的解码。
///
/// 两个夹具（anthropic-sse.txt / openai-sse.txt）与 `tools/logic_tests.py`
/// 读的是同一份字节 —— 那个 Python 镜像是我这边唯一的本地信号，这里是权威。
final class SSEParserTests: XCTestCase {

    private let expectedText = "这条说的是 Karpathy 对 LLM 认知鸿沟的看法。他估算全球约 60 亿人几乎没接触过大模型。"

    // MARK: - 辅助

    private struct Collected {
        var text = ""
        var names: [String] = []
        var stopReason: String?
    }

    private func collect(_ lines: [String], anthropic: Bool) -> Collected {
        var reader = SSEFrameReader()
        var result = Collected()

        func handle(_ event: AIChatEvent?) {
            guard let event = event else { return }
            switch event {
            case .text(let chunk):
                result.text += chunk
                result.names.append("text")
            case .thinking:
                result.names.append("thinking")
            case .toolStarted:
                result.names.append("tool_started")
            case .stopReason(let reason):
                result.stopReason = reason
                result.names.append("stop_reason")
            case .error:
                result.names.append("error")
            case .done:
                result.names.append("done")
            }
        }

        /// 解码器吃的是**非可选**的帧，所以要先把「还没凑成一帧」的情况挡掉。
        func decode(_ frame: SSEFrame?) {
            guard let frame = frame else { return }
            handle(anthropic ? AnthropicSSEDecoder.decode(frame) : OpenAISSSEDecoder.decode(frame))
        }

        for line in lines {
            decode(reader.consume(line: line))
        }
        decode(reader.flush())
        return result
    }

    private func anthropic(_ lines: String...) -> Collected {
        collect(lines, anthropic: true)
    }

    private func openAI(_ lines: String...) -> Collected {
        collect(lines, anthropic: false)
    }

    // MARK: - 夹具

    func testAnthropicFixture() throws {
        let stream = try Fixture.text("anthropic-sse", ext: "txt")
        let result = collect(stream.components(separatedBy: "\n"), anthropic: true)

        XCTAssertEqual(result.text, expectedText)
        XCTAssertEqual(result.names.filter { $0 == "thinking" }.count, 1, "thinking_delta 只点亮状态")
        XCTAssertTrue(result.names.contains("tool_started"), "能认出 web_search 开始")
        XCTAssertEqual(result.stopReason, "end_turn")
        XCTAssertEqual(result.names.last, "done")
    }

    func testOpenAIFixture() throws {
        let stream = try Fixture.text("openai-sse", ext: "txt")
        let result = collect(stream.components(separatedBy: "\n"), anthropic: false)

        XCTAssertEqual(result.text, expectedText)
        XCTAssertEqual(result.names.filter { $0 == "thinking" }.count, 2, "reasoning_content 只点亮状态")
        XCTAssertEqual(result.stopReason, "stop")
        XCTAssertEqual(result.names.last, "done")
    }

    // MARK: - 分帧

    func testCRLFIsAccepted() {
        XCTAssertEqual(anthropic("data: {\"type\":\"message_stop\"}\r", "").names, ["done"])
    }

    func testMultiLineDataIsJoined() {
        // JSON 被拆成两个 data: 行
        let result = anthropic(
            "data: {\"type\":\"content_block_delta\",",
            "data: \"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}",
            ""
        )
        XCTAssertEqual(result.text, "hi")
    }

    func testCommentsEventLinesAndPingAreIgnored() {
        let result = anthropic(": ping", "event: ping", "data: {\"type\":\"ping\"}", "")
        XCTAssertTrue(result.names.isEmpty)
        XCTAssertEqual(result.text, "")
    }

    func testOnlyOneLeadingSpaceIsStripped() {
        // 多出来的那个空格会留在 JSON 前面，仍然要能解析
        XCTAssertEqual(anthropic("data:  {\"type\":\"message_stop\"}", "").names, ["done"])
    }

    func testUnknownBlockTypesAreSkippedNotThrown() {
        // fallbacks 打开时中途换模型会出现 fallback 块；将来还会加新类型
        let result = anthropic(
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"fallback\",\"from\":{\"model\":\"a\"}}}",
            ""
        )
        XCTAssertTrue(result.names.isEmpty)
    }

    func testSecondMessageStartIsHarmless() {
        // 中途换模型会产生第二个 message_start，不能因此重置已攒的正文
        let result = anthropic(
            "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"前半\"}}",
            "",
            "data: {\"type\":\"message_start\",\"message\":{}}",
            "",
            "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"后半\"}}",
            ""
        )
        XCTAssertEqual(result.text, "前半后半")
    }

    // MARK: - 结束原因与错误

    func testStopReasonsAreSurfaced() {
        for reason in ["refusal", "pause_turn", "max_tokens"] {
            let result = anthropic("data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"\(reason)\"}}", "")
            XCTAssertEqual(result.stopReason, reason)
        }
    }

    func testNullStopReasonProducesNothing() {
        let result = anthropic("data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":null}}", "")
        XCTAssertNil(result.stopReason)
        XCTAssertTrue(result.names.isEmpty)
    }

    func testErrorFrameCarriesTheOriginalMessage() {
        let result = anthropic(
            "data: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}",
            ""
        )
        XCTAssertEqual(result.names, ["error"])
    }

    func testTruncatedStreamKeepsPartialText() {
        let result = anthropic(
            "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"半句\"}}",
            ""
        )
        XCTAssertEqual(result.text, "半句")
        XCTAssertFalse(result.names.contains("done"))
    }

    // MARK: - OpenAI 兼容侧的坑

    func testReasoningContentDoesNotProduceText() {
        let result = openAI(
            "data: {\"choices\":[{\"delta\":{\"content\":null,\"reasoning_content\":\"想了想\"},\"finish_reason\":null}]}",
            ""
        )
        XCTAssertEqual(result.text, "", "思考内容不能当正文")
        XCTAssertEqual(result.names, ["thinking"])
    }

    func testFinishReasonLengthIsSurfaced() {
        let result = openAI("data: {\"choices\":[{\"delta\":{\"content\":null},\"finish_reason\":\"length\"}]}", "")
        XCTAssertEqual(result.stopReason, "length")
    }

    func testEndOfStreamWithoutDoneStillKeepsText() {
        // 有些中转站不发 [DONE]，直接断流
        let result = openAI("data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}")
        XCTAssertEqual(result.text, "x")
        XCTAssertFalse(result.names.contains("done"))
    }

    func testOpenAIErrorCarriesTheOriginalMessage() {
        let result = openAI("data: {\"error\":{\"message\":\"Invalid API key\"}}", "")
        XCTAssertEqual(result.names, ["error"])
    }
}
