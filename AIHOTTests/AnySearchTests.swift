import XCTest

@testable import AIHOT

/// 假的 AnySearch：记下被调用的工具与参数，返回预设文本。
private final class FakeAnySearch: AnySearchCalling {

    var nextText = "## Search Results\n1. 结果"
    var nextError: Error?
    private(set) var calls: [(tool: String, arguments: [String: Any])] = []

    func call(tool: String, arguments: [String: Any], apiKey: String) async throws -> String {
        calls.append((tool: tool, arguments: arguments))
        if let error = nextError { throw error }
        return nextText
    }
}

final class AnySearchTests: XCTestCase {

    // MARK: - 响应解析（夹具是我实际调回来的那一份）

    func testParsesTheRealResponseFixture() throws {
        let data = try Fixture.data("anysearch-search", ext: "json")
        let text = try AnySearchAPI.resultText(from: data)

        XCTAssertTrue(text.hasPrefix("## Search Results"), "取到的就是排好的 Markdown，可以直接给模型")
        XCTAssertTrue(text.contains("https://karpathy.bearblog.dev/year-in-review-2025/"), "结果里带 URL")
        XCTAssertTrue(text.contains("**URL**"))
    }

    /// **无效 key 的真实形状**：HTTP 200、顶层没有 error，失败靠 `result.isError`
    /// 表达、原因写在 `content[0].text` 里。这份夹具是真跑出来的字节。
    ///
    /// 这条以前是用手写的 `{"error":{"message":"Invalid API key"}}` 测的 —— 那个形状
    /// 服务端根本不发，于是「只查顶层 error」的写法一直是绿的，而线上无效 key 时
    /// `invalid_api_key / Invalid API key.` 会被当成搜索结果交给模型。
    func testBadKeyComesBackAsHTTP200WithIsErrorAndMustNotBecomeAResult() throws {
        let data = try Fixture.data("anysearch-error", ext: "json")

        XCTAssertThrowsError(try AnySearchAPI.resultText(from: data), "错误文案绝不能当搜索结果返回") { error in
            let message = (error as? APIError)?.message ?? ""
            XCTAssertTrue(message.contains("Key 无效"), "要给出能照做的提示，实际是：\(message)")
        }
    }

