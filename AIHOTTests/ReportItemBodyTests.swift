import XCTest
@testable import AIHOT

/// 周报/月报条目站内页（`/items/{id}`）正文解析的测试。
///
/// 四份夹具是 **2026-10-21 的真实抓取**（React Router SSR，唯一锚点是
/// `<div class="prose">`）—— 断言的是解析器对**这份字节**的行为，不是对
/// 「今天的官网」。`tools/logic_tests.py` 的镜像 20 读同一批夹具；
/// 规则 4：Swift 是权威，两边不一致先怀疑 Python。
final class ReportItemBodyTests: XCTestCase {

    // MARK: - 辅助

    private func parsed(_ name: String) throws -> [ReportItemBody.Block] {
        let html = try Fixture.text("report-item-\(name)", ext: "html")
        return try XCTUnwrap(ReportItemBody.parse(html: html), "\(name) 认不出正文")
    }

    private func isHeading(_ block: ReportItemBody.Block) -> Bool {
        if case .heading = block { return true }
        return false
    }

    private func firstHeading(_ blocks: [ReportItemBody.Block]) throws -> ReportItemBody.Block {
        try XCTUnwrap(blocks.first(where: isHeading), "这一份里没有标题块")
    }

    private func firstBullets(_ blocks: [ReportItemBody.Block]) -> [[ReportItemBody.Run]]? {
        for block in blocks {
            if case .bullets(let items) = block { return items }
        }
        return nil
    }

    private func kindCounts(_ blocks: [ReportItemBody.Block]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for block in blocks {
            counts[kindKey(block), default: 0] += 1
        }
        return counts
    }

    private func kindKey(_ block: ReportItemBody.Block) -> String {
        switch block {
        case .heading: return "heading"
        case .paragraph: return "paragraph"
        case .bullets: return "bullets"
        case .divider: return "divider"
        }
    }

    private func plain(_ block: ReportItemBody.Block) -> String? {
        switch block {
        case .paragraph(let runs): return ReportItemBody.plainText(runs: runs)
        case .heading(_, let text): return text
        case .bullets(let items): return items.map { ReportItemBody.plainText(runs: $0) }
            .joined(separator: "\n")
        case .divider: return nil
        }
    }

    // MARK: - 夹具

    /// 四份夹具都要抽得出正文 —— 认不出就会退回轻量版详情页，那正是用户不要的。
    func testAllFourFixturePagesYieldBody() throws {
        for name in ["anthropic", "google", "techcrunch", "xai"] {
            let blocks = try parsed(name)
            XCTAssertFalse(blocks.isEmpty, "\(name) 抽出来是空的")
        }
    }

    /// 块型分布全部来自夹具实测。
    func testBlockKindCountsMatchFixture() throws {
        XCTAssertEqual(kindCounts(try parsed("anthropic")), ["paragraph": 33, "heading": 8])
        XCTAssertEqual(kindCounts(try parsed("google")),
                       ["paragraph": 26, "divider": 2, "bullets": 8, "heading": 8])
        XCTAssertEqual(kindCounts(try parsed("techcrunch")), ["paragraph": 19])
        XCTAssertEqual(kindCounts(try parsed("xai")),
                       ["paragraph": 15, "divider": 1, "bullets": 1, "heading": 5])
    }

    func testBlockCountsMatchFixture() throws {
        XCTAssertEqual(try parsed("anthropic").count, 41)
        XCTAssertEqual(try parsed("google").count, 44)
        XCTAssertEqual(try parsed("techcrunch").count, 19)
        XCTAssertEqual(try parsed("xai").count, 22)
    }

    // MARK: - 标题

    func testFirstHeadingKeepsOriginalLevelAndCopy() throws {
        XCTAssertEqual(try firstHeading(try parsed("anthropic")),
                       .heading(level: 2, text: "简单的防御还不够"))
        XCTAssertEqual(try firstHeading(try parsed("google")),
                       .heading(level: 2, text: "解决复杂的工程任务"))
        XCTAssertEqual(try firstHeading(try parsed("xai")),
                       .heading(level: 2, text: "套餐与定价"))
    }

