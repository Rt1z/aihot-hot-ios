import XCTest

@testable import InOut

/// 练习里那些纯逻辑：统计、模式切换、提示词。
///
/// 这些用例与 `tools/logic_tests.py` 的镜像 23 读同一组规则（规则 4：
/// Swift 是权威，镜像是更快的预检）。
final class PracticeLogicTests: XCTestCase {

    private func date(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter.date(from: string)!
    }

    private func entry(
        at when: Date,
        mode: PracticeMode = .structured,
        mainIdea: String = "主旨",
        points: [String] = [],
        takeaway: String? = nil,
        freeText: String? = nil
    ) -> PracticeEntry {
        PracticeEntry(
            article: PracticeArticle(
                kind: .hot,
                articleID: "a",
                title: "标题",
                sourceName: nil,
                originalURL: nil,
                aihotURL: nil,
                digest: nil
            ),
            createdAt: when,
            mode: mode,
            mainIdea: mainIdea,
            points: points,
            takeaway: takeaway,
            freeText: freeText
        )
    }

    // MARK: - 统计

    func testStatsCountsTotalWeekAndStreak() {
        // 2026-11-16 是周一（北京时间）；本周 = 11/16 起。
        let now = date("2026-11-16T10:00:00+08:00")
        let entries = [
            entry(at: date("2026-11-16T09:00:00+08:00")),
            entry(at: date("2026-11-15T09:00:00+08:00")),
            entry(at: date("2026-11-14T09:00:00+08:00")),
            entry(at: date("2026-11-10T09:00:00+08:00")),
        ]

        let stats = PracticeStatsCalculator.make(entries: entries, now: now)
        XCTAssertEqual(stats.total, 4)
        XCTAssertEqual(stats.thisWeek, 1)
        XCTAssertEqual(stats.streakDays, 3)
    }

    func testStreakSurvivesUntilDayIsOver() {
        // 今天还没写：从昨天往回数，不算断签
        let now = date("2026-11-16T10:00:00+08:00")
        let entries = [
            entry(at: date("2026-11-15T09:00:00+08:00")),
            entry(at: date("2026-11-14T09:00:00+08:00")),
        ]
        XCTAssertEqual(PracticeStatsCalculator.make(entries: entries, now: now).streakDays, 2)
    }

    func testStreakBreaksWhenYesterdayIsAlsoMissing() {
        let now = date("2026-11-16T10:00:00+08:00")
        let entries = [entry(at: date("2026-11-13T09:00:00+08:00"))]
        XCTAssertEqual(PracticeStatsCalculator.make(entries: entries, now: now).streakDays, 0)
    }

    func testEmptyStats() {
        let stats = PracticeStatsCalculator.make(
            entries: [],
            now: date("2026-11-16T10:00:00+08:00")
        )
        XCTAssertEqual(stats, .empty)
    }

    func testStreakUsesBeijingDaysNotDeviceTimeZone() {
        // 北京时间 11/16 00:30 = UTC 11/15 16:30。按北京时间是「今天」，按 UTC 是「昨天」。
        let now = date("2026-11-16T10:00:00+08:00")
        let entries = [entry(at: date("2026-11-16T00:30:00+08:00"))]
        XCTAssertEqual(PracticeStatsCalculator.make(entries: entries, now: now).streakDays, 1)
    }

    // MARK: - 模式切换

    func testFreeToStructuredCarriesTheWholeTextIntoMainIdea() {
        var content = PracticeContent.empty(mode: .free)
        content.freeText = "一句话说完"
        let switched = PracticeText.transferring(content, to: .structured)

        XCTAssertEqual(switched.mode, .structured)
        XCTAssertEqual(switched.mainIdea, "一句话说完")
        XCTAssertEqual(switched.points, ["", "", ""])
    }

    func testStructuredToFreeJoinsAllParts() {
        var content = PracticeContent.empty(mode: .structured)
        content.mainIdea = "主旨"
        content.points = ["要点一", "", "要点二"]
        content.takeaway = "我的判断"

        let switched = PracticeText.transferring(content, to: .free)
        XCTAssertEqual(switched.mode, .free)
        XCTAssertTrue(switched.freeText.contains("主旨"))
        XCTAssertTrue(switched.freeText.contains("· 要点一"))
        XCTAssertTrue(switched.freeText.contains("· 要点二"))
        XCTAssertTrue(switched.freeText.contains("我的判断"))
    }

    func testSwitchingDoesNotOverwriteExistingContent() {
        // 两边都写过：切过去只换视图，不拿另一边覆盖这一边
        var content = PracticeContent.empty(mode: .free)
        content.freeText = "自由写的"
        content.mainIdea = "早就写好的主旨"

        let switched = PracticeText.transferring(content, to: .structured)
        XCTAssertEqual(switched.mainIdea, "早就写好的主旨")
        XCTAssertEqual(switched.freeText, "自由写的")
    }