    func testIsErrorWithoutTheInvalidKeyCodeStillThrowsWithTheOriginalText() {
        let data = Data(#"{"result":{"content":[{"type":"text","text":"boom"}],"isError":true}}"#.utf8)
        XCTAssertThrowsError(try AnySearchAPI.resultText(from: data)) { error in
            XCTAssertTrue((error as? APIError)?.message.contains("boom") == true)
        }
    }

    func testIsErrorWithNoTextAtAllStillThrows() {
        let data = Data(#"{"result":{"content":[],"isError":true}}"#.utf8)
        XCTAssertThrowsError(try AnySearchAPI.resultText(from: data))
    }

    func testIsErrorFalseIsJustANormalResult() throws {
        let data = Data(#"{"result":{"content":[{"type":"text","text":"ok"}],"isError":false}}"#.utf8)
        XCTAssertEqual(try AnySearchAPI.resultText(from: data), "ok")
    }

    func testJSONRPCErrorSurfacesTheOriginalMessage() {
        let data = Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Invalid API key"}}"#.utf8)
        XCTAssertThrowsError(try AnySearchAPI.resultText(from: data)) { error in
            XCTAssertTrue((error as? APIError)?.message.contains("Invalid API key") == true)
        }
    }

    func testEmptyContentThrowsInsteadOfReturningEmptyString() {
        let data = Data(#"{"jsonrpc":"2.0","id":1,"result":{"content":[]}}"#.utf8)
        XCTAssertThrowsError(try AnySearchAPI.resultText(from: data))
    }

    func testGarbageThrows() {
        XCTAssertThrowsError(try AnySearchAPI.resultText(from: Data("not json".utf8)))
    }

    func testTrimsWhitespaceAndSkipsNonTextBlocks() throws {
        let data = Data(#"{"result":{"content":[{"type":"image"},{"type":"text","text":"  内容  "}]}}"#.utf8)
        XCTAssertEqual(try AnySearchAPI.resultText(from: data), "内容")
    }

    // MARK: - 工具分发

    func testWebSearchPassesQueryAndCapsResults() async {
        let fake = FakeAnySearch()
        let runner = AnySearchToolRunner(apiKey: "", api: fake)
        let call = AIChatToolCall(
            index: 0, id: "c1", name: AIChatToolName.webSearch,
            argumentsJSON: #"{"query":"Karpathy 后续"}"#
        )

        let outcome = await runner.execute(call: call)
        XCTAssertFalse(outcome.isError)
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(fake.calls.first?.tool, "search")
        XCTAssertEqual(fake.calls.first?.arguments["query"] as? String, "Karpathy 后续")
        XCTAssertEqual(fake.calls.first?.arguments["max_results"] as? Int, AnySearchToolRunner.searchResults)
    }

    func testReadURLUsesExtract() async {
        let fake = FakeAnySearch()
        fake.nextText = "# 页面标题\n正文"
        let runner = AnySearchToolRunner(apiKey: "", api: fake)
        let call = AIChatToolCall(
            index: 0, id: "c2", name: AIChatToolName.readURL,
            argumentsJSON: #"{"url":"https://example.com/a"}"#
        )

        let outcome = await runner.execute(call: call)
        XCTAssertFalse(outcome.isError)
        XCTAssertEqual(fake.calls.first?.tool, "extract")
        XCTAssertEqual(fake.calls.first?.arguments["url"] as? String, "https://example.com/a")
        XCTAssertTrue(outcome.text.contains("页面标题"))
    }

    func testMissingArgumentIsReportedAsToolErrorNotACrash() async {
        let fake = FakeAnySearch()
        let runner = AnySearchToolRunner(apiKey: "", api: fake)

        let search = await runner.execute(
            call: AIChatToolCall(index: 0, id: "c3", name: AIChatToolName.webSearch, argumentsJSON: "{}")
        )
        XCTAssertTrue(search.isError)
        XCTAssertTrue(fake.calls.isEmpty, "参数不全就不该去调服务")

        let read = await runner.execute(
            call: AIChatToolCall(index: 1, id: "c4", name: AIChatToolName.readURL, argumentsJSON: "{}")
        )
        XCTAssertTrue(read.isError)
    }

    func testUnknownToolIsRefused() async {
        let runner = AnySearchToolRunner(apiKey: "", api: FakeAnySearch())
        let outcome = await runner.execute(
            call: AIChatToolCall(index: 0, id: "c5", name: "delete_everything", argumentsJSON: "{}")
        )
        XCTAssertTrue(outcome.isError, "模型偶尔会编一个不存在的工具名")
    }

    func testServiceFailureComesBackAsToolError() async {
        let fake = FakeAnySearch()
        fake.nextError = APIError(kind: .server(429), message: "搜索服务返回 429")
        let runner = AnySearchToolRunner(apiKey: "", api: fake)

        let outcome = await runner.execute(
            call: AIChatToolCall(
                index: 0, id: "c6", name: AIChatToolName.webSearch,
                argumentsJSON: #"{"query":"x"}"#
            )
        )
        XCTAssertTrue(outcome.isError, "工具失败要当成 is_error 回传，让模型自己换个说法，而不是整轮报错")
        XCTAssertTrue(outcome.text.contains("429"))
    }

    /// `extract` 单页能返回到 5 万字，直接回传会顶爆上下文、也很贵。
    func testLongResultIsTruncatedWithAMarker() {
        let huge = String(repeating: "内容", count: 6000)
        let clamped = AIChatToolResult.clamp(huge)
        XCTAssertLessThanOrEqual(clamped.count, AIChatToolResult.maximumCharacters + 20)
        XCTAssertTrue(clamped.contains("已截断"))
    }
}
