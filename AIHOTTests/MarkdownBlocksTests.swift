import XCTest
@testable import AIHOT

/// `MarkdownBlocks.parse` 的用例。主夹具 `chat-markdown.md` 覆盖模型回答里
/// 真实会出现的全部块型；Python 镜像（`tools/logic_tests.py`「镜像 16」）
/// 读同一份文件。断言全部从夹具内容本身推导。
final class MarkdownBlocksTests: XCTestCase {

    func testFixtureParsesIntoTheExpectedBlocks() throws {
        let text = try Fixture.text("chat-markdown", ext: "md")
        let blocks = MarkdownBlocks.parse(text)

        XCTAssertEqual(
            blocks.count, 9,
            "夹具应切出 9 块：标题/段落/无序列表/有序列表/代码/引用/分隔线/表格/段落"
        )

        XCTAssertEqual(blocks[0], .heading(level: 2, text: "这条为什么火"))

        XCTAssertEqual(
            blocks[1],
            .paragraph("先看**三个信号**，再看 `热度指数` 的变化：")
        )

        // 第三项缩进 2 空格 → 层级 1；行内标记在块内原样保留，交给渲染层的 inline 解析
        XCTAssertEqual(
            blocks[2],
            .list(items: [
                MarkdownBlock.Item(
                    level: 0, number: nil,
                    text: "厂商放出了[实测数据](https://example.com/demo)"
                ),
                MarkdownBlock.Item(level: 0, number: nil, text: "社区在两天内跟进了 40+ 条讨论"),
                MarkdownBlock.Item(level: 1, number: nil, text: "其中一半来自官方论坛"),
                MarkdownBlock.Item(level: 0, number: nil, text: "没有出现反转报道"),
            ])
        )

        // 三个「1.」连排被重编成 1、2、3
        XCTAssertEqual(
            blocks[3],
            .list(items: [
                MarkdownBlock.Item(level: 0, number: 1, text: "先看发布时间"),
                MarkdownBlock.Item(level: 0, number: 2, text: "再看来源数量"),
                MarkdownBlock.Item(level: 0, number: 3, text: "最后看有没有后续"),
            ])
        )

        XCTAssertEqual(
            blocks[4],
            .code(
                language: "python",
                body: "def heat(rank):\n    # 没有热度指数时退回参与者数\n    return rank or 0"
            )
        )

        XCTAssertEqual(
            blocks[5],
            .quote("引用一段：热度按 60 秒缓存，**不重复请求**。")
        )

        XCTAssertEqual(blocks[6], .rule)

        // 分隔行带对齐标记（:---:）也是分隔行；对齐本身不渲染（一律左对齐，取舍见文件头）
        XCTAssertEqual(
            blocks[7],
            .table(
                header: ["来源", "参与者", "走向"],
                rows: [
                    ["官方博客", "12", "↑"],
                    ["社区讨论", "30", "持平"],
                ]
            )
        )

        XCTAssertEqual(blocks[8], .paragraph("结论：**别只看名次**，报道节奏更诚实。"))
    }

    func testEmptyInputMakesNoBlocks() {
        XCTAssertEqual(MarkdownBlocks.parse(""), [])
        XCTAssertEqual(MarkdownBlocks.parse("\n\n  \n"), [])
    }

    /// 没闭合的围栏（回答被截断是常态）：到文末都算代码 —— 宁可后面的内容变成等宽字，
    /// 也不能让一个悬着的 ``` 把后面的正文吞掉或者原样吐出来。
    func testUnterminatedFenceBecomesCodeToTheEnd() {
        XCTAssertEqual(
            MarkdownBlocks.parse("```swift\nlet a = 1"),
            [.code(language: "swift", body: "let a = 1")]
        )
    }

    /// `#` 后必须有空格才是标题；收尾的 `#` 序列只在前面有空格时才剥（`C#` 不能被啃掉）
    func testHeadingNeedsSpaceAndKeepsTrailingHashInWord() {
        XCTAssertEqual(MarkdownBlocks.parse("#标题"), [.paragraph("#标题")])
        XCTAssertEqual(MarkdownBlocks.parse("## 标题 ##"), [.heading(level: 2, text: "标题")])
        XCTAssertEqual(MarkdownBlocks.parse("# 语言是 C#"), [.heading(level: 1, text: "语言是 C#")])
        XCTAssertEqual(MarkdownBlocks.parse("####### 七个井号"), [.paragraph("####### 七个井号")])
    }

    /// 有序号：第一项用源码号起头；被无序项隔开的有序项重新从源码号起
    ///（连排重编由夹具里「三个 1. → 1、2、3」钉住）
    func testOrderedNumberResetsAfterUnorderedItem() {
        XCTAssertEqual(
            MarkdownBlocks.parse("3. 甲\n4. 乙"),
            [.list(items: [
                MarkdownBlock.Item(level: 0, number: 3, text: "甲"),
                MarkdownBlock.Item(level: 0, number: 4, text: "乙"),
            ])]
        )
        XCTAssertEqual(
            MarkdownBlocks.parse("1. 甲\n- 乙\n1. 丙"),
            [.list(items: [
                MarkdownBlock.Item(level: 0, number: 1, text: "甲"),
                MarkdownBlock.Item(level: 0, number: nil, text: "乙"),
                MarkdownBlock.Item(level: 0, number: 1, text: "丙"),
            ])]
        )
    }

    /// 列表续行只吃缩进行；顶格新行断开列表、另起段落
    func testListContinuationOnlyEatsIndentedLines() {
        XCTAssertEqual(
            MarkdownBlocks.parse("- 甲\n  续行\n- 乙"),
            [.list(items: [
                MarkdownBlock.Item(level: 0, number: nil, text: "甲\n  续行"),
                MarkdownBlock.Item(level: 0, number: nil, text: "乙"),
            ])]
        )
        XCTAssertEqual(
            MarkdownBlocks.parse("- 甲\n顶格"),
            [
                .list(items: [MarkdownBlock.Item(level: 0, number: nil, text: "甲")]),
                .paragraph("顶格"),
            ]
        )
    }

    /// `---` 单独一行是分隔线（Setext 下划线不认）；连续引用行合并、空引用行保留
    func testRuleVersusSetextAndQuoteLineJoining() {
        XCTAssertEqual(
            MarkdownBlocks.parse("一段\n---"),
            [.paragraph("一段"), .rule]
        )
        XCTAssertEqual(
            MarkdownBlocks.parse("> 甲\n>\n> 乙"),
            [.quote("甲\n\n乙")]
        )
    }

    /// 表格要求表头以 | 开头（否则「a | b」+「---」会被当成表格）；
    /// 残缺行按表头列数补空、多出的截掉
    func testTableNeedsLeadingPipeAndNormalizesRowWidth() {
        XCTAssertEqual(
            MarkdownBlocks.parse("a | b\n---"),
            [.paragraph("a | b"), .rule]
        )
        XCTAssertEqual(
            MarkdownBlocks.parse("| a | b |\n| - | - |\n| 1 |\n| 1 | 2 | 3 |"),
            [.table(
                header: ["a", "b"],
                rows: [["1", ""], ["1", "2"]]
            )]
        )
    }

    /// ~~ 围栏不认（取舍写在 MarkdownBlocks 文件头）；行首星号不是列表
    func testTildeFenceAndEmphasisStayParagraphs() {
        XCTAssertEqual(
            MarkdownBlocks.parse("~~~\n代码"),
            [.paragraph("~~~\n代码")]
        )
        XCTAssertEqual(
            MarkdownBlocks.parse("*强调* 一行"),
            [.paragraph("*强调* 一行")]
        )
    }
}
