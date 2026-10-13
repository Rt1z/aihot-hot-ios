import XCTest

@testable import AIHOT

/// 假的 SerpAPI：记下被调用的工具与参数，返回预设文本（与 FakeTavily 同形）。
private final class FakeSerpAPI: SerpAPICalling {

    var nextText = "### 1. 结果\nhttps://example.com\n\n摘要"
    var nextError: Error?
    private(set) var calls: [(tool: String, arguments: [String: Any])] = []

    func call(tool: String, arguments: [String: Any], apiKey: String) async throws -> String {
        calls.append((tool: tool, arguments: arguments))
        if let error = nextError { throw error }
        return nextText
    }
}

final class SerpAPITests: XCTestCase {

    // MARK: - 响应解析（夹具是实际调回来的 200 字节）

    /// 断言全部从抓到的字节推导：9 条 organic_results、7 条有 snippet、
    /// 第 1 条的 title 就是它自己的 link（不许重复印两行 URL）。
    func testSearchFixtureBecomesMarkdownForTheModel() throws {
        let data = try Fixture.data("serpapi-search", ext: "json")
        let text = try SerpAPI.searchText(from: data)

        XCTAssertTrue(text.hasPrefix("### 1. https://news.qq.com/rain/a/20251209A04T2S00"),
                      "第 1 条 title==link，实际开头：\(text.prefix(80))")
        let qqURL = "https://news.qq.com/rain/a/20251209A04T2S00"
        XCTAssertEqual(text.components(separatedBy: qqURL).count - 1, 1,
                       "title 就是链接时只该出现一次，不能标题一行再加链接一行")
        XCTAssertTrue(text.contains("### 3. Karpathy：80 亿人被AI 认知鸿沟分成四个层级"))
        XCTAssertTrue(text.contains("No information is available for this page."),
                      "snippet 容缺也容有：这是第 2 条抓到的 snippet 原文")
        XCTAssertEqual(text.components(separatedBy: "### ").count - 1, 9,
                       "9 条结果一个不能丢（含 2 条没 snippet 的）")
    }

