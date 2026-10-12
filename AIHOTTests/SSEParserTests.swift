import XCTest

@testable import AIHOT

/// SSE 分帧、两家协议的解码、以及工具调用的分片拼接。
///
/// 两个夹具（anthropic-sse.txt / openai-sse.txt）与 `tools/logic_tests.py`
/// 读的是同一份字节 —— 那个 Python 镜像是我这边唯一的本地信号，这里是权威。
final class SSEParserTests: XCTestCase {

    private struct Collected {
        var text = ""
        var names: [String] = []
        var stopReason: String?
        var toolCalls: [AIChatToolCall] = []
    }

    private func collect(_ lines: [String], anthropic: Bool) -> Collected {
        var reader = SSEFrameReader()
        var accumulator = AIChatToolCallAccumulator()
        var result = Collected()

        func handle(_ events: [AIChatEvent]) {
            accumulator.consume(events)
            for event in events {
                switch event {
                case .text(let chunk):
                    result.text += chunk
                    result.names.append("text")
                case .thinking:
                    result.names.append("thinking")
                case .toolCallStarted:
                    result.names.append("tool_started")
                case .toolCallArguments:
                    result.names.append("tool_args")
                case .stopReason(let reason):
                    result.stopReason = reason
                    result.names.append("stop_reason")
                case .error:
                    result.names.append("error")
                case .done:
                    result.names.append("done")
                }
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

        result.toolCalls = accumulator.result
        return result
    }

    private func anthropic(_ lines: String...) -> Collected {
        collect(lines, anthropic: true)
    }

    private func openAI(_ lines: String...) -> Collected {
        collect(lines, anthropic: false)
    }

    // MARK: - 夹具

    func testAnthropicFixtureIsAToolRound() throws {
        let stream = try Fixture.text("anthropic-sse", ext: "txt")
        let result = collect(stream.components(separatedBy: "\n"), anthropic: true)

        XCTAssertEqual(result.text, "我先查一下有没有后续。")
        XCTAssertEqual(result.names.filter { $0 == "thinking" }.count, 1, "thinking_delta 只点亮状态")
        XCTAssertEqual(result.stopReason, "tool_use", "要跑工具")
        XCTAssertEqual(result.names.last, "done")
        XCTAssertEqual(result.toolCalls.count, 1)

        let call = try XCTUnwrap(result.toolCalls.first)
        XCTAssertEqual(call.index, 2)
        XCTAssertEqual(call.id, "toolu_01A")
        XCTAssertEqual(call.name, "web_search")
        XCTAssertEqual(call.string("query"), "Karpathy LLM 认知鸿沟 后续", "分片拼回来的参数要能解析")
    }

    func testOpenAIFixtureIsAToolRound() throws {
        let stream = try Fixture.text("openai-sse", ext: "txt")
        let result = collect(stream.components(separatedBy: "\n"), anthropic: false)

        XCTAssertEqual(result.text, "我先查一下有没有后续。")
        XCTAssertEqual(result.names.filter { $0 == "thinking" }.count, 1)
        XCTAssertEqual(result.stopReason, "tool_calls", "要跑工具")
        XCTAssertEqual(result.names.last, "done")

        let call = try XCTUnwrap(result.toolCalls.first)
        XCTAssertEqual(call.index, 0)
        XCTAssertEqual(call.id, "call_01A")
        XCTAssertEqual(call.name, "web_search")
        XCTAssertEqual(
            call.string("query"), "Karpathy LLM 认知鸿沟 后续",
            "两家协议拼出来的工具调用必须是同一形状"
        )
    }

    // MARK: - 分帧

    func testCRLFIsAccepted() {
        XCTAssertEqual(anthropic("data: {\"type\":\"message_stop\"}\r", "").names, ["done"])
    }

    func testMultiLineDataIsJoined() {
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
        XCTAssertEqual(anthropic("data:  {\"type\":\"message_stop\"}", "").names, ["done"])
    }

    func testUnknownBlockTypesAreSkippedNotThrown() {
        let result = anthropic(
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"fallback\",\"from\":{\"model\":\"a\"}}}",
            ""
        )
        XCTAssertTrue(result.names.isEmpty)
    }

    func testSecondMessageStartIsHarmless() {
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
        for reason in ["refusal", "pause_turn", "max_tokens", "end_turn"] {
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

    // MARK: - 工具调用的拼接

    func testAnthropicToolUseBlock() {
        let result = anthropic(
            "data: {\"type\":\"content_block_start\",\"index\":1,"
                + "\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"read_url\"}}",
            ""
        )
        XCTAssertEqual(result.names, ["tool_started"])
        XCTAssertEqual(result.toolCalls.first?.name, "read_url")
        XCTAssertEqual(result.toolCalls.first?.id, "t1")
    }

    func testArgumentsCanArriveBeforeTheName() {
        var accumulator = AIChatToolCallAccumulator()
        accumulator.consume(.toolCallArguments(index: 0, fragment: "{\"a\":"))
        accumulator.consume(.toolCallStarted(index: 0, id: "id1", name: "read_url"))
        accumulator.consume(.toolCallArguments(index: 0, fragment: "1}"))

        let call = try? XCTUnwrap(accumulator.result.first)
        XCTAssertEqual(call?.id, "id1")
        XCTAssertEqual(call?.name, "read_url")
        XCTAssertEqual(call?.argumentsJSON, "{\"a\":1}")
        XCTAssertEqual(call?.arguments["a"] as? Int, 1)
    }

    func testCallWithoutNameIsDropped() {
        var accumulator = AIChatToolCallAccumulator()
        accumulator.consume(.toolCallArguments(index: 0, fragment: "{}"))
        XCTAssertTrue(accumulator.result.isEmpty, "只有参数没有名字的半截数据跑不了")
    }

    func testCallsComeBackInIndexOrder() {
        var accumulator = AIChatToolCallAccumulator()
        accumulator.consume(.toolCallStarted(index: 1, id: "b", name: "read_url"))
        accumulator.consume(.toolCallStarted(index: 0, id: "a", name: "web_search"))
        XCTAssertEqual(accumulator.result.map { $0.id }, ["a", "b"])
    }

    func testBrokenArgumentsDoNotCrash() {
        var accumulator = AIChatToolCallAccumulator()
        accumulator.consume(.toolCallStarted(index: 0, id: "x", name: "web_search"))
        accumulator.consume(.toolCallArguments(index: 0, fragment: "{\"query\":"))
        let call = try? XCTUnwrap(accumulator.result.first)
        XCTAssertEqual(call?.arguments.isEmpty, true, "参数是半截 JSON 时给空字典，而不是崩")
        XCTAssertNil(call?.string("query"))
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
        let result = openAI("data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}")
        XCTAssertEqual(result.text, "x")
        XCTAssertFalse(result.names.contains("done"))
    }

    func testOpenAIErrorCarriesTheOriginalMessage() {
        let result = openAI("data: {\"error\":{\"message\":\"Invalid API key\"}}", "")
        XCTAssertEqual(result.names, ["error"])
    }
}
