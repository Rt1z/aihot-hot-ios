import XCTest

@testable import AIHOT

/// `rsshub-bilibili-video.xml` 是按 RSSHub B 站路由的结构写的合成夹具（不是抓包），
/// 覆盖 CDATA、`media:thumbnail`、`//` 封面、`+0800` 日期与缺字段。
/// 真实抓包回来后替换它即可，断言口径不变。
final class RSSFeedParserTests: XCTestCase {

    private func source(name: String = "") -> SubscriptionSource {
        SubscriptionSource(
            id: "bilibili:/bilibili/user/video/946974",
            kind: .bilibili,
            name: name,
            request: .bilibili(route: "/bilibili/user/video/946974"),
            isEnabled: true
        )
    }

    private func parse(_ name: String = "") throws -> ParsedFeed {
        let data = try Fixture.data("rsshub-bilibili-video", ext: "xml")
        return try RSSFeedParser.parse(data: data, source: source(name: name))
    }

    func testParsesChannelAndItems() throws {
        let feed = try parse()
        XCTAssertEqual(feed.sourceName, "影视飓风", "配置没填名字时用 channel title")
        XCTAssertEqual(feed.items.count, 3)

        let first = feed.items[0]
        XCTAssertEqual(first.title, "我们花了一百万，拍了一支短片")
        XCTAssertEqual(first.link, "https://www.bilibili.com/video/BV1abc")
        XCTAssertEqual(first.summary, "这支短片的幕后故事。")
        XCTAssertEqual(first.coverURL, "https://i0.hdslb.com/bfs/archive/cover1.jpg", "// 开头要补 https:")
        XCTAssertEqual(first.sourceName, "影视飓风")
        XCTAssertEqual(first.publishedAt, SubscriptionDate.parseRSS("Mon, 20 Oct 2026 10:00:00 GMT"))
    }

    func testSecondItemUsesMediaThumbnailAndDecodesEntity() throws {
        let feed = try parse()
        let second = feed.items[1]
        XCTAssertEqual(second.title, "AI 与影像 & 未来")
        XCTAssertEqual(second.coverURL, "https://i0.hdslb.com/bfs/archive/cover2.jpg")
        XCTAssertEqual(second.publishedAt, SubscriptionDate.parseRSS("Tue, 21 Oct 2026 18:30:00 +0800"))
    }

    func testMissingFieldsDoNotCrashAndInvalidDateBecomesNil() throws {
        let feed = try parse()
        let third = feed.items[2]
        XCTAssertEqual(third.title, "没有封面的第三期")
        XCTAssertNil(third.publishedAt)
        XCTAssertEqual(third.summary, "")
        XCTAssertNil(third.coverURL)
        XCTAssertFalse(third.id.isEmpty)
    }

    func testConfiguredNameWins() throws {
        let feed = try parse("我的 UP 主")
        XCTAssertEqual(feed.sourceName, "我的 UP 主")
        XCTAssertEqual(Set(feed.items.map(\.sourceName)), ["我的 UP 主"])
    }

    func testZeroItemRSSIsValid() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel><title>空频道</title></channel></rss>
        """
        let feed = try RSSFeedParser.parse(data: Data(xml.utf8), source: source())
        XCTAssertEqual(feed.items.count, 0)
        XCTAssertEqual(feed.sourceName, "空频道")
    }

    func testHTMLErrorPageIsRejected() throws {
        let html = "<!doctype html><html><body>not found</body></html>"
        XCTAssertThrowsError(try RSSFeedParser.parse(data: Data(html.utf8), source: source())) { error in
            XCTAssertEqual((error as? SubscriptionError)?.kind, .invalidFeed)
        }
    }

    func testAtomIsRejectedWithAClearMessage() {
        let atom = "<?xml version=\"1.0\"?><feed xmlns=\"http://www.w3.org/2005/Atom\"></feed>"
        XCTAssertThrowsError(try RSSFeedParser.parse(data: Data(atom.utf8), source: source())) { error in
            XCTAssertTrue((error as? SubscriptionError)?.message.contains("Atom") == true)
        }
    }

    func testBrokenXMLIsRejected() {
        let broken = "<?xml version=\"1.0\"?><rss><channel><title>x</title>"
        XCTAssertThrowsError(try RSSFeedParser.parse(data: Data(broken.utf8), source: source()))
    }

    /// 带子元素的 description（没有 CDATA 的写法）不应把父元素文字清空。
    func testDescriptionWithCDATAKeepsHTML() {
        XCTAssertEqual(
            SubscriptionHTML.summary(from: "<p>你好</p><img src=\"https://x/y.jpg\">世界"),
            "你好 世界"
        )
        XCTAssertEqual(
            SubscriptionHTML.coverURL(from: "<img src=\"//x/y.jpg\">", baseURL: nil),
            "https://x/y.jpg"
        )
        XCTAssertNil(SubscriptionHTML.coverURL(from: "<img src=\"data:image/png;base64,xx\">", baseURL: nil))
    }
}
