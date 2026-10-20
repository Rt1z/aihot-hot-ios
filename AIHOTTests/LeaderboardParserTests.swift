import XCTest
@testable import AIHOT

/// 模型榜解析器测试。
///
/// 三份夹具是 **2026-10-20 的真实抓取**（站点分数/价格会随更新漂移）——
/// 断言的是解析器对**这份字节**的行为，不是对「今天的官网」。
/// `tools/logic_tests.py` 的镜像 17 读同一批夹具；规则 4：Swift 是权威。
final class LeaderboardParserTests: XCTestCase {

    // MARK: - 榜页

    func testParsesOverallBoardFixture() throws {
        let html = try Fixture.text("leaderboard-overall", ext: "html")
        let board = try XCTUnwrap(LeaderboardParser.parseBoard(html: html, category: .overall))

        XCTAssertEqual(board.category, .overall)
        XCTAssertEqual(board.models.count, 30)
        XCTAssertEqual(board.evalTotal, 35)
        XCTAssertEqual(board.institutionCount, 7)
        XCTAssertEqual(board.updatedText, "10/20 09:12")

        let first = board.models[0]
        XCTAssertEqual(first.rank, 1)
        XCTAssertEqual(first.slug, "claude-opus-5-5")
        XCTAssertEqual(first.name, "Claude Opus 5.5")
        XCTAssertEqual(first.provider, "Anthropic")
        XCTAssertEqual(first.releasedISO, "2026-09-22")
        XCTAssertEqual(first.evalCount, 34)
        XCTAssertEqual(first.coveragePercent, 96)
        XCTAssertEqual(first.cachePrice, "¥1.34")
        XCTAssertEqual(first.inputPrice, "¥26.72")
        XCTAssertEqual(first.outputPrice, "¥133.61")
        XCTAssertEqual(first.score, 73.8)

        let last = board.models[29]
        XCTAssertEqual(last.rank, 30)
        XCTAssertEqual(last.slug, "claude-sonnet-5")
        XCTAssertEqual(last.name, "Claude Sonnet 5")
        XCTAssertEqual(last.score, 59.1)
    }

    func testUnverifiedPricesParseAsNil() throws {
        let html = try Fixture.text("leaderboard-overall", ext: "html")
        let board = try XCTUnwrap(LeaderboardParser.parseBoard(html: html, category: .overall))
        let muse = try XCTUnwrap(board.models.first { $0.slug == "muse-wonder-full" })

        // 页面上是「待核验」→ 三档价格都是 nil（UI 显灰字），不编数字
        XCTAssertNil(muse.cachePrice)
        XCTAssertNil(muse.inputPrice)
        XCTAssertNil(muse.outputPrice)
        XCTAssertEqual(muse.score, 70.3)
    }

    func testParsesCategoryBoardFixtureIndependently() throws {
        let html = try Fixture.text("leaderboard-coding", ext: "html")
        let board = try XCTUnwrap(LeaderboardParser.parseBoard(html: html, category: .coding))

        XCTAssertEqual(board.category, .coding)
        XCTAssertEqual(board.models.count, 30)
        // 分类榜页头与综合榜不同：读的是本页数据
        XCTAssertEqual(board.evalTotal, 9)
        XCTAssertEqual(board.institutionCount, 3)

        let first = board.models[0]
        XCTAssertEqual(first.slug, "claude-opus-5-5")
        // 同一个模型在编程榜上的分数/评测数与综合榜不同
        XCTAssertEqual(first.evalCount, 8)
        XCTAssertEqual(first.coveragePercent, 86)
        XCTAssertEqual(first.score, 74.3)

        let last = board.models[29]
        XCTAssertEqual(last.slug, "gpt-5-6-luna")
        XCTAssertEqual(last.score, 59.2)
    }

    // MARK: - 详情页

    func testParsesDetailFixture() throws {
        let html = try Fixture.text("leaderboard-detail", ext: "html")
        let detail = try XCTUnwrap(LeaderboardParser.parseDetail(html: html))

        XCTAssertEqual(detail.name, "Claude Opus 5.5")
        XCTAssertEqual(detail.provider, "Anthropic")
        XCTAssertEqual(detail.releasedText, "2026-09-22 发布")
        XCTAssertEqual(detail.updatedText, "10/20 09:12")
        XCTAssertEqual(detail.overallScore, 73.8)
        XCTAssertEqual(detail.overallRank, 1)
        XCTAssertEqual(detail.coveragePercent, 96)
        XCTAssertEqual(detail.contextWindowText, "100万 Token")
        XCTAssertEqual(detail.inputPrice, "¥26.72")
        XCTAssertEqual(detail.outputPrice, "¥133.61")
        XCTAssertEqual(detail.cachePrice, "¥1.34")
        XCTAssertEqual(detail.originalUSDText, "$4 / $20")

        XCTAssertEqual(detail.cards.count, 4)
        let coding = try XCTUnwrap(detail.cards.first { $0.category == .coding })
        XCTAssertEqual(coding.score, 74.3)
        XCTAssertEqual(coding.rank, 1)
        XCTAssertEqual(coding.evalCount, 8)
        XCTAssertEqual(coding.coveragePercent, 86)
        let knowledge = try XCTUnwrap(detail.cards.first { $0.category == .knowledge })
        XCTAssertEqual(knowledge.rank, 5)
    }