    /// 200 也可能带顶层 `error` 字符串 —— 先查它，别把报错当结果。
    ///
    /// 合成体：这个分支没有免费触发的办法，真实形状没抓过。
    func testTopLevelErrorUnderHTTP200ThrowsInsteadOfBecomingResults() {
        let data = Data(#"{"error":"Your account has run out of searches.","organic_results":[]}"#.utf8)
        XCTAssertThrowsError(try SerpAPI.searchText(from: data), "报错绝不能当结果返回") { error in
            let message = (error as? APIError)?.message ?? ""
            XCTAssertTrue(message.contains("SerpAPI 报错"), "实际：\(message)")
            XCTAssertTrue(message.contains("run out of searches"), "接口原话要带上，实际：\(message)")
        }
    }

    func testSearchWithNoResultsThrowsInsteadOfReturningEmptyString() {
        let data = Data(#"{"organic_results":[]}"#.utf8)
        XCTAssertThrowsError(try SerpAPI.searchText(from: data)) { error in
            XCTAssertTrue((error as? APIError)?.message.contains("没有返回可用内容") == true)
        }
    }

    func testGarbageThrows() {
        XCTAssertThrowsError(try SerpAPI.searchText(from: Data("not json".utf8)))
    }

    // MARK: - 错误状态码（错误夹具是假 Key 免费探针抓的真 401 字节）

    /// SerpAPI 的 Key 在**查询串**里 —— 文案里带出完整请求 URL 等于把 Key 印出去。
    func testUnauthorizedFromCapturedErrorNeverLeaksTheKeyOrUrl() throws {
        let data = try Fixture.data("serpapi-error", ext: "json")
        let error = SerpAPI.apiError(statusCode: 401, data: data)
        XCTAssertEqual(error.kind, .server(401))
        XCTAssertTrue(error.message.contains("Key 无效"), "实际：\(error.message)")
        XCTAssertTrue(error.message.contains("搜索工具"), "要给出能照做的路径，实际：\(error.message)")
        XCTAssertTrue(error.message.contains("接口原话"), "要把真错误带出来，实际：\(error.message)")
        XCTAssertTrue(error.message.contains("Invalid API key"), "夹具里的原话，实际：\(error.message)")
        XCTAssertFalse(error.message.contains("api_key="), "查询串绝不进文案")
        XCTAssertFalse(error.message.contains("serpapi.com/search?"), "完整请求 URL 绝不进文案")
    }

    func testForbiddenIsTreatedTheSameAsUnauthorized() {
        let error = SerpAPI.apiError(statusCode: 403, data: Data())
        XCTAssertTrue(error.message.contains("Key 无效"))
    }

    func testRateLimitSaysTooManyRequests() {
        let error = SerpAPI.apiError(statusCode: 429, data: Data())
        XCTAssertTrue(error.message.contains("频繁"), "实际：\(error.message)")
        XCTAssertEqual(error.kind, .rateLimited(retryAfter: nil))
    }

    /// 其它状态码走单字段 `{"error": …}` 的原话（`problemMessage` 认不出这种信封）。
    func testOtherStatusesCarryTheSingleFieldError() {
        let body = Data(#"{"error":"Missing query 'q' parameter."}"#.utf8)
        let error = SerpAPI.apiError(statusCode: 400, data: body)
        XCTAssertEqual(error.kind, .server(400))
        XCTAssertTrue(error.message.contains("400"))
        XCTAssertTrue(error.message.contains("Missing query"), "单字段原话要进 message，实际：\(error.message)")
    }

    // MARK: - 工具分发

    func testWebSearchPassesQueryWithGoogleEngine() async {
        let fake = FakeSerpAPI()
        let runner = SerpAPIToolRunner(apiKey: "serpapi-key", api: fake)
        let call = AIChatToolCall(
            index: 0, id: "c1", name: AIChatToolName.webSearch,
            argumentsJSON: #"{"query":"Karpathy 后续"}"#
        )

        let outcome = await runner.execute(call: call)
        XCTAssertFalse(outcome.isError)
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(fake.calls.first?.tool, "search")
        XCTAssertEqual(fake.calls.first?.arguments["q"] as? String, "Karpathy 后续")
        XCTAssertEqual(fake.calls.first?.arguments["engine"] as? String, "google")
    }

    /// SerpAPI 没有读网页能力：链不会路由过来，真到了照实回绝、零网络。
    func testReadURLIsRefusedWithoutAnyNetworkCall() async {
        let fake = FakeSerpAPI()
        let runner = SerpAPIToolRunner(apiKey: "k", api: fake)

        let outcome = await runner.execute(
            call: AIChatToolCall(index: 0, id: "c2", name: AIChatToolName.readURL,
                                 argumentsJSON: #"{"url":"https://example.com/a"}"#)
        )
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(outcome.text.contains("不支持读网页"), "实际：\(outcome.text)")
        XCTAssertTrue(fake.calls.isEmpty, "不支持的能力一次网络都不该发")
    }

    /// SerpAPI 没有匿名模式：空 key 一个网络请求都不发。
    func testEmptyKeyNeverHitsTheNetwork() async {
        let fake = FakeSerpAPI()
        let runner = SerpAPIToolRunner(apiKey: "   ", api: fake)

        let outcome = await runner.execute(
            call: AIChatToolCall(index: 0, id: "c3", name: AIChatToolName.webSearch, argumentsJSON: #"{"query":"x"}"#)
        )
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(fake.calls.isEmpty, "没 key 就不该发网络")
        XCTAssertTrue(outcome.text.contains("SerpAPI 的 Key"), "要给出能照做的提示，实际：\(outcome.text)")
        XCTAssertTrue(outcome.text.contains("搜索工具"), "顺带给出设置路径")
    }

    func testMissingArgumentIsReportedAsToolErrorNotACrash() async {
        let fake = FakeSerpAPI()
        let runner = SerpAPIToolRunner(apiKey: "k", api: fake)

        let outcome = await runner.execute(
            call: AIChatToolCall(index: 0, id: "c4", name: AIChatToolName.webSearch, argumentsJSON: "{}")
        )
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(fake.calls.isEmpty, "参数不全就不该去调服务")
    }

    func testUnknownToolIsRefused() async {
        let runner = SerpAPIToolRunner(apiKey: "k", api: FakeSerpAPI())
        let outcome = await runner.execute(
            call: AIChatToolCall(index: 0, id: "c5", name: "delete_everything", argumentsJSON: "{}")
        )
        XCTAssertTrue(outcome.isError, "模型偶尔会编一个不存在的工具名")
    }

    func testServiceFailureComesBackAsToolError() async {
        let fake = FakeSerpAPI()
        fake.nextError = APIError(kind: .server(429), message: "SerpAPI 请求过于频繁或额度用尽（429），稍等片刻再试")
        let runner = SerpAPIToolRunner(apiKey: "k", api: fake)

        let outcome = await runner.execute(
            call: AIChatToolCall(index: 0, id: "c6", name: AIChatToolName.webSearch, argumentsJSON: #"{"query":"x"}"#)
        )
        XCTAssertTrue(outcome.isError, "工具失败要当成 is_error 回传，让模型自己换个说法，而不是整轮报错")
        XCTAssertTrue(outcome.text.contains("429"))
    }
}
