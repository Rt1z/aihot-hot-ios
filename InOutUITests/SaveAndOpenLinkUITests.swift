import XCTest

/// 快捷指令「收藏并打开」的消费路径：启动时带一条预置收藏 + 待打开 URL →
/// 切到收藏 → 自动 push 文章详情。
///
/// App Intent 本身在快捷指令里不好自动触发；这里用启动参数（仅 Xcode/模拟器
/// 能传）预置同样的状态，钉住 RootView + FavoritesListView 这一段的接线。
final class SaveAndOpenLinkUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testLaunchWithPendingLinkOpensTheArticle() {
        let app = XCUIApplication()
        let url = "https://example.com/uitest-open-\(UUID().uuidString.lowercased())"
        app.launchArguments = ["uitests-open-link=\(url)"]
        app.launch()

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15), "App 没能启动")
        XCTAssertTrue(
            app.tabBars.buttons.element(boundBy: 3).isSelected,
            "应该切到「收藏」tab"
        )
        XCTAssertTrue(
            app.navigationBars["文章"].waitForExistence(timeout: 10),
            "没有自动打开文章详情"
        )
        XCTAssertTrue(app.staticTexts["UITest Article"].waitForExistence(timeout: 5))
    }
}
