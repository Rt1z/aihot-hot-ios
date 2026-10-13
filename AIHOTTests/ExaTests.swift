import XCTest

@testable import AIHOT

/// 假的 Exa：记下被调用的工具与参数，返回预设文本（与 FakeTavily 同形）。
private final class FakeExa: ExaCalling {

    var nextText = "### 1. 结果\nhttps://example.com\n\n摘要"
    var nextError: Error?
    private(set) var calls: [(tool: String, arguments: [String: Any])] = []

    func call(tool: String, arguments: [String: Any], apiKey: String) async throws -> String {
        calls.append((tool: tool, arguments: arguments))
        if let error = nextError { throw error }
        return nextText
    }
}

final class ExaTests: XCTestCase {

    // MARK: - 搜索响应解析（夹具是实际调回来的 200 字节）

    /// 断言全部从抓到的字节推导：5 条 results、每条 text 恰 500 字
    /// （`maxCharacters: 500` 实测生效）、第 1 条 URL 与「第一部分」原文。
    func testSearchFixtureBecomesMarkdownForTheModel() throws {
        let data = try Fixture.data("exa-search", ext: "json")
        let text = try ExaAPI.searchText(from: data)

        XCTAssertTrue(text.hasPrefix("### 1. Karpathy 主帖：从我的时间线来看"),
                      "第 1 条标题，实际开头：\(text.prefix(60))")
        XCTAssertTrue(text.contains("https://www.cnblogs.com/gyc567/p/19848269"), "条目里带 URL")
        XCTAssertTrue(text.contains("第一部分"), "第 1 条抓到的 text 原文")
        XCTAssertTrue(text.contains("### 5. Karpathy：对 LLM 能力的共识"), "最后一条（第 5 条）")
        XCTAssertEqual(text.components(separatedBy: "### ").count - 1, 5, "5 条一条不能丢")
    }

