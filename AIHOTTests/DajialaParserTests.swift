import XCTest

@testable import AIHOT

/// 注意：`dajiala-post-history.json` 与三个 error 夹具目前是**按公开资料猜的**，
/// 不是抓包。真实响应回来后应替换夹具并收紧 `DajialaParser` 的字段别名表
/// （规则 13：手写 payload 会把 bug 钉成绿色）。
final class DajialaParserTests: XCTestCase {

    private func source(name: String = "") -> SubscriptionSource {
        SubscriptionSource(
            id: "wechat:test",
            kind: .wechat,
            name: name,
            request: .wechat(url: "https://mp.weixin.qq.com/s/x", biz: "BIZ"),
            isEnabled: true
        )
    }

    func testParsesCapturedShapeGuess() throws {
        let data = try Fixture.data("dajiala-post-history", ext: "json")
        let items = try DajialaParser.parse(data: data, source: source())

        XCTAssertEqual(items.count, 2, "缺链接的第三条要跳过")
        XCTAssertEqual(items[0].title, "AI 产品经理的下一步")
        XCTAssertEqual(items[0].sourceName, "某产品号", "配置没填名字时用接口返回的 wx_name")
        XCTAssertEqual(items[0].summary, "关于 AI 产品与职业发展。")
        XCTAssertEqual(items[0].publishedAt, SubscriptionDate.parseWeChat("2026-10-20 09:30:00"))
        XCTAssertEqual(items[1].summary, "睡眠不足会影响免疫力。", "摘要里的 HTML 要去掉")
        XCTAssertEqual(items[0].kind, .wechat)
    }

    func testConfiguredNameWinsOverResponseName() throws {
        let data = try Fixture.data("dajiala-post-history", ext: "json")
        let items = try DajialaParser.parse(data: data, source: source(name: "我的名字"))
        XCTAssertEqual(Set(items.map(\.sourceName)), ["我的名字"])
    }

    func testQPSLimit() throws {
        let data = try Fixture.data("dajiala-error-qps", ext: "json")
        let error = try errorThrown { _ = try DajialaParser.parse(data: data, source: source()) }
        XCTAssertEqual(error.kind, .rateLimited)
        XCTAssertEqual(error.retryAfter, 1)
    }

    func testBadKey() throws {
        let data = try Fixture.data("dajiala-error-10002", ext: "json")
        let error = try errorThrown { _ = try DajialaParser.parse(data: data, source: source()) }
        XCTAssertEqual(error.kind, .badKey)
        XCTAssertTrue(error.message.contains("Key 无效"))
    }

    func testInsufficientBalance() throws {
        let data = try Fixture.data("dajiala-error-balance", ext: "json")
        let error = try errorThrown { _ = try DajialaParser.parse(data: data, source: source()) }
        XCTAssertEqual(error.kind, .insufficientBalance)
    }

    /// HTTP 200 但结构认不出时不能静默成功，必须点名顶层字段。
    func testUnknownShapeThrowsWithTopLevelKeys() throws {
        let data = try Fixture.data("dajiala-unknown-shape", ext: "json")
        let error = try errorThrown { _ = try DajialaParser.parse(data: data, source: source()) }
        XCTAssertEqual(error.kind, .decoding)
        XCTAssertTrue(error.message.contains("payload"), "要把顶层字段名带出来")
    }

    func testNonJSONThrows() {
        XCTAssertThrowsError(try DajialaParser.parse(data: Data("<html>".utf8), source: source()))
    }

    /// 请求体：page 永远是 1；Key 只在 body 里，不在 URL 里。
    func testRequestBodyIsPageOneAndKeepsTheKeyOutOfTheURL() throws {
        let data = try DajialaAPI.makeBody(source: source(name: "某号"), apiKey: "SECRET-KEY")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual((body["page"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(body["key"] as? String, "SECRET-KEY")
        XCTAssertEqual(body["biz"] as? String, "BIZ")
        XCTAssertEqual(body["name"] as? String, "某号")
        XCTAssertEqual(body["verifycode"] as? String, "")
        XCTAssertNil(DajialaAPI.endpoint.query, "Key 不能出现在 URL 查询串里")
    }

    /// 服务端的错误文案若回显了请求体，Key 不能顺着界面/诊断漏出去。
    func testServerEchoedKeyIsRedacted() {
        let error = SubscriptionError(kind: .server, message: "invalid key SECRET-KEY for request")
        let sanitized = DajialaAPI.sanitized(error, key: "SECRET-KEY")
        XCTAssertFalse(sanitized.message.contains("SECRET-KEY"))
        XCTAssertTrue(sanitized.message.contains("***"))

        let clean = SubscriptionError(kind: .server, message: "服务返回 500")
        XCTAssertEqual(DajialaAPI.sanitized(clean, key: "SECRET-KEY"), clean)
    }

    func testBodyBuilderRejectsABilibiliSource() {
        let bili = SubscriptionSource(
            id: "bilibili:test",
            kind: .bilibili,
            name: "UP",
            request: .bilibili(route: "/bilibili/user/video/1"),
            isEnabled: true
        )
        XCTAssertThrowsError(try DajialaAPI.makeBody(source: bili, apiKey: "k"))
    }

    private func errorThrown(_ body: () throws -> Void) throws -> SubscriptionError {
        do {
            try body()
            XCTFail("应该抛错")
            throw SubscriptionError(kind: .server, message: "no error")
        } catch let error as SubscriptionError {
            return error
        }
    }
}
