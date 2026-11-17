import XCTest

@testable import InOut

/// 外部链接的校验、规范化、URL Scheme 解析与标题提取。
final class SavedLinkTests: XCTestCase {

    // MARK: - 规范化

    func testNormalizesSchemeHostAndDropsFragment() {
        let url = SharedLinkURL.normalized("  HTTPS://MP.Weixin.QQ.COM/s/abc?x=1#part  ")
        XCTAssertEqual(url?.absoluteString, "https://mp.weixin.qq.com/s/abc?x=1")
    }

    func testAcceptsHttpAndHttps() {
        XCTAssertNotNil(SharedLinkURL.normalized("https://example.com/a"))
        XCTAssertNotNil(SharedLinkURL.normalized("http://example.com/a"))
    }

    func testRejectsNonWebSchemes() {
        XCTAssertNil(SharedLinkURL.normalized("javascript:alert(1)"))
        XCTAssertNil(SharedLinkURL.normalized("file:///etc/passwd"))
        XCTAssertNil(SharedLinkURL.normalized("ftp://example.com/a"))
        XCTAssertNil(SharedLinkURL.normalized("aihot://add?url=https%3A%2F%2Fexample.com"))
    }

    func testRejectsPrivateAndLocalHosts() {
        let rejected = [
            "http://localhost/a",
            "http://foo.local/a",
            "http://127.0.0.1/a",
            "http://10.0.0.1/a",
            "http://192.168.1.1/a",
            "http://172.20.0.1/a",
            "http://169.254.1.1/a",
            "http://100.64.0.1/a",
            "http://[::1]/a",
            "http://[fe80::1]/a",
            "http://intranet/a",
        ]
        for raw in rejected {
            XCTAssertNil(SharedLinkURL.normalized(raw), "应该拒绝：\(raw)")
        }
    }

    func testRejectsUserInfoAndEmptyOrHugeLinks() {
        XCTAssertNil(SharedLinkURL.normalized("https://user:pass@example.com/a"))
        XCTAssertNil(SharedLinkURL.normalized("   "))
        XCTAssertNil(SharedLinkURL.normalized("https://example.com/" + String(repeating: "a", count: 3000)))
    }

    // MARK: - 从文字里找链接

    func testFirstURLFindsLinkInsideCopiedText() {
        let text = "标题：Qwen4-Max 发布\n链接：https://mp.weixin.qq.com/s/abc？详情见原文。"
        XCTAssertEqual(
            SharedLinkURL.firstURL(in: text),
            "https://mp.weixin.qq.com/s/abc"
        )
    }

    func testFirstURLTrimsTrailingPunctuation() {
        XCTAssertEqual(
            SharedLinkURL.firstURL(in: "看这个 https://example.com/a)."),
            "https://example.com/a"
        )
    }

    func testFirstURLRejectsPrivateLinks() {
        XCTAssertNil(SharedLinkURL.firstURL(in: "http://192.168.1.1/admin"))
    }

    // MARK: - 标题兜底

    func testDefaultTitleDistinguishesWeChatFromOrdinaryLinks() {
        XCTAssertTrue(SharedLinkURL.isWeChatHost("mp.weixin.qq.com"))
        XCTAssertTrue(SharedLinkURL.isWeChatHost("weixin.qq.com"))
        XCTAssertFalse(SharedLinkURL.isWeChatHost("example.com"))

        XCTAssertEqual(
            SharedLinkURL.defaultTitle(for: "https://mp.weixin.qq.com/s/abc"),
            "微信公众号文章"
        )
        XCTAssertEqual(
            SharedLinkURL.defaultTitle(for: "https://example.com/a"),
            "example.com"
        )
    }

    /// 公众号文章不再把域名挂在「公众号文章」后面；普通链接仍然保留域名。
    func testSourceLineOmitsTheDomainForWeChat() {
        XCTAssertEqual(
            SavedLink(url: "https://mp.weixin.qq.com/s/abc", title: "标题").sourceLine,
            "公众号文章"
        )
        XCTAssertEqual(
            SavedLink(url: "https://example.com/a", title: "标题").sourceLine,
            "链接 · example.com"
        )
    }

    func testSavedLinkUsesDefaultTitleWhenEmpty() {
        let wechat = SavedLink(url: "https://mp.weixin.qq.com/s/abc", title: "   ")
        XCTAssertEqual(wechat.title, "微信公众号文章")
        XCTAssertTrue(wechat.isWeChatArticle)

        let normal = SavedLink(url: "https://example.com/a", title: "文章标题")
        XCTAssertEqual(normal.title, "文章标题")
        XCTAssertEqual(normal.host, "example.com")
        XCTAssertEqual(normal.sourceLabel, "链接")
    }

    // MARK: - URL Scheme

