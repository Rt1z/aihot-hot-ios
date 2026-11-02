import XCTest

@testable import AIHOT

/// 订阅两条网络线路里**不发请求**的那部分：URL 拼接、错误翻译、错误优先级。
final class SubscriptionClientTests: XCTestCase {

    private func bilibiliSource(route: String = "/bilibili/user/video/946974") -> SubscriptionSource {
        SubscriptionSource(
            id: "bilibili:" + route,
            kind: .bilibili,
            name: "UP",
            request: .bilibili(route: route),
            isEnabled: true
        )
    }

    func testRSSHubURLJoinsBaseAndRoute() throws {
        let url = try RSSHubAPI.requestURL(
            baseURLRaw: "http://MacBook.local:1200/",
            source: bilibiliSource()
        )
        XCTAssertEqual(url.absoluteString, "http://MacBook.local:1200/bilibili/user/video/946974")
    }

    func testRSSHubURLKeepsQuery() throws {
        let url = try RSSHubAPI.requestURL(
            baseURLRaw: "http://MacBook.local:1200",
            source: bilibiliSource(route: "/bilibili/user/video/946974?limit=10")
        )
        XCTAssertEqual(
            url.absoluteString,
            "http://MacBook.local:1200/bilibili/user/video/946974?limit=10"
        )
    }

    func testRSSHubRejectsBadBaseAndBadRoute() {
        XCTAssertThrowsError(
            try RSSHubAPI.requestURL(baseURLRaw: "not a url", source: bilibiliSource())
        )
        XCTAssertThrowsError(
            try RSSHubAPI.requestURL(
                baseURLRaw: "http://MacBook.local:1200",
                source: bilibiliSource(route: "https://evil.example.com/bilibili/x")
            )
        )
    }

    func testRSSHubRejectsANonBilibiliSource() {
        let wechat = SubscriptionSource(
            id: "wechat:x",
            kind: .wechat,
            name: "",
            request: .wechat(url: "https://mp.weixin.qq.com/s/x", biz: "x"),
            isEnabled: true
        )
        XCTAssertThrowsError(
            try RSSHubAPI.requestURL(baseURLRaw: "http://MacBook.local:1200", source: wechat)
        )
    }

    /// -1009 与 -1022 是两件不同的事，文案不能只说「网络不可用」。
    func testURLErrorMappingDistinguishesLocalNetworkFromATS() {
        let local = SubscriptionHTTP.mapURLError(
            URLError(.notConnectedToInternet),
            localHint: true
        )
        XCTAssertEqual(local.kind, .offline)
        XCTAssertTrue(local.message.contains("本地网络"))

        let internet = SubscriptionHTTP.mapURLError(
            URLError(.notConnectedToInternet),
            localHint: false
        )
        XCTAssertTrue(internet.message.contains("网络不可用"))

        let ats = SubscriptionHTTP.mapURLError(
            URLError(.appTransportSecurityRequiresSecureConnection),
            localHint: true
        )
        XCTAssertEqual(ats.kind, .invalidConfig)
        XCTAssertTrue(ats.message.contains("明文 HTTP"))
    }

    func testErrorPriorityPutsActionableErrorsFirst() {
        let badKey = SubscriptionError(kind: .badKey, message: "")
        let balance = SubscriptionError(kind: .insufficientBalance, message: "")
        let rate = SubscriptionError(kind: .rateLimited, message: "")
        let offline = SubscriptionError(kind: .offline, message: "")
        let server = SubscriptionError(kind: .server, message: "")
        XCTAssertGreaterThan(badKey.priority, balance.priority)
        XCTAssertGreaterThan(balance.priority, rate.priority)
        XCTAssertGreaterThan(rate.priority, offline.priority)
        XCTAssertGreaterThan(offline.priority, server.priority)
    }

    func testBadKeyAndBalanceUseFailedNoticeKind() {
        XCTAssertEqual(SubscriptionError(kind: .badKey, message: "").noticeKind, .failed)
        XCTAssertEqual(SubscriptionError(kind: .insufficientBalance, message: "").noticeKind, .failed)
        XCTAssertEqual(SubscriptionError(kind: .offline, message: "").noticeKind, .offline)
        XCTAssertEqual(SubscriptionError(kind: .rateLimited, message: "").noticeKind, .rateLimited)
    }
}