    func testParsesBenchmarkGroupsFromDetailFixture() throws {
        let html = try Fixture.text("leaderboard-detail", ext: "html")
        let detail = try XCTUnwrap(LeaderboardParser.parseDetail(html: html))

        // 编程 8 + 科研 9 + 专业办公 10 + 知识问答 7 + 真人盲选 1 = 35 项
        XCTAssertEqual(detail.groups.count, 5)
        let total = detail.groups.reduce(0) { $0 + $1.items.count }
        XCTAssertEqual(total, 35)

        let coding = try XCTUnwrap(detail.groups.first { $0.category == .coding })
        XCTAssertEqual(coding.heading, "编程")
        XCTAssertEqual(coding.score, 74.3)
        XCTAssertEqual(coding.evalCount, 8)
        XCTAssertEqual(coding.items.count, 8)
        let first = coding.items[0]
        XCTAssertEqual(first.name, "ProgramBench")
        XCTAssertEqual(first.source, "Vals AI 旧型号作答 12%")
        XCTAssertEqual(first.scoreText, "18.5%")
        XCTAssertEqual(first.converted, "108.1")

        // 真人盲选不在分类榜里，category 为 nil 但分组和条目还在
        let blind = try XCTUnwrap(detail.groups.first { $0.heading == "真人盲选" })
        XCTAssertNil(blind.category)
        XCTAssertEqual(blind.items.count, 1)
        XCTAssertEqual(blind.items[0].name, "Arena Text")
        XCTAssertEqual(blind.items[0].scoreText, "1,508.2")

        // 名字前有字母徽章（P）的条目：名字不能被劈成徽章
        let knowledge = try XCTUnwrap(detail.groups.first { $0.category == .knowledge })
        let bullshit = try XCTUnwrap(knowledge.items.first { $0.name.contains("BullshitBench") })
        XCTAssertEqual(bullshit.name, "BullshitBench v2")
        XCTAssertEqual(bullshit.source, "BullshitBench")
        XCTAssertEqual(bullshit.scoreText, "62.0%")

        // 折算分带「至多」前缀的条目
        let professional = try XCTUnwrap(detail.groups.first { $0.category == .professional })
        let harvey = try XCTUnwrap(professional.items.first { $0.name.hasPrefix("Harvey") })
        XCTAssertEqual(harvey.converted, "至多 55.1")
    }

    // MARK: - 合成边界

    func testEmptyAndGarbageInputReturnsNil() throws {
        XCTAssertNil(LeaderboardParser.parseBoard(html: "", category: .overall))
        XCTAssertNil(LeaderboardParser.parseBoard(html: "<html><body>完全不是榜单</body></html>", category: .overall))
        XCTAssertNil(LeaderboardParser.parseDetail(html: ""))
        // 认不出 <h1> 才是 nil；只有 h1 也能出详情 —— 其余字段全 nil，UI 各自显灰
        let bare = try XCTUnwrap(LeaderboardParser.parseDetail(html: "<html><body><h1>只有名字</h1></body></html>"))
        XCTAssertEqual(bare.name, "只有名字")
        XCTAssertNil(bare.overallScore)
        XCTAssertTrue(bare.cards.isEmpty)
        XCTAssertTrue(bare.groups.isEmpty)
    }

    func testRowsWithoutAnchorAttributesAreSkipped() throws {
        // 只有 data-slug 行才进榜；没有锚点的表格行整行丢弃
        let html = """
        <html><body><main>
        <table>
        <tr><td>99</td><td>幽灵行</td></tr>
        <tr data-slug="demo-model"><td>01</td>
          <td><a href="/x"><strong>Demo Model</strong></a><small>Acme</small></td>
          <td><time>2026-01-02</time></td>
          <td><span>3 项评测</span><span>覆盖 50 %</span></td>
          <td>¥1.00</td><td>¥2.00</td><td>¥3.00</td>
          <td><strong>88.8  覆盖 50 %</strong></td>
        </tr>
        </table>
        </main></body></html>
        """
        let board = try XCTUnwrap(LeaderboardParser.parseBoard(html: html, category: .overall))
        XCTAssertEqual(board.models.count, 1)
        let model = board.models[0]
        XCTAssertEqual(model.slug, "demo-model")
        XCTAssertEqual(model.rank, 1)
        XCTAssertEqual(model.name, "Demo Model")
        XCTAssertEqual(model.provider, "Acme")
        XCTAssertEqual(model.releasedISO, "2026-01-02")
        XCTAssertEqual(model.evalCount, 3)
        XCTAssertEqual(model.coveragePercent, 50)
        XCTAssertEqual(model.cachePrice, "¥1.00")
        XCTAssertEqual(model.score, 88.8)
    }
}
