import XCTest

@testable import AIHOT

/// 配置文件逐条 salvage 的规格。镜像 22 读同一份夹具。
final class SubscriptionConfigTests: XCTestCase {

    private func parsedFixture() throws -> ParsedSubscriptionConfig {
        let data = try Fixture.data("subscription-config", ext: "json")
        return try SubscriptionConfigParser.parse(data: data)
    }

    func testFixtureSalvagesValidEntriesAndSkipsBadOnes() throws {
        let parsed = try parsedFixture()
        let config = parsed.config

        XCTAssertEqual(config.wechat.count, 3, "坏条目、重复、非对象、非 http 链接都要跳过")
        XCTAssertEqual(config.bilibili.count, 3, "坏路由、越界路由、重复都要跳过")

        let ids = Set(config.allSources.map(\.id))
        XCTAssertEqual(
            ids,
            [
                "wechat:MzkxMjUwNzA4NQ==",
                "wechat:MzkxOther==",
                "wechat:https://mp.weixin.qq.com/s/ghi",
                "bilibili:/bilibili/user/video/946974",
                "bilibili:/bilibili/user/video/123456?limit=10",
                "bilibili:/bilibili/user/video/999"
            ]
        )
        XCTAssertFalse(parsed.warnings.isEmpty)
        XCTAssertTrue(parsed.warnings.contains { $0.contains("配置版本") })
        XCTAssertTrue(parsed.warnings.contains { $0.contains("重复") })
        XCTAssertTrue(parsed.warnings.contains { $0.contains("route 不合法") })
    }

    func testDisabledEntriesAreKeptButExcludedFromEnabledSources() throws {
        let parsed = try parsedFixture()
        let disabledWeChat = parsed.config.wechat.first { $0.id == "wechat:MzkxOther==" }
        let disabledBili = parsed.config.bilibili.first { $0.id == "bilibili:/bilibili/user/video/999" }

        XCTAssertFalse(disabledWeChat?.isEnabled ?? true)
        XCTAssertFalse(disabledBili?.isEnabled ?? true)
        XCTAssertEqual(parsed.config.enabledSources.count, 4)
    }

    func testWeChatBizIsPreferredOverTheSampleURL() throws {
        let parsed = try parsedFixture()
        guard case let .wechat(url, biz) = parsed.config.wechat[0].request else {
            return XCTFail("第一条不是公众号")
        }
        XCTAssertEqual(biz, "MzkxMjUwNzA4NQ==", "从 __biz 查询参数里取，百分号编码要解码")
        XCTAssertNotNil(url)
    }

    func testBilibiliUIDBecomesTheStandardRoute() throws {
        let parsed = try parsedFixture()
        let up1 = parsed.config.bilibili.first { $0.name == "UP 1" }
        guard case let .bilibili(route) = up1?.request else {
            return XCTFail("UP 1 丢了")
        }
        XCTAssertEqual(route, "/bilibili/user/video/946974")
    }

    func testExtractsBizFromWeChatArticleURL() {
        XCTAssertEqual(
            SubscriptionConfigParser.extractWeChatBiz(
                from: "https://mp.weixin.qq.com/s/x?__biz=MzkxMjUwNzA4NQ%3D%3D&mid=1"
            ),
            "MzkxMjUwNzA4NQ=="
        )
        XCTAssertEqual(
            SubscriptionConfigParser.extractWeChatBiz(from: "https://mp.weixin.qq.com/s/x"),
            nil
        )
        XCTAssertEqual(
            SubscriptionConfigParser.extractWeChatBiz(from: "https://example.com/s?__biz=abc"),
            nil,
            "只认 mp.weixin.qq.com"
        )
    }

    /// 路由是 SSRF 边界：只能指向 RSSHub 站内的 /bilibili/。
    func testBilibiliRouteValidation() {
        XCTAssertEqual(
            SubscriptionConfigParser.normalizedBilibiliRoute("/bilibili/user/video/1?limit=10"),
            "/bilibili/user/video/1?limit=10"
        )
        XCTAssertNil(SubscriptionConfigParser.normalizedBilibiliRoute("https://evil.example.com/bilibili/user/video/1"))
        XCTAssertNil(SubscriptionConfigParser.normalizedBilibiliRoute("/bilibili/../../etc/passwd"))
        XCTAssertNil(SubscriptionConfigParser.normalizedBilibiliRoute("//evil.example.com/bilibili/x"))
        XCTAssertNil(SubscriptionConfigParser.normalizedBilibiliRoute("/other/user/video/1"))
        XCTAssertNil(SubscriptionConfigParser.normalizedBilibiliRoute("/bilibili/x#fragment"))
    }

    func testEmptyConfigIsValid() throws {
        let parsed = try SubscriptionConfigParser.parse(data: Data("{}".utf8))
        XCTAssertTrue(parsed.config.isEmpty)
        XCTAssertTrue(parsed.warnings.isEmpty)
    }

    func testMissingSectionsAreTolerated() throws {
        let parsed = try SubscriptionConfigParser.parse(
            data: Data(#"{"wechat":[],"bilibili":null}"#.utf8)
        )
        XCTAssertTrue(parsed.config.isEmpty)
    }

    /// 一个栏目写坏（不是数组）不能把另一个栏目一起丢掉。
    func testMalformedSectionDoesNotDropTheOtherSection() throws {
        let json = #"{"wechat":"oops","bilibili":[{"name":"UP","uid":"1"}]}"#
        let parsed = try SubscriptionConfigParser.parse(data: Data(json.utf8))
        XCTAssertEqual(parsed.config.bilibili.count, 1)
        XCTAssertTrue(parsed.warnings.contains { $0.contains("wechat 不是数组") })
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try SubscriptionConfigParser.parse(data: Data("not json".utf8)))
        XCTAssertThrowsError(try SubscriptionConfigParser.parse(data: Data("[]".utf8)))
    }

    func testDuplicateIdentityKeepsTheFirstNameButTheSameID() throws {
        let json = """
        {
          "wechat": [
            {"name": "旧名字", "biz": "BIZ1"},
            {"name": "新名字", "biz": "BIZ1"}
          ]
        }
        """
        let parsed = try SubscriptionConfigParser.parse(data: Data(json.utf8))
        XCTAssertEqual(parsed.config.wechat.count, 1)
        XCTAssertEqual(parsed.config.wechat.first?.name, "旧名字")
        XCTAssertEqual(parsed.config.wechat.first?.id, "wechat:BIZ1")
    }

    func testSourceCountIsCapped() throws {
        let entries = (0..<60).map { #"{"name":"UP \#($0)","uid":"\#($0)"}"# }.joined(separator: ",")
        let json = #"{"bilibili":[\#(entries)]}"#
        let parsed = try SubscriptionConfigParser.parse(data: Data(json.utf8))
        XCTAssertEqual(parsed.config.bilibili.count, SubscriptionConfigParser.maximumSources)
        XCTAssertTrue(parsed.warnings.contains { $0.contains("超过") })
    }
}
