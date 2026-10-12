import XCTest

@testable import AIHOT

/// 「报道节奏」的纯逻辑。
///
/// 夹具 `story-timeline.json` 是刻意排的：北京时间 06:00–08:59 每小时各 2 条，
/// 09:00–11:59 一条没有，12:00 那小时 3 条，13:00 起回落，另外还有一条没有
/// `publishedAt`。所以下面的数字都来自夹具的实际内容，不是「应该等于几」的推理 ——
/// 夹具一改，这里就该跟着改。
final class ReportTimelineTests: XCTestCase {

    private func fixtureStory() throws -> Story {
        let data = try Fixture.data("story-timeline", ext: "json")
        return try JSONDecoder.aihot.decode(StoryResponse.self, from: data).story
    }

    private func fixtureSummary() throws -> ReportTimeline.Summary {
        let story = try fixtureStory()
        return try XCTUnwrap(ReportTimeline.make(story: story))
    }

    /// 临时拼一条 story，用来覆盖夹具不好表达的情形。
    /// 只给 `id` 与 `publishedAt`：`Report` 的其它字段都是可选的。
    private func story(reportsJSON: String) throws -> Story {
        let json = #"{"schemaVersion":1,"story":{"publicId":"t","title":"T","reports":[\#(reportsJSON)]}}"#
        return try JSONDecoder.aihot.decode(StoryResponse.self, from: Data(json.utf8)).story
    }

    // MARK: - 夹具本身

    func testFixtureHasBothADatedReportAndOneWithoutATimestamp() throws {
        let story = try fixtureStory()
        // 夹具的前提条件：断言下面那些数字之前，先确认输入就是设想的样子
        XCTAssertEqual(story.reports?.count, 15)
        XCTAssertEqual(story.reports?.compactMap { $0.publishedAt }.count, 14)
        XCTAssertEqual(story.reportCount, 43)
    }

    // MARK: - 分桶

    func testTenHourWindowFallsIntoHourlyBuckets() throws {
        let summary = try fixtureSummary()
        XCTAssertEqual(summary.buckets.count, 10, "06:00–15:00，一小时一桶")
        XCTAssertEqual(summary.buckets.first?.label, "06:00")
        XCTAssertEqual(summary.buckets.last?.label, "15:00")
    }

    func testBucketCountsMatchTheFixture() throws {
        let summary = try fixtureSummary()
        XCTAssertEqual(
            summary.buckets.map { $0.label },
            ["06:00", "07:00", "08:00", "09:00", "10:00", "11:00", "12:00", "13:00", "14:00", "15:00"]
        )
        XCTAssertEqual(summary.buckets.map { $0.count }, [2, 2, 2, 0, 0, 0, 3, 2, 1, 2])
    }

    /// 断档那三小时必须是**贴着底的柱子**，不能因为「没有报道」就把桶删掉 ——
    /// 图要说明的恰恰是「这段时间没人跟了」。
    func testQuietHoursSurviveAsEmptyBuckets() throws {
        let summary = try fixtureSummary()
        let empty = summary.buckets.filter { $0.count == 0 }
        XCTAssertEqual(empty.map { $0.label }, ["09:00", "10:00", "11:00"])
        // 而且它们真的夹在两边都有报道的桶中间（不是收尾的空白）
        XCTAssertEqual(summary.buckets.first?.count, 2)
        XCTAssertEqual(summary.buckets.last?.count, 2)
    }

    func testReportWithoutATimestampIsExcludedFromTheChart() throws {
        let summary = try fixtureSummary()
        XCTAssertEqual(summary.totalTimestamped, 14, "15 条里那条没有时间的不能算进来")
        XCTAssertEqual(summary.buckets.map { $0.count }.reduce(0, +), 14)
    }

    func testPeakIsTheEarliestBucketWithTheMostReports() throws {
        let summary = try fixtureSummary()
        XCTAssertEqual(summary.peak.label, "12:00")
        XCTAssertEqual(summary.peak.count, 3)
        XCTAssertEqual(summary.buckets.filter { $0.isPeak }.count, 1, "并列时只标最早的那个")
    }

    func testOnlyTheNewestBucketIsMarkedAsNewest() throws {
        let summary = try fixtureSummary()
        XCTAssertEqual(summary.buckets.filter { $0.isNewest }.map { $0.label }, ["15:00"])
    }

    // MARK: - 轴与统计

    func testAxisLabelsAreEvenlySpreadAndKeepBothEnds() throws {
        let summary = try fixtureSummary()
        XCTAssertEqual(summary.axisLabels, ["06:00", "08:00", "10:00", "12:00", "15:00"])
        XCTAssertEqual(summary.axisLabels.first, summary.buckets.first?.label)
        XCTAssertEqual(summary.axisLabels.last, summary.buckets.last?.label)
    }