    /// 200 也可能带顶层 `error`（防御分支，合成钉）—— 报错绝不能当结果。
    func testTopLevelErrorUnderHTTP200ThrowsInsteadOfBecomingResults() {
        let data = Data(#"{"error":"billing issue","results":[{"title":"T","url":"https://e.com","text":"C"}]}"#.utf8)
        XCTAssertThrowsError(try ExaAPI.searchText(from: data)) { error in
            let message = (error as? APIError)?.message ?? ""
            XCTAssertTrue(message.contains("Exa 报错"), "实际：\(message)")
            XCTAssertTrue(message.contains("billing issue"), "接口原话要带上")
        }
    }

    func testSearchWithNoResultsThrowsInsteadOfReturningEmptyString() {
        let data = Data(#"{"results":[]}"#.utf8)
        XCTAssertThrowsError(try ExaAPI.searchText(from: data)) { error in
            XCTAssertTrue((error as? APIError)?.message.contains("没有返回可用内容") == true)
        }
    }

    func testGarbageThrows() {
        XCTAssertThrowsError(try ExaAPI.searchText(from: Data("not json".utf8)))
        XCTAssertThrowsError(try ExaAPI.contentsText(from: Data("not json".utf8)))
    }

    // MARK: - 读网页响应解析（夹具是实际调回来的 200 字节）

    /// 单页正文原样返回；夹具里 10689 字 —— 请求要的是 8000，**服务端没严格遵守**，
    /// 靠 `AIChatToolResult.clamp` 在回传前兜底，这里钉住真实字节数。
    func testContentsFixtureReturnsThePagesText() throws {
        let data = try Fixture.data("exa-contents", ext: "json")
        let text = try ExaAPI.contentsText(from: data)

        XCTAssertTrue(text.hasPrefix("2025 LLM Year in Review – karpathy"),
                      "抓到的正文就是这么开头的，实际：\(text.prefix(50))")
        XCTAssertTrue(text.hasSuffix("Strap in."), "抓到的正文结尾")
        XCTAssertEqual(text.count, 10689, "请求了 8000、实测回了 10689 —— 断言从字节推导")
        XCTAssertEqual(text.components(separatedBy: "### ").count - 1, 0,
                       "正文直接返回，不套搜索结果的标题块")
    }

    /// **HTTP 200 也可能有 `statuses[]` 失败条目** —— Tavily `failed_results` 的同款陷阱
    /// （规则 13）。少了这一查，「提取失败」会被当成空正文喂给模型。
    ///
    /// 合成体：失败条目的形状没真抓过（夹具里是全 success），字段全可选。
    func testFailedStatusThrowsEvenUnderHTTP200() {
        let data = Data(
            #"{"results":[{"url":"https://ok.com","text":"正文"}],"statuses":[{"id":"https://bad.com","status":"failure"}]}"#
                .utf8
        )
        XCTAssertThrowsError(try ExaAPI.contentsText(from: data), "失败绝不能当正文返回") { error in
            let message = (error as? APIError)?.message ?? ""
            XCTAssertTrue(message.contains("Exa 提取失败"), "实际：\(message)")
            XCTAssertTrue(message.contains("bad.com"), "没有原话时点名是哪个页面，实际：\(message)")
        }
    }

    /// 接口给了失败原因时优先用原话。
    func testFailedStatusPrefersTheReasonVerbatim() {
        let data = Data(
            #"{"results":[{"url":"https://ok.com","text":"正文"}],"statuses":[{"id":"https://bad.com","status":"failure","error":"fetch failed"}]}"#
                .utf8
        )
        XCTAssertThrowsError(try ExaAPI.contentsText(from: data)) { error in
            let message = (error as? APIError)?.message ?? ""
            XCTAssertTrue(message.contains("Exa 提取失败"), "实际：\(message)")
            XCTAssertTrue(message.contains("fetch failed"), "接口原话要带出来，实际：\(message)")
        }
    }

    func testContentsWithNoTextThrowsInsteadOfReturningEmptyString() {
        let data = Data(#"{"results":[],"statuses":[]}"#.utf8)
        XCTAssertThrowsError(try ExaAPI.contentsText(from: data)) { error in
            XCTAssertTrue((error as? APIError)?.message.contains("没有返回可用内容") == true)
        }
    }

    // MARK: - 错误状态码（错误夹具是假 Key 免费探针抓的真 401 字节）

    func testUnauthorizedFromCapturedErrorNamesKeyAndSettingsPath() throws {
        let data = try Fixture.data("exa-error", ext: "json")
        let error = ExaAPI.apiError(statusCode: 401, data: data)
        XCTAssertEqual(error.kind, .server(401))
        XCTAssertTrue(error.message.contains("Key 无效"), "实际：\(error.message)")
        XCTAssertTrue(error.message.contains("搜索工具"), "要给出能照做的路径，实际：\(error.message)")
        XCTAssertTrue(error.message.contains("接口原话"), "要把真错误带出来，实际：\(error.message)")
        XCTAssertTrue(error.message.contains("Invalid API key"), "夹具里的原话，实际：\(error.message)")
    }

    func testForbiddenIsTreatedTheSameAsUnauthorized() {
        let error = ExaAPI.apiError(statusCode: 403, data: Data())
        XCTAssertTrue(error.message.contains("Key 无效"))
    }

    /// Exa 用 402 表示额度用尽（信封里的 `tag` 是另一维度，不参与状态码分支）。
    func testPaymentRequiredSaysCreditsRanOut() {
        let error = ExaAPI.apiError(statusCode: 402, data: Data())
        XCTAssertTrue(error.message.contains("额度用尽"), "实际：\(error.message)")
        XCTAssertTrue(error.message.contains("搜索工具"), "要给出退路，实际：\(error.message)")
    }

    func testRateLimitSaysTooManyRequests() {
        let error = ExaAPI.apiError(statusCode: 429, data: Data())
        XCTAssertTrue(error.message.contains("频繁"), "实际：\(error.message)")
        XCTAssertEqual(error.kind, .rateLimited(retryAfter: nil))
    }

    /// 其它状态码走单字段 `error` 的原话（信封 `{requestId, error, tag}`，`problemMessage` 认不出）。
    func testOtherStatusesCarryTheEnvelopeError() {
        let body = Data(#"{"requestId":"r1","error":"invalid numResults","tag":"INVALID_REQUEST"}"#.utf8)
        let error = ExaAPI.apiError(statusCode: 400, data: body)
        XCTAssertEqual(error.kind, .server(400))
        XCTAssertTrue(error.message.contains("400"))
        XCTAssertTrue(error.message.contains("invalid numResults"), "实际：\(error.message)")
    }

    // MARK: - 工具分发

    /// 搜索请求体：query + numResults 5 + 内联摘要 500 字（夹具就是按这个形状抓的）。
    func testWebSearchPassesQueryWithInlineSnippetCap() async {
        let fake = FakeExa()
        let runner = ExaToolRunner(apiKey: "exa-key", api: fake)
        let call = AIChatToolCall(
            index: 0, id: "c1", name: AIChatToolName.webSearch,
            argumentsJSON: #"{"query":"Karpathy 后续"}"#
        )

        let outcome = await runner.execute(call: call)
        XCTAssertFalse(outcome.isError)
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(fake.calls.first?.tool, "search")
        XCTAssertEqual(fake.calls.first?.arguments["query"] as? String, "Karpathy 后续")
        XCTAssertEqual(fake.calls.first?.arguments["numResults"] as? Int, ExaToolRunner.searchResults)
        let contents = fake.calls.first?.arguments["contents"] as? [String: [String: Int]]
        XCTAssertEqual(contents?["text"]?["maxCharacters"], ExaToolRunner.searchSnippetCharacters)
    }

    /// 读网页请求体：urls 数组 + 8000 字上限（实测服务端不严格遵守，clamp 兜底）。
    func testReadURLUsesContentsWithUrlsArray() async {
        let fake = FakeExa()
        fake.nextText = "# 页面标题\n正文"
        let runner = ExaToolRunner(apiKey: "exa-key", api: fake)
        let call = AIChatToolCall(
            index: 0, id: "c2", name: AIChatToolName.readURL,
            argumentsJSON: #"{"url":"https://example.com/a"}"#
        )

        let outcome = await runner.execute(call: call)
        XCTAssertFalse(outcome.isError)
        XCTAssertEqual(fake.calls.first?.tool, "contents")
        XCTAssertEqual(fake.calls.first?.arguments["urls"] as? [String], ["https://example.com/a"],
                       "参数名是 urls、值是数组")
        let contents = fake.calls.first?.arguments["contents"] as? [String: [String: Int]]
        XCTAssertEqual(contents?["text"]?["maxCharacters"], ExaToolRunner.contentsCharacters)
        XCTAssertTrue(outcome.text.contains("页面标题"))
    }

    /// Exa 没有匿名模式：空 key 一个网络请求都不发。
    func testEmptyKeyNeverHitsTheNetwork() async {
        let fake = FakeExa()
        let runner = ExaToolRunner(apiKey: "   ", api: fake)

        let outcome = await runner.execute(
            call: AIChatToolCall(index: 0, id: "c3", name: AIChatToolName.webSearch, argumentsJSON: #"{"query":"x"}"#)
        )
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(fake.calls.isEmpty, "没 key 就不该发网络")
        XCTAssertTrue(outcome.text.contains("Exa 的 Key"), "要给出能照做的提示，实际：\(outcome.text)")
        XCTAssertTrue(outcome.text.contains("搜索工具"), "顺带给出设置路径")
    }

    func testMissingArgumentIsReportedAsToolErrorNotACrash() async {
        let fake = FakeExa()
        let runner = ExaToolRunner(apiKey: "k", api: fake)

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
        let runner = ExaToolRunner(apiKey: "k", api: FakeExa())
        let outcome = await runner.execute(
            call: AIChatToolCall(index: 0, id: "c6", name: "delete_everything", argumentsJSON: "{}")
        )
        XCTAssertTrue(outcome.isError, "模型偶尔会编一个不存在的工具名")
    }

    func testServiceFailureComesBackAsToolError() async {
        let fake = FakeExa()
        fake.nextError = APIError(kind: .server(429), message: "Exa 请求过于频繁（429），稍等片刻再试")
        let runner = ExaToolRunner(apiKey: "k", api: fake)

        let outcome = await runner.execute(
            call: AIChatToolCall(index: 0, id: "c7", name: AIChatToolName.webSearch, argumentsJSON: #"{"query":"x"}"#)
        )
        XCTAssertTrue(outcome.isError, "工具失败要当成 is_error 回传，让模型自己换个说法，而不是整轮报错")
        XCTAssertTrue(outcome.text.contains("429"))
    }

    /// 读网页单页可能很长（夹具实测 10689 > 8000），回传前必须截断（截断时会写明）。
    func testLongResultIsTruncatedWithAMarker() async {
        let fake = FakeExa()
        fake.nextText = String(repeating: "内容", count: 6000)
        let runner = ExaToolRunner(apiKey: "k", api: fake)

        let outcome = await runner.execute(
            call: AIChatToolCall(index: 0, id: "c8", name: AIChatToolName.readURL, argumentsJSON: #"{"url":"https://example.com/long"}"#)
        )
        XCTAssertFalse(outcome.isError)
        XCTAssertTrue(outcome.text.contains("已截断"))
    }
}
