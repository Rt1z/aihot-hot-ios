import XCTest

@testable import AIHOT

/// `ReportPeriod` 纯函数（镜像 18 的 Swift 侧权威）：
/// 期号 → 中文标题、日期区间 → 展示文案、往期按月分组。
final class ReportPeriodTests: XCTestCase {

    // MARK: - title

    func testTitleForWeekKeys() {
        XCTAssertEqual(ReportPeriod.title(periodKey: "2026-W42"), "2026 年第 42 周")
        XCTAssertEqual(ReportPeriod.title(periodKey: "2026-W07"), "2026 年第 7 周")  // 补零要剥掉
        XCTAssertEqual(ReportPeriod.title(periodKey: "2026-W1"), "2026 年第 1 周")   // 位数不限
        XCTAssertEqual(ReportPeriod.title(periodKey: "2026-W53"), "2026 年第 53 周")
    }

    func testTitleForMonthKeys() {
        XCTAssertEqual(ReportPeriod.title(periodKey: "2026-09"), "2026 年 9 月")
        XCTAssertEqual(ReportPeriod.title(periodKey: "2026-12"), "2026 年 12 月")
    }

    func testTitleRejectsUnrecognizedKeys() {
        XCTAssertNil(ReportPeriod.title(periodKey: "2026-W54"), "一年最多 53 周")
        XCTAssertNil(ReportPeriod.title(periodKey: "2026-W0"))
        XCTAssertNil(ReportPeriod.title(periodKey: "2026-13"), "没有第 13 个月")
        XCTAssertNil(ReportPeriod.title(periodKey: "2026-00"))
        XCTAssertNil(ReportPeriod.title(periodKey: "W42"), "缺年份")
        XCTAssertNil(ReportPeriod.title(periodKey: "2026/09"))
        XCTAssertNil(ReportPeriod.title(periodKey: "banana"))
    }

    // MARK: - rangeText

    func testRangeTextWithinSameYear() {
        // 补零两位的 MM.dd，区间用 en dash 两边带空格
        XCTAssertEqual(ReportPeriod.rangeText(start: "2026-10-12", end: "2026-10-18"), "10.12 – 10.18")
        XCTAssertEqual(ReportPeriod.rangeText(start: "2026-09-01", end: "2026-09-30"), "09.01 – 09.30")
    }

    func testRangeTextCrossesYear() {
        XCTAssertEqual(ReportPeriod.rangeText(start: "2025-12-29", end: "2026-01-04"), "2025.12.29 – 2026.01.04")
    }

    func testRangeTextIsNilWhenEitherEndIsMissingOrInvalid() {
        XCTAssertNil(ReportPeriod.rangeText(start: nil, end: "2026-10-18"))
        XCTAssertNil(ReportPeriod.rangeText(start: "2026-10-12", end: nil))
        XCTAssertNil(ReportPeriod.rangeText(start: nil, end: nil))
        // 缺一半没有信息量；格式不对宁可不显示（不编造）
        XCTAssertNil(ReportPeriod.rangeText(start: "2026-10", end: "2026-10-18"))
        XCTAssertNil(ReportPeriod.rangeText(start: "2026-10-12", end: "2026-13-01"))
        XCTAssertNil(ReportPeriod.rangeText(start: "2026-10-12", end: "2026-10-32"))
    }

    // MARK: - groupByMonth

    func testGroupByMonthOnIndexFixturePreservesOrderAndCounts() throws {
        let data = try Fixture.data("report-weekly-index", ext: "json")
        let entries = try JSONDecoder.aihot.decode(ReportIndexResponse.self, from: data).items
        XCTAssertEqual(entries.count, 12)

        let groups = ReportPeriod.groupByMonth(entries)

        // 接口给的顺序就是新→旧，分组顺序必须原样保留（不排序 —— 同规则 8 的道理）
        XCTAssertEqual(groups.map { $0.title }, ["2026 年 10 月", "2026 年 9 月", "2026 年 8 月", "2026 年 7 月"])
        XCTAssertEqual(groups.map { $0.entries.count }, [2, 4, 5, 1])

        // 不丢不重：合起来必须恰好是输入
        let flat = groups.flatMap { $0.entries }
        XCTAssertEqual(flat.count, entries.count)
        XCTAssertEqual(Set(flat.map { $0.id }), Set(entries.map { $0.id }))
    }

    func testGroupByMonthSendsMissingPeriodStartToTrailingOtherGroup() {
        let valid = ReportEntry(week: "2026-W41", month: nil, periodStart: "2026-10-05",
                                periodEnd: nil, generatedAt: nil, headline: nil, links: nil, attribution: nil)
        let noStart = ReportEntry(week: "2026-W01", month: nil, periodStart: nil,
                                  periodEnd: nil, generatedAt: nil, headline: nil, links: nil, attribution: nil)
        let badStart = ReportEntry(week: "2026-W02", month: nil, periodStart: "not-a-date",
                                   periodEnd: nil, generatedAt: nil, headline: nil, links: nil, attribution: nil)
        let alsoValid = ReportEntry(week: "2026-W42", month: nil, periodStart: "2026-10-12",
                                    periodEnd: nil, generatedAt: nil, headline: nil, links: nil, attribution: nil)

        let groups = ReportPeriod.groupByMonth([valid, noStart, badStart, alsoValid])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].title, "2026 年 10 月")
        // 同月内保持输入顺序（10-05 在 10-12 前面）
        XCTAssertEqual(groups[0].entries.map { $0.id }, ["2026-W41", "2026-W42"])
        XCTAssertEqual(groups[1].title, "其它")
        XCTAssertEqual(groups[1].entries.map { $0.id }, ["2026-W01", "2026-W02"])
    }

    func testGroupByMonthOnEmptyInputIsEmpty() {
        XCTAssertTrue(ReportPeriod.groupByMonth([]).isEmpty)
    }
}
