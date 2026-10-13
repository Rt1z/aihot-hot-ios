import XCTest

@testable import AIHOT

/// 假的 Tavily：记下被调用的工具与参数，返回预设文本（与 FakeAnySearch 同形）。
private final class FakeTavily: TavilyCalling {

    var nextText = "### 1. 结果\nhttps://example.com\n\n摘要"
    var nextError: Error?
    private(set) var calls: [(tool: String, arguments: [String: Any])] = []

    func call(tool: String, arguments: [String: Any], apiKey: String) async throws -> String {
        calls.append((tool: tool, arguments: arguments))
        if let error = nextError { throw error }
        return nextText
    }
}

final class TavilyTests: XCTestCase {

    // MARK: - 响应解析（两份夹具都是实际调回来的 200 字节）

    /// 断言全部从抓到的字节推导：查询词「Karpathy 认知鸿沟」、5 条结果、answer 为 null。
    func testSearchFixtureBecomesMarkdownForTheModel() throws {
        let data = try Fixture.data("tavily-search", ext: "json")
        let text = try TavilyAPI.searchText(from: data)

        XCTAssertTrue(text.hasPrefix("### 1. Karpathy 主帖"), "第 1 条标题，实际开头：\(text.prefix(60))")
        XCTAssertTrue(text.contains("https://www.cnblogs.com/gyc567/p/19848269"), "条目里带 URL")
        XCTAssertTrue(text.contains("### 2. LLM能力共识正在撕裂"))
        XCTAssertTrue(text.contains("### 5. 75%人口未接触LLM"), "抓到的最后一条")
        XCTAssertFalse(text.hasPrefix(">"), "夹具里 answer 是 null，不该出现引用块")
    }

