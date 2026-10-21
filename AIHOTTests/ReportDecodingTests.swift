import XCTest

@testable import AIHOT

/// 周报/月报四份真实夹具的端到端解码（规则 19）。
///
/// 断言全部来自夹具字节本身，不来自「应该是多少」的推理（规则 4）。
final class ReportDecodingTests: XCTestCase {

    // MARK: - 最新一期周报

    func testWeeklyLatestFixtureDecodes() throws {
        let data = try Fixture.data("report-weekly-latest", ext: "json")
        let envelope = try JSONDecoder.aihot.decode(ReportResponse.self, from: data)
        let report = envelope.report

        XCTAssertEqual(envelope.schemaVersion, 1)
        XCTAssertEqual(report.week, "2026-W42")
        XCTAssertNil(report.month)
        XCTAssertEqual(report.periodKey, "2026-W42")
        XCTAssertEqual(report.periodStart, "2026-10-12")
        XCTAssertEqual(report.periodEnd, "2026-10-18")

        // 带毫秒的 ISO8601 —— 内置 .iso8601 解不开，必须走 AIHOTDate.parse
        let generated = try XCTUnwrap(report.generatedAt)
        XCTAssertEqual(generated, try XCTUnwrap(AIHOTDate.parse("2026-10-19T02:00:16.671Z")))

        XCTAssertEqual(report.headline, "Google 发布 Gemini 4 Argon：面向复杂工程与科研任务的前沿模型")
        XCTAssertNotNil(report.overview, "新期次有 overview，缺了说明解码或夹具有变")
        XCTAssertEqual(report.links?.aihot, "https://aihot.news/weekly/2026-W42")
        XCTAssertEqual(report.attribution?.name, "AIHOT")

        // 四个分栏的标签与条数（标签原样渲染，不归一化）
        XCTAssertEqual(report.sections.map { $0.label }, ["模型发布/更新", "产品发布/更新", "行业动态", "论文研究"])
        XCTAssertEqual(report.sections.map { $0.items.count }, [7, 4, 6, 3])
        XCTAssertTrue(report.sections.allSatisfy { $0.summary != nil }, "新期次四个 summary 都在")

        let first = try XCTUnwrap(report.sections.first?.items.first)
        XCTAssertEqual(first.title, "Google 发布 Gemini 4 Argon：面向复杂工程与科研任务的前沿模型")
        XCTAssertEqual(first.source?.name, "Google Blog：AI（RSS）")
        XCTAssertEqual(first.links?.original,
                       "https://blog.google/innovation-and-ai/models-and-research/gemini-models/introducing-gemini-4-argon/")
        XCTAssertNotNil(first.links?.aihot, "站内条目回链是「网页版」的兜底")
        let published = try XCTUnwrap(first.publishedAt)
        XCTAssertEqual(published, try XCTUnwrap(AIHOTDate.parse("2026-10-13T16:00:00.000Z")))
    }

    // MARK: - 索引

    func testWeeklyIndexFixtureDecodes() throws {
        let data = try Fixture.data("report-weekly-index", ext: "json")
        let envelope = try JSONDecoder.aihot.decode(ReportIndexResponse.self, from: data)

        XCTAssertEqual(envelope.schemaVersion, 1)
        XCTAssertEqual(envelope.count, 12)
        XCTAssertEqual(envelope.items.count, 12)

        let ids = envelope.items.map { $0.id }
        XCTAssertEqual(Set(ids).count, ids.count, "期号必须唯一，否则 NavigationLink 会串页")
        XCTAssertEqual(ids.first, "2026-W42")
        XCTAssertEqual(ids.last, "2026-W31")
        XCTAssertEqual(envelope.items.first?.periodStart, "2026-10-12")
        XCTAssertEqual(envelope.items.last?.periodStart, "2026-07-27")

        // 「网页版」契约：每条往期都要有回链；headline 都在（行文案靠它）
        XCTAssertTrue(envelope.items.allSatisfy { $0.links?.aihot != nil })
        XCTAssertTrue(envelope.items.allSatisfy { $0.headline != nil })

        // 周报索引里每条都得认成 weekly —— 详情页按这个去取数，认错就是打错接口
        XCTAssertTrue(envelope.items.allSatisfy { $0.kind == .weekly })
    }

    // MARK: - 往期条目的栏目归属

    /// 往期区块有自己的切换（不跟着分段控件走），所以条目从哪一栏来**只能看它自己**：
    /// 用分段当前值会拿周报的期号去打月报端点。
    /// 没有月报索引夹具（官网只给全量、抓一份就够），所以月报那条直接构造。
    func testEntryKindIsDerivedFromItsOwnPeriodKey() {
        let weekly = ReportEntry(
            week: "2026-W41", month: nil, periodStart: nil, periodEnd: nil,
            generatedAt: nil, headline: nil, links: nil, attribution: nil
        )
        let monthly = ReportEntry(
            week: nil, month: "2026-09", periodStart: nil, periodEnd: nil,
            generatedAt: nil, headline: nil, links: nil, attribution: nil
        )
        let broken = ReportEntry(
            week: nil, month: nil, periodStart: nil, periodEnd: nil,
            generatedAt: nil, headline: nil, links: nil, attribution: nil
        )

        XCTAssertEqual(weekly.kind, .weekly)
        XCTAssertEqual(monthly.kind, .monthly)
        XCTAssertNil(broken.kind, "两个键都没有是数据坏；认不出就不该瞎猜")
    }

