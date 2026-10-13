import XCTest

@testable import AIHOT

/// 假的 Serper：记下被调用的工具与参数，返回预设文本（与 FakeTavily 同形）。
private final class FakeSerper: SerperCalling {

    var nextText = "### 1. 结果\nhttps://example.com\n\n摘要"
    var nextError: Error?
    private(set) var calls: [(tool: String, arguments: [String: Any])] = []

    func call(tool: String, arguments: [String: Any], apiKey: String) async throws -> String {
        calls.append((tool: tool, arguments: arguments))
        if let error = nextError { throw error }
        return nextText
    }
}

final class SerperTests: XCTestCase {

    // MARK: - 响应解析（夹具是实际调回来的 200 字节）

    /// 断言全部从抓到的字节推导：10 条 organic 全有 snippet、
    /// 第 1 条是 Berryxia.AI 的推文、`date`（8 条有）不进输出。
    func testSearchFixtureBecomesMarkdownForTheModel() throws {
        let data = try Fixture.data("serper-search", ext: "json")
        let text = try SerperAPI.searchText(from: data)

        XCTAssertTrue(text.hasPrefix("### 1. Berryxia.AI on X"),
                      "第 1 条标题，实际开头：\(text.prefix(60))")
        XCTAssertTrue(text.contains("认知鸿沟一次性说透"), "第 1 条抓到的 snippet 原文")
        XCTAssertTrue(text.contains("### 10. Karpathy：LLM 能力认知鸿沟正扩大为漏斗"),
                      "最后一条（第 10 条）")
        XCTAssertEqual(text.components(separatedBy: "### ").count - 1, 10, "10 条一条不能丢")
        XCTAssertFalse(text.contains("6 months ago"),
                       "`date` 字段格式杂乱（真值 '6 months ago'）不解析、不进输出")
    }