    /// answer 非空时前置引用块（夹具里是 null，这条用合成体钉格式）。
    func testSearchAnswerIsPrefixedAsQuoteWhenPresent() throws {
        let data = Data(#"{"answer":"一句话结论","results":[{"title":"T","url":"https://e.com","content":"C"}]}"#.utf8)
        let text = try TavilyAPI.searchText(from: data)
        XCTAssertTrue(text.hasPrefix("> 一句话结论"))
        XCTAssertTrue(text.contains("### 1. T"))
    }

    /// `raw_content` 本身就是 Markdown，原样交给模型；夹具里是单个页面、11418 字。
    func testExtractFixtureReturnsThePagesMarkdown() throws {
        let data = try Fixture.data("tavily-extract", ext: "json")
        let text = try TavilyAPI.extractText(from: data)

        XCTAssertTrue(text.hasPrefix("[# karpathy](/)"), "抓到的 raw_content 就是这么开头的")
        XCTAssertTrue(text.contains("# 2025 LLM Year in Review"))
        // 夹具里 raw_content 是 11418 字，但末尾带 3 个空白（`…Strap in.\n\n `），
        // trimmed 会剥掉 —— 断言必须从「解析后」的字节推导，11418 那个原始长度会红。
        XCTAssertEqual(text.count, 11415, "单个结果、trim 之后的长度")
    }

    /// **HTTP 200 也可能带非空的 `failed_results`** —— Tavily 版的 `isError` 陷阱（规则 13）。
    /// 少了这一查，「提取失败」的说明会被当成正文喂给模型。
    ///
    /// 合成体：failed_results 的条目形状没真抓过（夹具里是 []），字段全可选。
    /// 这里连「同时有成功结果」的情况也钉住：部分失败同样必须抛。
    func testExtractWithFailedResultsThrowsEvenUnderHTTP200() {
        let data = Data(
            #"{"results":[{"url":"https://ok.com","raw_content":"正文"}],"failed_results":[{"url":"https://bad.com","error":"fetch failed"}]}"#
                .utf8
        )
        XCTAssertThrowsError(try TavilyAPI.extractText(from: data), "失败绝不能当正文返回") { error in
            let message = (error as? APIError)?.message ?? ""
            XCTAssertTrue(message.contains("Tavily 提取失败"), "实际：\(message)")
            XCTAssertTrue(message.contains("fetch failed"), "要把接口原话带出来，实际：\(message)")
        }
    }

    /// 认不出原因时也要点名是哪个页面，而不是含糊一句「失败了」。
    func testFailedResultWithoutReasonStillNamesThePage() {
        let data = Data(#"{"results":[],"failed_results":[{"url":"https://bad.com"}]}"#.utf8)
        XCTAssertThrowsError(try TavilyAPI.extractText(from: data)) { error in
            XCTAssertTrue((error as? APIError)?.message.contains("bad.com") == true)
        }
    }

    func testSearchWithNoResultsThrowsInsteadOfReturningEmptyString() {
        let data = Data(#"{"query":"x","results":[],"answer":null}"#.utf8)
        XCTAssertThrowsError(try TavilyAPI.searchText(from: data)) { error in
            XCTAssertTrue((error as? APIError)?.message.contains("没有返回可用内容") == true)
        }
    }

    func testExtractWithNoResultsThrowsInsteadOfReturningEmptyString() {
        let data = Data(#"{"results":[],"failed_results":[]}"#.utf8)
        XCTAssertThrowsError(try TavilyAPI.extractText(from: data))
    }

    func testGarbageThrows() {
        XCTAssertThrowsError(try TavilyAPI.searchText(from: Data("not json".utf8)))
        XCTAssertThrowsError(try TavilyAPI.extractText(from: Data("not json".utf8)))
    }

    // MARK: - 错误状态码
    //
    // 与 AnySearch 相反，Tavily 的失败**主要就走状态码**（401/403 是主路径而非兜底）。
    // 错误体是合成的（夹具只抓了 200，真实错误形状没抓过）——这里钉的是
    // 「message 会带上能照做的提示 / 接口原话」这条链路。

    func testUnauthorizedNamesTheKeyAndTheWayOut() {
        let error = TavilyAPI.apiError(statusCode: 401, data: Data())
        XCTAssertEqual(error.kind, .server(401))
        XCTAssertTrue(error.message.contains("Key 无效"), "实际：\(error.message)")
        XCTAssertTrue(error.message.contains("搜索工具"), "要给出退路：设置里的搜索工具一节（退路是链，不是切回某家）")
    }

    func testForbiddenIsTreatedTheSameAsUnauthorized() {
        let error = TavilyAPI.apiError(statusCode: 403, data: Data())
        XCTAssertTrue(error.message.contains("Key 无效"))
    }

    func testRateLimitSaysTooManyRequests() {
        let error = TavilyAPI.apiError(statusCode: 429, data: Data())
        XCTAssertTrue(error.message.contains("频繁"), "实际：\(error.message)")
    }

    func testOtherStatusesCarryTheProblemMessage() {
        let body = Data(#"{"error":{"message":"invalid query"}}"#.utf8)
        let error = TavilyAPI.apiError(statusCode: 400, data: body)
        XCTAssertEqual(error.kind, .server(400))
        XCTAssertTrue(error.message.contains("400"))
        XCTAssertTrue(error.message.contains("invalid query"), "problemMessage 的原话要进 message")
    }

    // MARK: - 工具分发

    func testWebSearchPassesQueryAndCapsResults() async {
        let fake = FakeTavily()
        let runner = TavilyToolRunner(apiKey: "tvly-key", api: fake)
        let call = AIChatToolCall(
            index: 0, id: "c1", name: AIChatToolName.webSearch,
            argumentsJSON: #"{"query":"Karpathy 后续"}"#
        )

        let outcome = await runner.execute(call: call)
        XCTAssertFalse(outcome.isError)
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(fake.calls.first?.tool, "search")
        XCTAssertEqual(fake.calls.first?.arguments["query"] as? String, "Karpathy 后续")
        XCTAssertEqual(fake.calls.first?.arguments["max_results"] as? Int, TavilyToolRunner.searchResults)
    }

    /// Tavily 的提取参数是 `urls`（数组）+ `format: "markdown"`，与 AnySearch 的单个 `url` 不同。
    func testReadURLUsesExtractWithUrlsArrayAndMarkdownFormat() async {
        let fake = FakeTavily()
        fake.nextText = "# 页面标题\n正文"
        let runner = TavilyToolRunner(apiKey: "tvly-key", api: fake)
        let call = AIChatToolCall(
            index: 0, id: "c2", name: AIChatToolName.readURL,
            argumentsJSON: #"{"url":"https://example.com/a"}"#
        )

        let outcome = await runner.execute(call: call)
        XCTAssertFalse(outcome.isError)
        XCTAssertEqual(fake.calls.first?.tool, "extract")
        XCTAssertEqual(
            fake.calls.first?.arguments["urls"] as? [String], ["https://example.com/a"],
            "参数名是 urls、值是数组"
        )
        XCTAssertEqual(fake.calls.first?.arguments["format"] as? String, "markdown")
        XCTAssertTrue(outcome.text.contains("页面标题"))
    }

    /// Tavily 没有匿名模式：空 key 一个网络请求都不发，直接回一句能照做的话。
    func testEmptyKeyNeverHitsTheNetwork() async {
        let fake = FakeTavily()
        let runner = TavilyToolRunner(apiKey: "   ", api: fake)

        let outcome = await runner.execute(
            call: AIChatToolCall(index: 0, id: "c3", name: AIChatToolName.webSearch, argumentsJSON: #"{"query":"x"}"#)
        )
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(fake.calls.isEmpty, "没 key 就不该发网络")
        XCTAssertTrue(outcome.text.contains("Tavily 的 Key"), "要给出能照做的提示，实际：\(outcome.text)")
        XCTAssertTrue(outcome.text.contains("搜索工具"), "顺带给出设置路径（退路是链，不是切回某家）")
    }

    func testMissingArgumentIsReportedAsToolErrorNotACrash() async {
        let fake = FakeTavily()
        let runner = TavilyToolRunner(apiKey: "k", api: fake)

        let search = await runner.execute(
            call: AIChatToolCall(index: 0, id: "c4", name: AIChatToolName.webSearch, argumentsJSON: "{}")
        )
        XCTAssertTrue(search.isError)
        XCTAssertTrue(fake.calls.isEmpty, "参数不全就不该去调服务")

        let read = await runner.execute(
            call: AIChatToolCall(index: 1, id: "c5", name: AIChatToolName.readURL, argumentsJSON: "{}")
        )
        XCTAssertTrue(read.isError)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testUnknownToolIsRefused() async {
        let runner = TavilyToolRunner(apiKey: "k", api: FakeTavily())
        let outcome = await runner.execute(
            call: AIChatToolCall(index: 0, id: "c6", name: "delete_everything", argumentsJSON: "{}")
        )
        XCTAssertTrue(outcome.isError, "模型偶尔会编一个不存在的工具名")
    }

    func testServiceFailureComesBackAsToolError() async {
        let fake = FakeTavily()
        fake.nextError = APIError(kind: .server(429), message: "Tavily 请求过于频繁（429），稍等片刻再试")
        let runner = TavilyToolRunner(apiKey: "k", api: fake)

        let outcome = await runner.execute(
            call: AIChatToolCall(index: 0, id: "c7", name: AIChatToolName.webSearch, argumentsJSON: #"{"query":"x"}"#)
        )
        XCTAssertTrue(outcome.isError, "工具失败要当成 is_error 回传，让模型自己换个说法，而不是整轮报错")
        XCTAssertTrue(outcome.text.contains("429"))
    }

    /// extract 单页可能很长，回传前必须截断（截断时会写明）。
    func testLongResultIsTruncatedWithAMarker() async {
        let fake = FakeTavily()
        fake.nextText = String(repeating: "内容", count: 6000)
        let runner = TavilyToolRunner(apiKey: "k", api: fake)

        let outcome = await runner.execute(
            call: AIChatToolCall(index: 0, id: "c8", name: AIChatToolName.readURL, argumentsJSON: #"{"url":"https://example.com/long"}"#)
        )
        XCTAssertFalse(outcome.isError)
        XCTAssertTrue(outcome.text.contains("已截断"))
    }
}