    func testSwitchingBackRestoresStructuredContent() {
        var structured = PracticeContent.empty(mode: .structured)
        structured.mainIdea = "主旨"
        structured.points = ["要点一", "", ""]

        let free = PracticeText.transferring(structured, to: .free)
        let back = PracticeText.transferring(free, to: .structured)
        XCTAssertEqual(back.mainIdea, "主旨")
        XCTAssertEqual(back.points, ["要点一", "", ""])
    }

    // MARK: - 文字工具

    func testWordCountIgnoresWhitespace() {
        XCTAssertEqual(PracticeText.wordCount("a b\n中 文"), 4)
        XCTAssertEqual(PracticeText.wordCount("   "), 0)
    }

    func testNormalizedPointsTrimsDropsEmptyAndCapsAtThree() {
        let points = ["  一  ", "", "二", "三", "四"]
        XCTAssertEqual(PracticeText.normalizedPoints(points), ["一", "二", "三"])
    }

    func testCanSaveNeedsThePrimaryFieldOnly() {
        var structured = PracticeContent.empty(mode: .structured)
        structured.points = ["只有要点"]
        XCTAssertFalse(PracticeText.canSave(structured))
        structured.mainIdea = "主旨"
        XCTAssertTrue(PracticeText.canSave(structured))

        var free = PracticeContent.empty(mode: .free)
        XCTAssertFalse(PracticeText.canSave(free))
        free.freeText = " "
        XCTAssertFalse(PracticeText.canSave(free))
        free.freeText = "一句"
        XCTAssertTrue(PracticeText.canSave(free))
    }

    func testMatchesDetectsContentChange() {
        let original = entry(at: Date(timeIntervalSince1970: 1_760_000_000), mainIdea: "旧主旨")
        var content = PracticeContent.make(from: original)
        XCTAssertTrue(PracticeText.matches(entry: original, content: content))

        content.mainIdea = "新主旨"
        XCTAssertFalse(PracticeText.matches(entry: original, content: content))
    }

    func testModeCodableRoundTrip() {
        let data = try! JSONEncoder.aihot.encode(PracticeMode.structured)
        XCTAssertEqual(try! JSONDecoder.aihot.decode(PracticeMode.self, from: data), .structured)
    }

    // MARK: - 正文纯文本

    func testPlainTextKeepsBlockStructure() {
        let blocks: [ReportItemBody.Block] = [
            .heading(level: 2, text: "标题"),
            .paragraph([ReportItemBody.Run(text: "第一段", url: nil, bold: false)]),
            .bullets([
                [ReportItemBody.Run(text: "点一", url: nil, bold: false)],
                [ReportItemBody.Run(text: "点二", url: nil, bold: false)],
            ]),
            .divider,
        ]
        XCTAssertEqual(
            ReportItemBody.plainText(blocks: blocks),
            "## 标题\n\n第一段\n\n- 点一\n- 点二"
        )
    }

    // MARK: - 提示词

    private func article(digest: String?) -> PracticeArticle {
        PracticeArticle(
            kind: .hot,
            articleID: "a",
            title: "一篇关于推理成本的文章",
            sourceName: "示例来源",
            originalURL: nil,
            aihotURL: nil,
            digest: digest
        )
    }

    func testPromptMarksDigestBasisWhenFullTextIsMissing() {
        var content = PracticeContent.empty(mode: .structured)
        content.mainIdea = "推理变便宜了"
        content.points = ["价格下降", "", ""]

        let built = PracticeReviewPrompt.make(
            article: article(digest: "导读正文"),
            articleText: nil,
            content: content
        )

        XCTAssertEqual(built.basis, "导读")
        XCTAssertTrue(built.user.contains("材料类型：导读"))
        XCTAssertTrue(built.user.contains("导读正文"))
        XCTAssertTrue(built.user.contains("主旨：推理变便宜了"))
        XCTAssertTrue(built.user.contains("- 价格下降"))
        XCTAssertTrue(built.system.contains("禁止"))
        XCTAssertTrue(built.system.contains("不要假装看过全文"))
    }

    func testPromptUsesFullTextAndClampsIt() {
        let longText = String(repeating: "甲", count: PracticeReviewPrompt.maximumArticleCharacters + 100)
            + "尾部标记"
        var content = PracticeContent.empty(mode: .free)
        content.freeText = "我的总结"

        let built = PracticeReviewPrompt.make(
            article: article(digest: "导读"),
            articleText: longText,
            content: content
        )

        XCTAssertEqual(built.basis, "全文")
        XCTAssertTrue(built.user.contains("材料类型：全文"))
        XCTAssertTrue(built.user.contains("（材料过长，后文已省略）"))
        XCTAssertFalse(built.user.contains("尾部标记"))
        XCTAssertTrue(built.user.contains("我的总结"))
    }

    func testPromptWithoutAnyMaterialSaysSo() {
        var content = PracticeContent.empty(mode: .free)
        content.freeText = "总结"
        let built = PracticeReviewPrompt.make(
            article: article(digest: nil),
            articleText: nil,
            content: content
        )
        XCTAssertEqual(built.basis, "导读")
        XCTAssertTrue(built.user.contains("（没有可用的文章材料）"))
    }
}
