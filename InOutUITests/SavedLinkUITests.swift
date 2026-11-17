import XCTest

/// 外部链接的三条端到端：
/// 1. 手动添加 → 收藏列表出现；
/// 2. 输入 URL 后自动抓标题（需要网络，抓不到时 XCTSkip）；
/// 3. 打开导入文章 → 正文加载 → AI 对话与「练一练」可用（需要网络）。
///
/// 都不经过剪贴板（那会触发系统粘贴授权弹窗）。
final class SavedLinkUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - 帮助

    private func launchToFavorites() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15), "App 没能启动")
        // 收藏 tab：热点 | 周报 | 模型榜 | 收藏 | 设置 —— 第 4 个（下标 3）
        app.tabBars.buttons.element(boundBy: 3).tap()
        return app
    }

    private func openAddSheetAndType(_ app: XCUIApplication, url: String) {
        let addButton = app.buttons["favorites-add-link"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10), "收藏页没有「添加链接」入口")
        addButton.tap()

        let urlField = app.descendants(matching: .any)["add-link-url"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 5), "添加链接表单没有出现")
        urlField.tap()
        urlField.typeText(url)
        // 键盘占了下半屏；往上滑一下，让下面的标题字段进入 AX 树
        app.swipeUp()
    }

    private func addLink(_ app: XCUIApplication, url: String) {
        openAddSheetAndType(app, url: url)

        let save = app.buttons["add-link-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: save)
        waitForExpectations(timeout: 5)
        save.tap()
    }

    private func uniqueURL(_ prefix: String) -> String {
        "https://example.com/\(prefix)-\(UUID().uuidString.lowercased())"
    }

    // MARK: - 用例

    func testAddingLinkManuallyShowsItInFavorites() {
        let app = launchToFavorites()
        addLink(app, url: uniqueURL("manual"))

        XCTAssertTrue(
            app.buttons["saved-link-row"].firstMatch.waitForExistence(timeout: 5),
            "收藏列表里没有刚添加的链接"
        )
    }

    func testTitleIsFetchedAutomatically() throws {
        let app = launchToFavorites()
        // 只打开表单并输入，不保存 —— 要观察的是标题字段被自动填上
        openAddSheetAndType(app, url: uniqueURL("title"))

        let titleField = app.descendants(matching: .any)["add-link-title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if (titleField.value as? String) == "Example Domain" {
                return
            }
            if app.staticTexts["没取到标题，可以自己填，或直接用域名。"].exists {
                throw XCTSkip("网络不可用或站点拒绝，跳过标题抓取断言")
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("20 秒内没有自动获取到标题")
    }

    func testImportedArticleSupportsChatAndPractice() throws {
        let app = launchToFavorites()
        addLink(app, url: uniqueURL("reader"))

        let row = app.buttons["saved-link-row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "收藏里没有刚添加的链接")
        row.tap()

        XCTAssertTrue(app.navigationBars["文章"].waitForExistence(timeout: 10), "没有进入文章阅读页")

        let practice = app.buttons["练一练"]
        XCTAssertTrue(practice.waitForExistence(timeout: 5), "文章页没有练一练入口")

        // 正文取到之后练一练才可点
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline && !practice.isEnabled {
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard practice.isEnabled else {
            throw XCTSkip("文章正文没有加载出来（需要网络）")
        }

        app.buttons["AI 对话"].tap()
        XCTAssertTrue(
            app.staticTexts["就这篇文章问点什么"].waitForExistence(timeout: 5),
            "导入文章的 AI 对话没有打开"
        )
        app.buttons["关闭"].tap()

        practice.tap()
        XCTAssertTrue(app.navigationBars["练一练"].waitForExistence(timeout: 5), "导入文章的练一练没有打开")
        app.buttons["取消"].tap()
    }
}
