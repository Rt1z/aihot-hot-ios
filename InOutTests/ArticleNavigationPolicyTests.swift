import XCTest

@testable import InOut

/// 导入文章阅读器的导航策略：http(s) 留在页面里；自定义协议只有用户主动点
/// 链接才交给系统。回归钉是小红书那种「一打开就自动跳 App」的页面。
final class ArticleNavigationPolicyTests: XCTestCase {

    func testInPageSchemesStayInsideReader() {
        for scheme in ["http", "https", "about", "data", "blob"] {
            XCTAssertEqual(
                ArticleNavigationPolicy.decision(scheme: scheme, isLinkActivated: false),
                .allow,
                scheme
            )
            XCTAssertEqual(
                ArticleNavigationPolicy.decision(scheme: scheme, isLinkActivated: true),
                .allow,
                scheme
            )
        }
    }

    /// 小红书页面载入后会用 JS 往 `xhsdiscover://` 跳；这不是用户动作，
    /// 必须静默取消，否则会弹「在『小红书』中打开？」。
    func testXiaohongshuAutoRedirectIsCancelledSilently() {
        XCTAssertEqual(
            ArticleNavigationPolicy.decision(scheme: "xhsdiscover", isLinkActivated: false),
            .cancel
        )
    }

    func testCustomSchemeTappedByUserOpensExternally() {
        XCTAssertEqual(
            ArticleNavigationPolicy.decision(scheme: "xhsdiscover", isLinkActivated: true),
            .openExternally
        )
        XCTAssertEqual(
            ArticleNavigationPolicy.decision(scheme: "weixin", isLinkActivated: true),
            .openExternally
        )
    }

    func testSchemeComparisonIsCaseInsensitive() {
        XCTAssertEqual(
            ArticleNavigationPolicy.decision(scheme: "HTTPS", isLinkActivated: false),
            .allow
        )
        XCTAssertEqual(
            ArticleNavigationPolicy.decision(scheme: "XHSDiscover", isLinkActivated: false),
            .cancel
        )
    }

    func testMissingSchemeIsAllowed() {
        XCTAssertTrue(ArticleNavigationPolicy.isInPage(scheme: nil))
        XCTAssertEqual(
            ArticleNavigationPolicy.decision(scheme: nil, isLinkActivated: false),
            .allow
        )
    }
}
