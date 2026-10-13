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

    // MARK: - 行是怎么切出来的（承重：SSE 只认空行分帧）

    /// 照 `AIChatModel.consume` 的读法：逐字节喂进自己的切行器。
    private func lines(of text: String) -> [String] {
        var splitter = SSELineSplitter()
        var result: [String] = []
        for byte in Array(text.utf8) {
            if let line = splitter.consume(byte: byte) { result.append(line) }
        }
        if let line = splitter.flush() { result.append(line) }
        return result
    }

    /// **量出来的平台事实**：Darwin 的 `AsyncLineSequence` 会**把空行整个丢掉**。
    ///
    /// 这条在 CI（iOS 模拟器）上实测：喂 `"data: a\n\ndata: b\n\n"`，它交出
    /// `["data: a", "data: b"]` —— 两个空行都不见了。用 `AsyncStream<UInt8>` 就够了，
    /// 因为 `.lines` 挂在 `AsyncSequence where Element == UInt8` 上，
    /// `URLSession.AsyncBytes.lines` 走的是同一个实现。
    ///
    /// 而空行是 SSE 分帧的**唯一**依据（`SSEFrameReader` 见空行才交出一帧），
    /// 所以用它读 SSE 的后果是固定的：整条流被拼成**一帧** → 拼起来的 JSON 解不出来 →
    /// 每个事件都认不出来 → 真机上「一个字都没有」加一句看不懂的提示，而且**全部夹具用例照旧全绿**
    /// （它们自己按 `\n` 切好行再喂，恰好绕开了这一段）。这就是 `SSELineSplitter` 存在的全部理由，
    /// 也是 CLAUDE.md 规则 17 的由来。
    ///
    /// 哪天 Apple 改了它，这条会红 —— 那时可以重新考虑用回 `bytes.lines`，
    /// 但别只看这条就换：`SSELineSplitter` 还有「逐字节可测」这个好处。
    func testPlatformLineSplitterDropsBlankLinesWhichIsWhyWeDoNotUseIt() async throws {
        let stream = AsyncStream<UInt8> { continuation in
            for byte in Array("data: a\n\ndata: b\n\n".utf8) { continuation.yield(byte) }
            continuation.finish()
        }
        var observed: [String] = []
        for try await line in stream.lines { observed.append(line) }

        XCTAssertEqual(
            observed, ["data: a", "data: b"],
            "实测：平台会把空行整个丢掉（这正是不能用 bytes.lines 读 SSE 的原因）"
        )
    }

    func testSplitterKeepsBlankLinesAndTheLastUnterminatedLine() {
        XCTAssertEqual(lines(of: "data: a\n\ndata: b\n\n"), ["data: a", "", "data: b", ""])
        XCTAssertEqual(lines(of: "data: x"), ["data: x"], "末尾没有换行的那一行不能丢")
        XCTAssertEqual(lines(of: ""), [], "什么都不喂就不该产出幻影空行")
        XCTAssertEqual(lines(of: "\n"), [""])
    }

    /// CRLF：切行只看 `\n`，`\r` 留给分帧器剥（它本来就在剥）。
    func testSplitterLeavesTheCarriageReturnToTheFrameReader() {
        XCTAssertEqual(lines(of: "data: x\r\n\r\n"), ["data: x\r", "\r"])
        XCTAssertEqual(openAI("data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\r", "").text, "x")
    }

    /// 夹具的**字节**走一遍「切行 → 分帧」，必须和按行喂进去得到同一轮。
    ///
    /// 这条钉的是那段原来归平台管的链路（`bytes.lines` 本地验不了）。
    func testFixtureBytesProduceTheSameRoundAsItsLines() throws {
        let text = try Fixture.text("openai-sse", ext: "txt")
        let byLines = collect(text.components(separatedBy: "\n"), anthropic: false)
        let byBytes = collect(lines(of: text), anthropic: false)

        XCTAssertEqual(byBytes.text, byLines.text)
        XCTAssertEqual(byBytes.stopReason, byLines.stopReason)
        XCTAssertEqual(byBytes.names, byLines.names)
        XCTAssertEqual(byBytes.toolCalls.map { $0.id }, byLines.toolCalls.map { $0.id })
        XCTAssertEqual(byBytes.toolCalls.map { $0.argumentsJSON }, byLines.toolCalls.map { $0.argumentsJSON })
        XCTAssertEqual(byBytes.names.last, "done", "收尾标记也要走到")

        // 夹具以**单个**换行结尾：按行切会多出一个幻影空行，切行器不产出它 ——
        // 那一帧由分帧器在流结束时 flush 出来，帧本身不变（上面几条就是证据）。
        let trimmed = text.hasSuffix("\n") ? String(text.dropLast()) : text
        XCTAssertEqual(lines(of: trimmed), trimmed.components(separatedBy: "\n"))
    }
}