    // MARK: - 老期次的 null（可选性的回归钉）

    func testOlderWeeklyHasNullOverviewAndSectionSummaries() throws {
        let data = try Fixture.data("report-weekly-older", ext: "json")
        let envelope = try JSONDecoder.aihot.decode(ReportResponse.self, from: data)
        let report = envelope.report

        // 老期次真的没有 overview —— 字段必须可选，否则整期解不出来
        XCTAssertEqual(report.week, "2026-W30")
        XCTAssertNil(report.overview)
        XCTAssertEqual(report.sections.count, 5)

        // 老期次的 label 是主题句（新期次是分类名）—— 原样保留，不归一化
        XCTAssertEqual(report.sections.map { $0.label }, [
            "开源模型性能逼近前沿，闭源商业模式承压",
            "AI安全事件频发：自主智能体攻破生产环境",
            "端侧与具身智能模型加速落地",
            "AI办公与创作工具全面升级",
            "AI基础设施与训练效率创新"
        ])

        // 末栏 summary 也是 null（前四栏有）
        XCTAssertNil(report.sections[4].summary)
        XCTAssertNotNil(report.sections[0].summary)
        XCTAssertEqual(report.sections.map { $0.items.count }, [4, 4, 4, 4, 4])

        let first = try XCTUnwrap(report.sections.first?.items.first)
        XCTAssertEqual(first.title, "Qwen3.8 开源发布，2.4T 参数模型上线")
        // 摘要里有换行与 emoji —— 原文透传，不压缩
        XCTAssertTrue(first.summary?.contains("\n") ?? false)
    }

    // MARK: - 月报（钉 month 键）

    func testMonthlyLatestFixtureDecodes() throws {
        let data = try Fixture.data("report-monthly-latest", ext: "json")
        let envelope = try JSONDecoder.aihot.decode(ReportResponse.self, from: data)
        let report = envelope.report

        XCTAssertNil(report.week)
        XCTAssertEqual(report.month, "2026-09")
        XCTAssertEqual(report.periodKey, "2026-09")
        XCTAssertEqual(report.periodStart, "2026-09-01")
        XCTAssertEqual(report.periodEnd, "2026-09-30")
        XCTAssertEqual(report.links?.aihot, "https://aihot.news/monthly/2026-09")

        let generated = try XCTUnwrap(report.generatedAt)
        XCTAssertEqual(generated, try XCTUnwrap(AIHOTDate.parse("2026-10-01T11:48:32.108Z")))

        XCTAssertEqual(report.headline, "Anthropic 发布 Claude Opus 5.5，成本较 Opus 5 降低 40%")
        XCTAssertEqual(report.sections.map { $0.label },
                       ["模型发布/更新", "产品发布/更新", "行业动态", "论文研究", "技巧与观点"])
        // 月报里四个 summary 是 null —— 与老周报同一类形态
        XCTAssertEqual(report.sections.filter { $0.summary == nil }.count, 4)
        XCTAssertNotNil(report.sections[0].summary)

        let first = try XCTUnwrap(report.sections.first?.items.first)
        XCTAssertEqual(first.source?.name, "Anthropic：Newsroom（网页）")
        XCTAssertEqual(first.links?.original, "https://www.anthropic.com/claude-opus-5-5")
    }

    // MARK: - 快照 round-trip（秒精度）

    func testReportKindStateSnapshotRoundTripsAtSecondPrecision() throws {
        let reportData = try Fixture.data("report-weekly-latest", ext: "json")
        let report = try JSONDecoder.aihot.decode(ReportResponse.self, from: reportData).report
        let indexData = try Fixture.data("report-weekly-index", ext: "json")
        let entries = try JSONDecoder.aihot.decode(ReportIndexResponse.self, from: indexData).items

        let state = ReportKindState(latest: report, entries: entries, lastUpdated: report.generatedAt, hasLoaded: true)
        let encoded = try JSONEncoder.aihot.encode(state)
        let restored = try JSONDecoder.aihot.decode(ReportKindState.self, from: encoded)

        XCTAssertEqual(restored.hasLoaded, true)
        XCTAssertEqual(restored.latest?.periodKey, "2026-W42")
        XCTAssertEqual(restored.latest?.sections.count, 4)
        XCTAssertEqual(restored.entries.count, 12)

        // JSONEncoder.aihot 写的是**不带小数秒**的 ISO8601 —— round-trip 后截到整秒，
        // 断言必须按秒精度写（写 .671 必红，见 CLAUDE.md 编码器不对称那条）
        let truncated = try XCTUnwrap(AIHOTDate.parse("2026-10-19T02:00:16Z"))
        XCTAssertEqual(restored.latest?.generatedAt, truncated)
        XCTAssertEqual(restored.lastUpdated, truncated)
    }
}
