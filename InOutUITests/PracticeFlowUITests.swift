import XCTest

/// 练习本的端到端一条：从热点详情「练一练」写到保存，再从收藏 tab 的入口
/// 看到这条记录。
///
/// 这条用例钉的是单测与镜像都看不到的接线：两个详情页的工具栏按钮、
/// sheet 的保存→对照切换、收藏页入口的导航。写作内容用 ASCII，
/// 避免依赖模拟器的中文输入法。
///
/// **需要网络**（热点榜是线上数据）。拉不到榜时 `XCTSkip`，不让离线环境
/// 变成一条假红 —— 真正的网络故障由其它层报。
final class PracticeFlowUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testPracticeFromHotDetailSavesAndAppearsInPracticeBook() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15), "App 没能启动")
        app.tabBars.buttons.element(boundBy: 0).tap()

        let first = app.buttons["hot-item-1"]
        guard first.waitForExistence(timeout: 20) else {
            throw XCTSkip("热点榜没有加载出来（需要网络）；这条用例只验证练习流程")
        }
        first.tap()

        let practiceButton = app.buttons["练一练"]
        XCTAssertTrue(practiceButton.waitForExistence(timeout: 10), "详情页没有「练一练」入口")
        practiceButton.tap()

        let mainIdea = app.descendants(matching: .any)["practice-main-idea"]
        XCTAssertTrue(mainIdea.waitForExistence(timeout: 10), "写作面板没有出现")
        mainIdea.tap()
        mainIdea.typeText("AI chip supply is tight")

        let save = app.buttons["保存"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled, "写了主旨之后「保存」仍然点不了")
        save.tap()

        XCTAssertTrue(
            app.navigationBars["对照"].waitForExistence(timeout: 5),
            "保存后没有进对照页"
        )

        app.buttons["关闭"].tap()

        // 收藏 tab：热点 | 周报 | 模型榜 | 收藏 | 设置 —— 收藏是第 4 个（下标 3）
        app.tabBars.buttons.element(boundBy: 3).tap()
        let practiceBook = app.descendants(matching: .any)["practice-book-row"]
        XCTAssertTrue(practiceBook.waitForExistence(timeout: 5), "收藏页没有练习本入口")
        practiceBook.tap()

        XCTAssertTrue(app.navigationBars["练习本"].waitForExistence(timeout: 5), "没进练习本")
        XCTAssertTrue(
            app.buttons["practice-entry-row"].firstMatch.waitForExistence(timeout: 5),
            "练习本里没有刚保存的记录"
        )
    }
}