    /// 正文里没有标题就不许凭空造一个（techcrunch 整篇都是段落）。
    func testFixtureWithoutHeadingsYieldsNoHeadingBlock() throws {
        XCTAssertFalse(try parsed("techcrunch").contains(where: isHeading),
                       "techcrunch 正文里没有标题")
    }

    /// level 取标签上的原始数字，渲染层自己决定字号。
    func testHeadingLevelIsTheTagNumber() throws {
        let html = #"<div class="prose"><h3>三级</h3><h6>六级</h6></div>"#
        let blocks = try XCTUnwrap(ReportItemBody.parse(html: html))
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0], .heading(level: 3, text: "三级"))
        XCTAssertEqual(blocks[1], .heading(level: 6, text: "六级"))
    }

    // MARK: - 首段与纯文本

    func testFirstParagraphPlainTextComesFromTheFixture() throws {
        XCTAssertEqual(plain(try parsed("google")[0]), "2026年10月13日")
        XCTAssertEqual(plain(try parsed("xai")[0]),
                       "Grok、Grok Bot、Cursor 和 X Premium，全部包含在一个套餐中。")
        let anthropicFirst = try XCTUnwrap(plain(try parsed("anthropic")[0]))
        XCTAssertTrue(anthropicFirst.hasPrefix(
            "近几个月来，我们在降低蒸馏攻击对 Claude 的有效性方面取得了实质性进展"))
        let techcrunchFirst = try XCTUnwrap(plain(try parsed("techcrunch")[0]))
        XCTAssertTrue(techcrunchFirst.hasPrefix("Character.AI 让用户创建 AI 角色并与它们对话"))
    }

    /// 原文段落里夹着换行与缩进，界面看到的那一行必须是干净的。
    func testWhitespaceInsideParagraphIsCollapsed() throws {
        let text = try XCTUnwrap(plain(try parsed("techcrunch")[0]))
        XCTAssertFalse(text.contains("\n"))
        XCTAssertFalse(text.contains("  "))
        XCTAssertFalse(text.hasPrefix(" "))
        XCTAssertFalse(text.hasSuffix(" "))
    }

    // MARK: - 行内片段

    func testInlineLinkRunsCarryTheHref() throws {
        var linked: ReportItemBody.Run?
        for block in try parsed("anthropic") {
            let runs: [ReportItemBody.Run]
            switch block {
            case .paragraph(let r): runs = r
            case .bullets(let items): runs = items.first ?? []
            default: runs = []
            }
            if let run = runs.first(where: { $0.url != nil }) {
                linked = run
                break
            }
        }
        let run = try XCTUnwrap(linked, "anthropic 正文里认得出链接片段")
        XCTAssertEqual(run.url?.absoluteString,
                       "https://www.anthropic.com/threat-intelligence-report-september-2026"
                       + "#illicit-distillation-sep-26")
        XCTAssertFalse(run.bold)
        XCTAssertFalse(run.text.isEmpty)
    }

    /// 链接与加粗在一段里交替，实体要解码，相邻同样式的片段要合并。
    /// **开标签也是结算点**：锚点前的文字不算链接、加粗前的文字不算粗，
    /// 片段之间的分隔空格必须留住（曾经锚点吞掉前文、空格被裁、整句粘连）。
    func testInlineRunsHandleNestedLinkBoldAndEntities() throws {
        let html = #"<div class="prose"><p>见 <a href="https://x.com/a?b=1&amp;c=2"><b>这里</b></a> 与 <b>结论</b>。</p></div>"#
        let blocks = try XCTUnwrap(ReportItemBody.parse(html: html))
        guard case .paragraph(let runs) = blocks[0] else {
            return XCTFail("第一块不是段落")
        }
        XCTAssertEqual(runs.count, 5)
        XCTAssertEqual(runs[0].text, "见 ")
        XCTAssertNil(runs[0].url)
        XCTAssertFalse(runs[0].bold)
        XCTAssertEqual(runs[1].text, "这里")
        XCTAssertEqual(runs[1].url?.absoluteString, "https://x.com/a?b=1&c=2")
        XCTAssertTrue(runs[1].bold)
        XCTAssertEqual(runs[2].text, " 与 ")
        XCTAssertNil(runs[2].url)
        XCTAssertFalse(runs[2].bold)
        XCTAssertEqual(runs[3].text, "结论")
        XCTAssertNil(runs[3].url)
        XCTAssertTrue(runs[3].bold)
        XCTAssertEqual(runs[4].text, "。")
        XCTAssertNil(runs[4].url)
        XCTAssertFalse(runs[4].bold)
        // 拼回纯文本要与页面可见文字一字不差
        XCTAssertEqual(ReportItemBody.plainText(runs: runs), "见 这里 与 结论。")
    }

    /// 回归：锚点只覆盖锚点自己的文字 —— 修之前「发布 」被吸进链接、
    /// 锚点后的标点又因两端裁剪粘在链接上（google 夹具 42 个锚点几乎每段都这样）。
    func testLinkRunDoesNotAbsorbSurroundingText() {
        let runs = ReportItemBody.inlineRuns(
            #"发布 <a href="https://x.com/a">Gemini 4 Argon</a>，面向复杂任务。"#)
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs[0].text, "发布 ")
        XCTAssertNil(runs[0].url)
        XCTAssertEqual(runs[1].text, "Gemini 4 Argon")
        XCTAssertEqual(runs[1].url?.absoluteString, "https://x.com/a")
        XCTAssertEqual(runs[2].text, "，面向复杂任务。")
        XCTAssertNil(runs[2].url)
    }

    /// 回归（真实夹具）：google 那段以链接开头的正文 —— 链接 run 不吞后面的
    /// 普通文字，分隔空格保留，`&amp;` 在 URL 里解成 `&`。
    func testGoogleLinkRunsExcludeAdjacentPlainText() throws {
        var pinned = false
        for block in try parsed("google") {
            guard case .paragraph(let runs) = block,
                  runs.first?.url?.absoluteString.hasPrefix("https://blog.google/") == true,
                  runs.count > 4 else { continue }
            pinned = true
            XCTAssertEqual(runs[0].text, "Gemini 4 Argon")
            XCTAssertEqual(runs[1].text, " 今日起面向全球开发者与企业开放，可通过 ")
            XCTAssertNil(runs[1].url)
            XCTAssertEqual(runs[2].text, "AI Studio")
            XCTAssertEqual(runs[3].text, " 和 ")
            XCTAssertNil(runs[3].url)
            XCTAssertEqual(runs[4].text, "Gemini 平台")
            XCTAssertTrue(runs[4].url?.absoluteString.hasPrefix(
                "https://console.cloud.google.com/agent-platform/studio/multimodal;mode=prompt"
            ) == true)
            XCTAssertTrue(runs[4].url?.absoluteString.contains("region=global") == true,
                          "`&amp;` 要解成 `&`")
            break
        }
        XCTAssertTrue(pinned, "google 夹具里那段以 Gemini 4 Argon 开头的正文不见了")
    }

    /// 页内锚点（`#footnote-1`）在我们这里没有落点：文字保留，不做成点不开的死链接。
    func testFragmentOnlyHrefIsNotALink() {
        let runs = ReportItemBody.inlineRuns(#"脚注<a href="#footnote-1">1</a>结束"#)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].text, "脚注1结束")
        XCTAssertNil(runs[0].url)
    }

    /// `<br>` 只是排版，折成一个空格，不许把一段劈成两段。
    func testBreakBecomesASpaceInsteadOfSplittingTheRun() {
        let runs = ReportItemBody.inlineRuns("第一行<br>第二行")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].text, "第一行 第二行")
        XCTAssertNil(runs[0].url)
        XCTAssertFalse(runs[0].bold)
    }

    // MARK: - 列表

    func testBulletsKeepTheirItemsAndLinks() throws {
        let googleItems = try XCTUnwrap(firstBullets(try parsed("google")),
                                        "google 正文里没有列表")
        XCTAssertEqual(googleItems.count, 6)
        XCTAssertEqual(ReportItemBody.plainText(runs: googleItems[0]),
                       "为解决你最棘手的问题而打造")
        // 首项本身就是 `<li><a …>`，片段要带着 URL
        XCTAssertEqual(googleItems[0].first?.url?.absoluteString,
                       "https://blog.google/innovation-and-ai/models-and-research/"
                       + "gemini-models/introducing-gemini-4-argon/#builttosolve")

        let xaiItems = try XCTUnwrap(firstBullets(try parsed("xai")), "xai 正文里没有列表")
        XCTAssertEqual(xaiItems.count, 4)
        // 原文是 `<strong>Grok</strong> 支持聊天…` —— 加粗段后面的分隔空格是页面上
        // 的真实文字（旧解析器在 `</strong>` 处裁掉了它，「Grok支持」粘在一起）
        XCTAssertEqual(ReportItemBody.plainText(runs: xaiItems[0]),
                       "Grok 支持聊天、语音以及图像和视频生成。")
        XCTAssertEqual(xaiItems[0].count, 2)
        XCTAssertEqual(xaiItems[0][0].text, "Grok")
        XCTAssertTrue(xaiItems[0][0].bold)
        XCTAssertNil(xaiItems[0][0].url)
        XCTAssertEqual(xaiItems[0][1].text, " 支持聊天、语音以及图像和视频生成。")
        XCTAssertFalse(xaiItems[0][1].bold)
    }

    // MARK: - 顺序

    func testBlockOrderFollowsThePage() throws {
        let googleOrder = try parsed("google").prefix(4).map(kindKey)
        XCTAssertEqual(googleOrder, ["paragraph", "paragraph", "divider", "divider"])
        let xaiOrder = try parsed("xai").prefix(5).map(kindKey)
        XCTAssertEqual(xaiOrder, ["paragraph", "divider", "paragraph", "paragraph", "bullets"])
    }

    // MARK: - 噪声过滤（规则 18：宁可少滤，不可滤错）

    func testUnfilledTemplateAndBareSeparatorAreDropped() throws {
        let google = try parsed("google")
        for block in google {
            guard let text = plain(block) else { continue }
            XCTAssertFalse(text.contains("[["), "留下了没填的模板变量：\(text)")
            XCTAssertNotEqual(text, "|", "留下了纯分隔符那一段")
        }
        // 反过来：站点自己的文案**不**滤 —— 谁家的都认不出来，硬编码就是猜
        XCTAssertTrue(google.contains { self.plain($0) == "收听文章" })
    }

    func testNoiseRulesOnSyntheticPage() throws {
        let html = #"<div class="prose"><p>收听文章</p><p>[[duration]] 分钟</p><p></p><p> </p><p>正文</p></div>"#
        let blocks = try XCTUnwrap(ReportItemBody.parse(html: html))
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.compactMap { self.plain($0) }, ["收听文章", "正文"])
    }

    // MARK: - 认不出正文

    func testMissingProseReturnsNil() {
        XCTAssertNil(ReportItemBody.parse(html: "<html><body><p>hi</p></body></html>"))
        XCTAssertNil(ReportItemBody.parse(html: "<html><body>没有正文</body></html>"))
    }

    func testEmptyOrNoiseOnlyProseReturnsNil() {
        XCTAssertNil(ReportItemBody.parse(html: #"<div class="prose"></div>"#))
        XCTAssertNil(ReportItemBody.parse(html: #"<div class="prose">   </div>"#))
        // 只剩噪声也算「没有正文」
        XCTAssertNil(ReportItemBody.parse(html: #"<div class="prose"><p>[[x]]</p></div>"#))
    }

    /// 正文里嵌着别的 div 不能把片段切断（配平只数 div，别的标签不参与）。
    func testNestedDivDoesNotTruncateTheFragment() throws {
        let html = #"<div class="prose"><div class="x"><p>在嵌套里</p></div><p>外面</p></div>"#
        let blocks = try XCTUnwrap(ReportItemBody.parse(html: html))
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.compactMap { self.plain($0) }, ["在嵌套里", "外面"])
    }

    /// class 可能带修饰（`prose dark:prose-invert`），按词边界认。
    func testProseClassWithModifiersIsStillFound() throws {
        let html = #"<div class="prose dark:prose-invert max-w-none"><p>正文</p></div>"#
        let blocks = try XCTUnwrap(ReportItemBody.parse(html: html))
        XCTAssertEqual(blocks.count, 1)
    }

    // MARK: - 块边界截断

    func testTruncationHappensAtBlockBoundaries() {
        let long = String(repeating: "a", count: 10000)
        let longB = String(repeating: "b", count: 10000)
        let short = String(repeating: "c", count: 100)
        let html = "<div class=\"prose\"><p>\(long)</p><p>\(longB)</p><p>\(short)</p></div>"
        // 10000 + 10000 = 20000 正好不超，第三段才被挡在外面 —— 块边界截断，不切半个段落
        XCTAssertEqual(ReportItemBody.parse(html: html)?.count, 2)
    }

    func testOversizedFirstBlockIsStillReturned() {
        let huge = String(repeating: "a", count: 30000)
        let html = "<div class=\"prose\"><p>\(huge)</p></div>"
        XCTAssertEqual(ReportItemBody.parse(html: html)?.count, 1,
                       "第一段就超限也要给一段 —— 空正文比少几段更糟")
    }

    // MARK: - links.aihot → 条目 id

    /// 与 `StoryID` 同一条纪律：绝不能拿 HTML 地址本身去请求。
    func testItemIdComesFromTheItemLinkPath() throws {
        let data = try Fixture.data("report-weekly-latest", ext: "json")
        let report = try JSONDecoder.aihot.decode(ReportResponse.self, from: data).report

        var checked = 0
        for section in report.sections {
            for item in section.items {
                guard let link = item.links?.aihot else { continue }
                let id = try XCTUnwrap(ReportItemID.id(fromItemLink: link),
                                       "取不到 id 就永远看不到全文：\(link)")
                XCTAssertFalse(id.contains("/"))
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0, "夹具里一条 item 链接都没有")
    }

    /// 路径锚点必须是 `/items/` —— 往期链接形如 `/weekly/2026-W42`，
    /// 末段 8 个字符、全在合法字符集里，只看末段会把期号当成条目 id 发出去。
    func testItemIdRejectsPeriodLinksAndBadCandidates() {
        XCTAssertEqual(ReportItemID.id(fromItemLink: "https://aihot.news/items/smxxtw5ca2c9jscojk4ppe5hf"),
                       "smxxtw5ca2c9jscojk4ppe5hf")
        XCTAssertEqual(ReportItemID.id(fromItemLink: "https://aihot.news/items/cmucwy58v0rskroedmv35n8ji?utm=1#x"),
                       "cmucwy58v0rskroedmv35n8ji")
        XCTAssertEqual(ReportItemID.id(fromItemLink: "https://aihot.virxact.com/items/cmrrjaxlv030jbihklywu3xy6"),
                       "cmrrjaxlv030jbihklywu3xy6", "旧域名也只看路径")
        XCTAssertNil(ReportItemID.id(fromItemLink: "https://aihot.news/weekly/2026-W42"))
        XCTAssertNil(ReportItemID.id(fromItemLink: "https://aihot.news/monthly/2026-09"))
        XCTAssertNil(ReportItemID.id(fromItemLink: "https://aihot.news/items/short"))
        XCTAssertNil(ReportItemID.id(fromItemLink: nil))
        XCTAssertNil(ReportItemID.id(fromItemLink: ""))
    }
}