    /// 防御分支：200 带顶层 `error`（形状没抓过，合成钉）—— 报错绝不能当结果。
    func testTopLevelErrorUnderHTTP200ThrowsInsteadOfBecomingResults() {
        let data = Data(#"{"error":"quota exceeded","organic":[]}"#.utf8)
        XCTAssertThrowsError(try SerperAPI.searchText(from: data)) { error in
            let message = (error as? APIError)?.message ?? ""
            XCTAssertTrue(message.contains("Serper 报错"), "实际：\(message)")
            XCTAssertTrue(message.contains("quota exceeded"), "接口原话要带上")
        }
    }

    /// 一条都没有时，顶层 `message` 比「没有内容」更能说明原因（防御分支，合成钉）。
    func testEmptyOrganicWithMessageSurfacesTheMessage() {
        let data = Data(#"{"organic":[],"message":"insufficient credits"}"#.utf8)
        XCTAssertThrowsError(try SerperAPI.searchText(from: data)) { error in
            let message = (error as? APIError)?.message ?? ""
            XCTAssertTrue(message.contains("Serper 报错"), "实际：\(message)")
            XCTAssertTrue(message.contains("insufficient credits"))
        }
    }

    func testSearchWithNoResultsThrowsInsteadOfReturningEmptyString() {
        let data = Data(#"{"organic":[]}"#.utf8)
        XCTAssertThrowsError(try SerperAPI.searchText(from: data)) { error in
            XCTAssertTrue((error as? APIError)?.message.contains("没有返回可用内容") == true)
        }
    }

    func testGarbageThrows() {
        XCTAssertThrowsError(try SerperAPI.searchText(from: Data("not json".utf8)))
    }

    // MARK: - 错误状态码（夹具是假 Key 免费探针抓的真 403 字节；
    //         错误形状官方文档不可达，全靠这 44 字节）

    func testUnauthorizedFromCapturedErrorNamesKeyAndSettingsPath() throws {
        let data = try Fixture.data("serper-error", ext: "json")
        let error = SerperAPI.apiError(statusCode: 403, data: data)
        XCTAssertEqual(error.kind, .server(403))
        XCTAssertTrue(error.message.contains("Key 无效"), "实际：\(error.message)")
        XCTAssertTrue(error.message.contains("403"), "状态码要带上，实际：\(error.message)")
        XCTAssertTrue(error.message.contains("搜索工具"), "要给出能照做的路径，实际：\(error.message)")
        XCTAssertTrue(error.message.contains("接口原话"), "要把真错误带出来，实际：\(error.message)")
        XCTAssertTrue(error.message.contains("Unauthorized."), "夹具里的原话，实际：\(error.message)")
    }

    func testUnauthorizedIsTreatedTheSameAsForbidden() {
        let error = SerperAPI.apiError(statusCode: 401, data: Data())
        XCTAssertTrue(error.message.contains("Key 无效"))
    }

    func testRateLimitSaysTooManyRequests() {
        let error = SerperAPI.apiError(statusCode: 429, data: Data())
        XCTAssertTrue(error.message.contains("频繁"), "实际：\(error.message)")
        XCTAssertEqual(error.kind, .rateLimited(retryAfter: nil))
    }

    /// 其它状态码：顶层 `message` 恰好是 `problemMessage` 认得的形状。
    func testOtherStatusesCarryTheProblemMessage() {
        let body = Data(#"{"message":"invalid q parameter","statusCode":400}"#.utf8)
        let error = SerperAPI.apiError(statusCode: 400, data: body)
        XCTAssertEqual(error.kind, .server(400))
        XCTAssertTrue(error.message.contains("400"))
        XCTAssertTrue(error.message.contains("invalid q parameter"), "实际：\(error.message)")
    }

    // MARK: - 工具分发

    /// 请求体只有 `{"q": …}`（用户给的接入样例，保持最小）。
    func testWebSearchPassesQueryAsQOnly() async {
        let fake = FakeSerper()
        let runner = SerperToolRunner(apiKey: "serper-key", api: fake)
        let call = AIChatToolCall(
            index: 0, id: "c1", name: AIChatToolName.webSearch,
            argumentsJSON: #"{"query":"Karpathy 后续"}"#
        )

        let outcome = await runner.execute(call: call)
        XCTAssertFalse(outcome.isError)
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(fake.calls.first?.tool, "search")
        XCTAssertEqual(fake.calls.first?.arguments["q"] as? String, "Karpathy 后续")
        XCTAssertEqual(fake.calls.first?.arguments.count, 1, "体里只放 q，不做多余字段")
    }

    /// Serper 没有读网页能力：链不会路由过来，真到了照实回绝、零网络。
    func testReadURLIsRefusedWithoutAnyNetworkCall() async {
        let fake = FakeSerper()
        let runner = SerperToolRunner(apiKey: "k", api: fake)

        let outcome = await runner.execute(
            call: AIChatToolCall(index: 0, id: "c2", name: AIChatToolName.readURL,
                                 argumentsJSON: #"{"url":"https://example.com/a"}"#)
        )
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(outcome.text.contains("不支持读网页"), "实际：\(outcome.text)")
        XCTAssertTrue(fake.calls.isEmpty, "不支持的能力一次网络都不该发")
    }

    /// Serper 没有匿名模式：空 key 一个网络请求都不发。
    func testEmptyKeyNeverHitsTheNetwork() async {
        let fake = FakeSerper()
        let runner = SerperToolRunner(apiKey: "   ", api: fake)

        let outcome = await runner.execute(
            call: AIChatToolCall(index: 0, id: "c3", name: AIChatToolName.webSearch, argumentsJSON: #"{"query":"x"}"#)
        )
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(fake.calls.isEmpty, "没 key 就不该发网络")
        XCTAssertTrue(outcome.text.contains("Serper 的 Key"), "要给出能照做的提示，实际：\(outcome.text)")
        XCTAssertTrue(outcome.text.contains("搜索工具"), "顺带给出设置路径")
    }

    func testMissingArgumentIsReportedAsToolErrorNotACrash() async {
        let fake = FakeSerper()
        let runner = SerperToolRunner(apiKey: "k", api: fake)

        let outcome = await runner.execute(
            call: AIChatToolCall(index: 0, id: "c4", name: AIChatToolName.webSearch, argumentsJSON: "{}")
        )
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(fake.calls.isEmpty, "参数不全就不该去调服务")
    }

    func testUnknownToolIsRefused() async {
        let runner = SerperToolRunner(apiKey: "k", api: FakeSerper())
        let outcome = await runner.execute(
            call: AIChatToolCall(index: 0, id: "c5", name: "delete_everything", argumentsJSON: "{}")
        )
        XCTAssertTrue(outcome.isError, "模型偶尔会编一个不存在的工具名")
    }

    func testServiceFailureComesBackAsToolError() async {
        let fake = FakeSerper()
        fake.nextError = APIError(kind: .server(429), message: "Serper 请求过于频繁或额度用尽（429），稍等片刻再试")
        let runner = SerperToolRunner(apiKey: "k", api: fake)

        let outcome = await runner.execute(
            call: AIChatToolCall(index: 0, id: "c6", name: AIChatToolName.webSearch, argumentsJSON: #"{"query":"x"}"#)
        )
        XCTAssertTrue(outcome.isError, "工具失败要当成 is_error 回传，让模型自己换个说法，而不是整轮报错")
        XCTAssertTrue(outcome.text.contains("429"))
    }
}
