import XCTest

/// 设置页「搜索工具」的两条 UI 用例 —— 钉住单测覆盖不到的那类问题：
/// 1. 中间行的 ↑ 真的能把行换上去（Form 行里多按钮共享点击区域的回归钉 ——
///    「↑↓ 按了没反应」就是先在真机上炸出来的，XCTest/镜像都测不到这一层）；
/// 2. 顺序与开关即点即存（杀掉 App 重开还在）。
///
/// 每条用例**首次**启动带 `uitests-reset-search-settings`（`AIHOTApp.init` 里
/// 据此重置顺序/开关），**验证持久化的第二次启动不带** —— 带了会把刚存的值又抹掉。
final class SearchToolSettingsUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchApp(resetSearchTools: Bool) {
        app = XCUIApplication()
        app.launchArguments = resetSearchTools ? ["uitests-reset-search-settings"] : []
        app.launch()
        openSearchToolsSection()
    }

    /// 设置 tab（第三格）→ 滚到「搜索工具」区块（在「AI 对话」下面一屏）。
    private func openSearchToolsSection() {
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15), "App 没能启动")
        app.tabBars.buttons.element(boundBy: 2).tap()
        reveal(app.switches["search-toggle-serpapi"])
    }

    /// 把元素滚到可点区域（表单下半截的行初始不在屏内）。
    private func reveal(_ element: XCUIElement, maxSwipes: Int = 8) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "元素不存在：\(element)")
        var swipes = 0
        while !element.isHittable && swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(element.isHittable, "滚了 \(swipes) 次仍点不到：\(element)")
    }

    /// UISwitch 的 value 在不同 iOS 版本上可能是 Bool，也可能是 "1"/"0" 字符串，两种都认。
    private func isOn(_ toggle: XCUIElement) -> Bool {
        if let flag = toggle.value as? Bool { return flag }
        if let text = toggle.value as? String {
            return text == "1" || text.lowercased() == "true"
        }
        return false
    }

    /// 中间行 ↑：SerpAPI 与上面的 Tavily 换位；重开后顺序还在。
    func testMovingMiddleProviderUpwardsSwapsRowsAndPersists() {
        launchApp(resetSearchTools: true)
        let serpapi = app.switches["search-toggle-serpapi"]
        let tavily = app.switches["search-toggle-tavily"]
        reveal(serpapi)
        reveal(tavily)

        // 默认顺序 AnySearch, Tavily, SerpAPI, …：Tavily 在 SerpAPI 上面
        XCTAssertLessThan(tavily.frame.minY, serpapi.frame.minY, "默认顺序不对")

        app.buttons["search-up-serpapi"].tap()
        // 等 Form 重排动画落定再比坐标
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertLessThan(
            serpapi.frame.minY, tavily.frame.minY,
            "↑ 没有把 SerpAPI 换到 Tavily 上面 —— 按钮没生效，或又被 Form 行共享点击吃掉了"
        )

        // 即点即存：第二次启动**不带**重置参数，顺序应该还是换过的
        app.terminate()
        launchApp(resetSearchTools: false)
        XCTAssertTrue(serpapi.waitForExistence(timeout: 10))
        reveal(serpapi)
        reveal(tavily)
        XCTAssertLessThan(serpapi.frame.minY, tavily.frame.minY, "重启后顺序丢了")
    }

    /// 拨掉 Exa 的开关，重启后还是关的。
    func testTogglingProviderOffPersists() {
        launchApp(resetSearchTools: true)
        let exa = app.switches["search-toggle-exa"]
        reveal(exa)
        XCTAssertTrue(isOn(exa), "重置后 Exa 应该是开着的")

        exa.tap()
        XCTAssertFalse(isOn(exa), "点一下没关掉")

        app.terminate()
        launchApp(resetSearchTools: false)
        XCTAssertTrue(exa.waitForExistence(timeout: 10))
        reveal(exa)
        XCTAssertFalse(isOn(exa), "重启后开关丢了")
    }
}