    func testIncomingURLParsesURLAndTitle() throws {
        let incoming = try XCTUnwrap(
            URL(string: "aihot://add?url=https%3A%2F%2Fmp.weixin.qq.com%2Fs%2Fabc%3Fx%3D1&title=%E4%B8%80%E4%B8%AA%E6%A0%87%E9%A2%98")
        )
        let input = try XCTUnwrap(SharedLinkInput.parse(incoming))
        XCTAssertEqual(input.url.absoluteString, "https://mp.weixin.qq.com/s/abc?x=1")
        XCTAssertEqual(input.title, "一个标题")
    }

    func testIncomingURLWithoutTitleIsAllowed() throws {
        let incoming = try XCTUnwrap(URL(string: "aihot://add?url=https%3A%2F%2Fexample.com%2Fa"))
        XCTAssertNil(try XCTUnwrap(SharedLinkInput.parse(incoming)).title)
    }

    func testIncomingURLRejectsWrongRouteOrBadInnerURL() throws {
        XCTAssertNil(SharedLinkInput.parse(try XCTUnwrap(URL(string: "other://add?url=https%3A%2F%2Fexample.com"))))
        XCTAssertNil(SharedLinkInput.parse(try XCTUnwrap(URL(string: "aihot://open?url=https%3A%2F%2Fexample.com"))))
        XCTAssertNil(SharedLinkInput.parse(try XCTUnwrap(URL(string: "aihot://add?title=only"))))
        XCTAssertNil(SharedLinkInput.parse(try XCTUnwrap(URL(string: "aihot://add?url=http%3A%2F%2Flocalhost%2Fa"))))
    }

    // MARK: - 标题解析

    func testTitlePrefersOgTitleAndDecodesEntities() throws {
        let html = try Fixture.text("link-title", ext: "html")
        XCTAssertEqual(LinkTitleParser.parse(html: html), "Qwen4-Max 发布 & 价格揭晓")
    }

    func testTitleFallsBackToTitleTag() {
        let html = "<html><head><title>\n  普通标题 &amp; 后缀 \n</title></head></html>"
        XCTAssertEqual(LinkTitleParser.parse(html: html), "普通标题 & 后缀")
    }

    func testTitlePrefersPropertyBeforeContentOrder() {
        let html = #"<meta property="og:title" content="第一种顺序"><title>不该选中</title>"#
        XCTAssertEqual(LinkTitleParser.parse(html: html), "第一种顺序")
    }

    func testTitleReturnsNilWhenMissingOrEmpty() {
        XCTAssertNil(LinkTitleParser.parse(html: "<html><head></head><body>没有标题</body></html>"))
        XCTAssertNil(LinkTitleParser.parse(html: "<title>   </title>"))
    }

    /// 公众号页面的 `<title>` 常常是「微信公众平台」，真正的标题在 msg_title 里。
    func testTitleFallsBackToWeChatMessageTitle() {
        let html = """
        <html><head><title>微信公众平台</title></head>
        <body><script>var msg_title = '公众号真标题';</script></body></html>
        """
        XCTAssertEqual(LinkTitleParser.parse(html: html), "公众号真标题")
    }

    func testGenericTitlesAreRecognized() {
        XCTAssertTrue(LinkTitleParser.isGenericTitle("微信公众平台"))
        XCTAssertTrue(LinkTitleParser.isGenericTitle("请在微信客户端打开链接"))
        XCTAssertFalse(LinkTitleParser.isGenericTitle("Qwen4-Max 发布"))
    }

    func testTitleIsCapped() {
        let long = String(repeating: "标", count: 300)
        let parsed = LinkTitleParser.parse(html: "<title>\(long)</title>")
        XCTAssertEqual(parsed?.count, SharedLinkURL.maximumTitleLength)
    }

    // MARK: - 导入（RootView 的 onOpenURL 走这一层）

    @MainActor
    func testImporterAddsOnceAndReportsDuplicates() throws {
        let name = "aihot.tests.links.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let store = FavoritesStore(defaults: defaults)
        let incoming = try XCTUnwrap(
            URL(string: "aihot://add?url=https%3A%2F%2Fexample.com%2Fa&title=%E6%A0%87%E9%A2%98")
        )

        let first = try XCTUnwrap(SavedLinkImporter.importLink(from: incoming, into: store))
        XCTAssertTrue(first.added)
        XCTAssertEqual(first.title, "标题")
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.link?.title, "标题")

        let second = try XCTUnwrap(SavedLinkImporter.importLink(from: incoming, into: store))
        XCTAssertFalse(second.added, "重复导入不该再加一条")
        XCTAssertEqual(store.items.count, 1)

        let invalid = try XCTUnwrap(URL(string: "other://add?url=https%3A%2F%2Fexample.com"))
        XCTAssertNil(SavedLinkImporter.importLink(from: invalid, into: store))
    }
}
