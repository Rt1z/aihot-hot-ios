import XCTest

@testable import AIHOT

final class EnricherTests: XCTestCase {

    // MARK: - 页面文本

    func testParsesTextFixture() throws {
        let text = try Fixture.text("hot-page", ext: "txt")
        let enrichment = try XCTUnwrap(HotPageEnricher.parse(text: text))

        XCTAssertEqual(enrichment.updatedText, "10月12日 10:35")
        XCTAssertEqual(enrichment.ranks.count, 3)
        XCTAssertTrue(enrichment.hasHeatValues)

        let first = try XCTUnwrap(enrichment.info(for: 1))
        XCTAssertEqual(first.heat, 143)
        XCTAssertTrue(first.isBreakout)
        XCTAssertEqual(first.delta, .up(629))

        let second = try XCTUnwrap(enrichment.info(for: 2))
        XCTAssertEqual(second.heat, 90)
        XCTAssertEqual(second.delta, .flat)
        XCTAssertFalse(second.isBreakout)

        let third = try XCTUnwrap(enrichment.info(for: 3))
        XCTAssertEqual(third.heat, 77)
        XCTAssertEqual(third.delta, .down(16))
    }

    func testOnlyTopThreeRanksAreParsed() throws {
        let text = try Fixture.text("hot-page", ext: "txt")
        let enrichment = try XCTUnwrap(HotPageEnricher.parse(text: text))

        // 4–10 名的数字在页面上没有稳定锚点，宁可不解析
        XCTAssertNil(enrichment.info(for: 4))
        XCTAssertNil(enrichment.info(for: 10))
    }

    func testHeatIsFoundAfterALongDigest() {
        // 真实页面上热度数字排在整段正文（几百字）之后，
        // 所以解析不能依赖「数字离序号多近」这种窗口。
        let longDigest = String(repeating: "正文。", count: 300)
        let text = """
        NO.01 爆 ↑ 20%
        标题
        \(longDigest)
        +10 7 个来源 · 16 位参与者
        160
        热度指数
        """
        let enrichment = HotPageEnricher.parse(text: text)
        XCTAssertEqual(enrichment?.info(for: 1)?.heat, 160)
    }

    // MARK: - HTML → 文本

    /// 临时诊断：定位 stripElement 为什么没剔除 script/style。用完即删。
    func testTemporaryStripDiagnostics() throws {
        let html = try Fixture.text("hot-page", ext: "html")
        print("DIAG fixture len=\(html.count) hasScriptTag=\(html.contains("<script")) hasStyleTag=\(html.contains("<style"))")

        let afterScript = HTMLTextExtractor.stripElement(html, tag: "script")
        print("DIAG stripElement(script) removed=\(!afterScript.contains("window.__NEXT_DATA__"))")

        let afterStyle = HTMLTextExtractor.stripElement(html, tag: "style")
        print("DIAG stripElement(style) removed=\(!afterStyle.contains("font-weight"))")

        let withWordBoundary = RegexUtil.replace(
            "<script\\b[^>]*>.*?</script>",
            in: html,
            with: "\n",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        print("DIAG probe-with-\\b removed=\(!withWordBoundary.contains("window.__NEXT_DATA__"))")

        let withoutWordBoundary = RegexUtil.replace(
            "<script[^>]*>.*?</script>",
            in: html,
            with: "\n",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        print("DIAG probe-without-\\b removed=\(!withoutWordBoundary.contains("window.__NEXT_DATA__"))")

        let greedy = RegexUtil.replace(
            "<script.*</script>",
            in: html,
            with: "\n",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        print("DIAG probe-greedy removed=\(!greedy.contains("window.__NEXT_DATA__"))")

        let text = HTMLTextExtractor.plainText(from: html)
        print("DIAG extracted-head=<\(text.prefix(240))>")
    }

    func testExtractsPlainTextFromHTML() throws {
        let html = try Fixture.text("hot-page", ext: "html")
        let text = HTMLTextExtractor.plainText(from: html)

        XCTAssertTrue(text.contains("热度指数"))
        XCTAssertTrue(text.contains("NO.01"))
        XCTAssertTrue(text.contains("143"))
        XCTAssertFalse(text.contains("window.__NEXT_DATA__"), "script 内容必须被剔除")
        XCTAssertFalse(text.contains("font-weight"), "style 内容必须被剔除")
        XCTAssertFalse(text.contains("<"), "不应残留标签")
        XCTAssertTrue(text.contains("·"), "HTML 实体应被解码")
        XCTAssertFalse(text.contains("&middot;"), "HTML 实体不应残留原文")
    }

    func testEndToEndHTMLToEnrichment() throws {
        let html = try Fixture.text("hot-page", ext: "html")
        let text = HTMLTextExtractor.plainText(from: html)
        let enrichment = try XCTUnwrap(HotPageEnricher.parse(text: text))

        XCTAssertEqual(enrichment.updatedText, "10月12日 10:35")
        XCTAssertEqual(enrichment.info(for: 1)?.heat, 143)
        XCTAssertEqual(enrichment.info(for: 1)?.delta, .up(629))
        XCTAssertTrue(enrichment.info(for: 1)?.isBreakout ?? false)
        XCTAssertEqual(enrichment.info(for: 2)?.delta, .flat)
    }

    // MARK: - 失败即放弃

    func testRejectsUnrelatedPage() {
        let text = "首页\n最新动态\n登录\n注册"
        XCTAssertNil(HotPageEnricher.parse(text: text))
    }

    func testDoesNotUseUnrelatedNumberAsHeat() {
        // 页面上 4–10 名的行里有「+43 个来源 65」这类数字，但没有「热度指数」锚点，
        // 就不能当成热度指数用
        let text = "NO.01 爆\n某条标题\n+43 个来源 65 新上榜\n继续往下\n"
        let enrichment = HotPageEnricher.parse(text: text)
        XCTAssertNil(enrichment?.info(for: 1)?.heat)
        XCTAssertEqual(enrichment?.info(for: 1)?.isBreakout, true)
    }

    func testTitleCannotFakeNewBadge() {
        // 标题里有「新」，但不在序号那一行，不能被当成「新上榜」
        let text = "NO.01 持平\n新模型发布：某公司推出新架构\n内容\n120\n热度指数"
        let enrichment = HotPageEnricher.parse(
            text: text,
            excludingTitles: ["新模型发布：某公司推出新架构"]
        )
        XCTAssertEqual(enrichment?.info(for: 1)?.isNew, false)
        XCTAssertEqual(enrichment?.info(for: 1)?.heat, 120)
    }

    func testBadgeOnNextLineIsStillFound() {
        // 序号和徽章被换行分开（真实页面里 div 结束就会产生换行）
        let text = "NO.01\n新上榜 ↑ 12%\n某条标题\n88\n热度指数"
        let enrichment = HotPageEnricher.parse(text: text)
        let info = enrichment?.info(for: 1)
        XCTAssertEqual(info?.isNew, true)
        XCTAssertEqual(info?.delta, .up(12))
        XCTAssertEqual(info?.heat, 88)
    }

    func testRankTenIsNotMistakenForRankOne() {
        // 如果页面把最后一名写成 NO.10，不能被读成 NO.01 而把它的数字算到第一名头上
        let text = """
        NO.01 爆
        第一条标题
        50
        热度指数
        NO.10 持平
        第十条标题
        10
        热度指数
        """
        let enrichment = HotPageEnricher.parse(text: text)
        XCTAssertEqual(enrichment?.info(for: 1)?.heat, 50)
        XCTAssertNil(enrichment?.info(for: 10))
    }
}