    func testLabelsNeverRepeat() throws {
        let summary = try fixtureSummary()
        // x 轴按标签分类，重名会被合并成一根柱子 —— 这是轴正确性的前提
        XCTAssertEqual(Set(summary.buckets.map { $0.label }).count, summary.buckets.count)
    }

    func testLast24HourCountCoversTheWholeWindowHere() throws {
        let summary = try fixtureSummary()
        XCTAssertEqual(summary.last24HourCount, 14, "整条流只跨 10 小时，都在最新一条之后 24 小时内")
    }

    /// 接口说一共有 43 条，我们只拿到 15 条 —— 界面必须把这件事说出来。
    func testTruncatedIsSetWhenTheAPIClaimsMoreReportsThanWeHave() throws {
        let summary = try fixtureSummary()
        XCTAssertTrue(summary.truncated)
    }

    func testNotTruncatedWhenTheAPIReportsNoMoreThanWeHave() throws {
        let story = try story(reportsJSON: """
        {"id":"a","publishedAt":"2026-10-12T00:00:00.000Z"},
        {"id":"b","publishedAt":"2026-10-12T02:00:00.000Z"}
        """)
        let summary = try XCTUnwrap(ReportTimeline.make(story: story))
        XCTAssertFalse(summary.truncated, "reportCount 缺省时不能凭空说被截断")
    }

    // MARK: - 边界

    func testFewerThanTwoTimestampedReportsDrawsNothing() throws {
        let one = try story(reportsJSON: #"{"id":"a","publishedAt":"2026-10-12T00:00:00.000Z"}"#)
        XCTAssertNil(ReportTimeline.make(story: one), "一根柱子没有可比性")

        let none = try story(reportsJSON: #"{"id":"a","publishedAt":null}"#)
        XCTAssertNil(ReportTimeline.make(story: none))

        // 真实的 story.json 只有 1 条报道：详情页这一节就不能出现
        let committedData = try Fixture.data("story", ext: "json")
        let committed = try JSONDecoder.aihot.decode(StoryResponse.self, from: committedData).story
        XCTAssertNil(ReportTimeline.make(story: committed))
    }

    func testAllReportsInOneBucketDrawsNothing() throws {
        let story = try story(reportsJSON: """
        {"id":"a","publishedAt":"2026-10-12T03:00:00.000Z"},
        {"id":"b","publishedAt":"2026-10-12T03:05:00.000Z"}
        """)
        XCTAssertNil(ReportTimeline.make(story: story), "两条落在同一个 15 分钟桶里，画不出节奏")
    }

    /// 夹具走的是「1 小时」档，这里补上最细的那一档（北京时间 08:05 / 08:20 / 08:35）。
    func testHalfHourWindowFallsIntoQuarterHourBuckets() throws {
        let story = try story(reportsJSON: """
        {"id":"a","publishedAt":"2026-10-12T00:05:00.000Z"},
        {"id":"b","publishedAt":"2026-10-12T00:20:00.000Z"},
        {"id":"c","publishedAt":"2026-10-12T00:35:00.000Z"}
        """)
        let summary = try XCTUnwrap(ReportTimeline.make(story: story))
        XCTAssertEqual(summary.buckets.map { $0.label }, ["08:00", "08:15", "08:30"])
        XCTAssertEqual(summary.buckets.map { $0.count }, [1, 1, 1])
        XCTAssertEqual(summary.peak.label, "08:00", "三个桶并列时峰值取最早")
    }

    /// 跨度大就退到「每天」一桶。顺便钉住**不依赖当前时间**这件事：
    /// 这几条是 2020 年的数据，如果实现里读了 `Date()`，这里会退化成空窗口。
    func testLongSpanFallsBackToDailyBuckets() throws {
        let story = try story(reportsJSON: """
        {"id":"a","publishedAt":"2020-01-01T00:00:00.000Z"},
        {"id":"b","publishedAt":"2020-01-02T16:00:00.000Z"},
        {"id":"c","publishedAt":"2020-01-04T08:00:00.000Z"}
        """)
        let summary = try XCTUnwrap(ReportTimeline.make(story: story))
        XCTAssertEqual(summary.buckets.count, 4, "北京时间 1月1日 08:00 → 1月4日 16:00")
        XCTAssertEqual(summary.buckets.map { $0.label }, ["1月1日", "1月2日", "1月3日", "1月4日"])
        XCTAssertEqual(summary.buckets.map { $0.count }, [1, 0, 1, 1])
        XCTAssertEqual(summary.peak.label, "1月1日", "并列取最早")
        XCTAssertEqual(summary.last24HourCount, 1, "只有 1月4日 16:00 那一条在最新一条之后 24 小时内")
        XCTAssertEqual(summary.axisLabels.count, 4, "不足 5 个就全显示")
    }

    func testSameStoryAlwaysProducesTheSameChart() throws {
        let story = try fixtureStory()
        XCTAssertEqual(ReportTimeline.make(story: story), ReportTimeline.make(story: story))
    }
}
