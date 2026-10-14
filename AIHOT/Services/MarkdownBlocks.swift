import Foundation

/// 一条 AI 回答里的 Markdown 切成块 —— 气泡按块排版（标题、列表、代码块…），
/// 而不是把整段丢给 `AttributedString` 的行内解析器、看着 `#` 与 ``` 原样吐出来。
///
/// 纯函数、无 IO：和 `ReportTimeline` 同一类。XCTest 与 Python 镜像
/// （`tools/logic_tests.py`「镜像 16」）读同一份夹具 `AIHOTTests/Fixtures/chat-markdown.md`。
///
/// **刻意不是完整 CommonMark** —— 只认模型回答里真实出现的形态，规则从简：
/// 宁可漏渲染（退回原样显示，和以前一样），也不渲染错（错会把正文藏进错的容器里）。
/// 已知取舍：
///
/// - 代码块只认 ``` 围栏（不认 ~~~ 与四空格缩进：缩进代码和嵌套列表没法区分）；
///   **没闭合的围栏算到文末** —— 回答被截断时，后面的正文顶多变成等宽字，不会消失；
/// - 标题只认 ATX（`#` 后必须有空格），不认 Setext（`===` / `---` 下划线）：
///   `---` 单独一行一律按分隔线画；
/// - 列表的续行**只吃缩进行**，顶格新行直接断开列表另起段落（模型忘写空行时
///   另起一段比 CommonMark 的懒惰续行更不容易吃掉正文）；
/// - 引用只剥一层 `>`，不递归分块（`> - 项目` 里的项目符号原样显示）；
/// - 表格要求表头以 `|` 开头、分隔行含 `|`（模型都这么写；也避免「a | b」
///   下一行「---」被当成表格）。列数以表头为准：残缺行补空、多出的截掉；
/// - 块不嵌套进列表/引用里（列表中间的代码块会被提到外层）。
enum MarkdownBlock: Equatable {
    /// 整段原文（可能多行）。行内格式（**加粗** / `代码` / [链接](…)）
    /// 由渲染层用 Foundation 的 inline 解析处理，这里只管块的边界。
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String, body: String)
    case list(items: [Item])
    case quote(String)
    case rule
    case table(header: [String], rows: [[String]])

    struct Item: Equatable {
        /// 缩进层级：源码缩进 ÷ 2，封顶 3（气泡就那么宽，再深正文就没了）
        let level: Int
        /// 有序项要显示的序号；无序项为 nil（画「•」）
        let number: Int?
        let text: String
    }
}

enum MarkdownBlocks {

    static func parse(_ text: String) -> [MarkdownBlock] {
        // \r\n（中转站/复制粘贴都可能出现）：行尾的 \r 剥掉，不然围栏识别会失灵
        let lines = text.components(separatedBy: "\n").map {
            $0.hasSuffix("\r") ? String($0.dropLast()) : $0
        }

        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var items: [MarkdownBlock.Item] = []
        var quoteLines: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined("\n")))
            paragraph.removeAll()
        }
        func flushList() {
            guard !items.isEmpty else { return }
            blocks.append(.list(items: items))
            items.removeAll()
        }
        func flushQuote() {
            guard !quoteLines.isEmpty else { return }
            blocks.append(.quote(quoteLines.joined("\n")))
            quoteLines.removeAll()
        }
        func flushAll() {
            flushParagraph()
            flushList()
            flushQuote()
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 空行：当前挂着的块全部收尾
            if trimmed.isEmpty {
                flushAll()
                index += 1
                continue
            }

            // 1) 围栏代码块
            if trimmed.hasPrefix("```") {
                flushAll()
                let info = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let language = info
                    .split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .first.map(String.init) ?? ""
                var body: [String] = []
                index += 1
                while index < lines.count {
                    let inner = lines[index].trimmingCharacters(in: .whitespaces)
                    let afterMarker = inner.dropFirst(3)
                    let isClosingFence = inner.hasPrefix("```")
                        && afterMarker.allSatisfy({ $0 == " " || $0 == "\t" })
                    if isClosingFence {
                        index += 1
                        break
                    }
                    body.append(lines[index])
                    index += 1
                }
                // 没有收尾围栏（回答被截断是常态）也不再往下找：到文末都是代码
                let code = body.joined("\n").trimmingCharacters(in: .newlines)
                blocks.append(.code(language: language, body: code))
                continue
            }

            // 2) ATX 标题
            if let heading = headingMatch(in: line) {
                flushAll()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            // 3) 分隔线（`---` / `***` / `___`）
            if isRule(trimmed) {
                flushAll()
                blocks.append(.rule)
                index += 1
                continue
            }

            // 4) 引用：连续的 `>` 行合成一块
            if let content = quoteContent(in: line) {
                flushParagraph()
                flushList()
                quoteLines.append(content)
                index += 1
                continue
            }
            // 非 `>` 行把引用断开（引用不懒惰续行）
            flushQuote()

            // 5) 表格：表头以 | 开头，且下一行是分隔行
            if trimmed.hasPrefix("|"),
               index + 1 < lines.count,
               isTableSeparator(lines[index + 1]) {
                flushAll()
                let header = tableCells(trimmed)
                index += 2
                var rows: [[String]] = []
                while index < lines.count, lines[index].contains("|") {
                    rows.append(tableCells(lines[index].trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                // 列数以表头为准：残缺行补空、多出的截掉，不让一行歪数据把整表挤乱
                let width = header.count
                rows = rows.map { row in
                    if row.count >= width { return Array(row.prefix(width)) }
                    return row + Array(repeating: "", count: width - row.count)
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // 6) 列表项
            if let item = listItem(in: line) {
                flushParagraph()
                // 有序号连排时重编：源码写「1. 1. 1.」→ 显示 1、2、3；
                // 第一项用源码给的号（「3.」开头就从 3 起），中间隔着无序项则重新从源码号起
                var resolved = item
                if item.number != nil,
                   let previous = items.last,
                   let previousNumber = previous.number {
                    resolved = MarkdownBlock.Item(
                        level: item.level,
                        number: previousNumber + 1,
                        text: item.text
                    )
                }
                items.append(resolved)
                index += 1
                continue
            }

            // 7) 列表续行：列表还开着 + 有缩进 → 并进最后一项（只吃缩进行）
            if !items.isEmpty && (line.hasPrefix(" ") || line.hasPrefix("\t")) {
                flushParagraph()
                if let previous = items.popLast() {
                    items.append(MarkdownBlock.Item(
                        level: previous.level,
                        number: previous.number,
                        text: previous.text + "\n" + line
                    ))
                }
                index += 1
                continue
            }

            // 8) 顶格新行断开列表，另起段落
            flushList()

            // 9) 段落
            paragraph.append(line)
            index += 1
        }

        flushAll()
        return blocks
    }

    // MARK: - 各类块的识别

    private struct HeadingMatch {
        let level: Int
        let text: String
    }

    /// `## 标题`：1–6 个 `#`、后面必须有空格；行尾允许收尾的 `#` 序列（`## 标题 ##`）。
    /// `#标题`（没空格）不是标题，原样留在段落里。
    private static func headingMatch(in line: String) -> HeadingMatch? {
        let pattern = #"^ {0,3}(#{1,6})[ \t]+(.*?)(?:[ \t]+#+[ \t]*)?$"#
        guard let result = RegexUtil.firstMatch(pattern, in: line),
              let hashes = RegexUtil.group(result, at: 1, in: line) else { return nil }
        // group 2 允许为空（`# ` 这种空标题）—— RegexUtil.group 对空串返回 nil，这里直接取
        let text = (line as NSString).substring(with: result.range(at: 2))
        return HeadingMatch(level: hashes.count, text: text)
    }

    private static func isRule(_ trimmed: String) -> Bool {
        RegexUtil.firstMatch(#"^(-{3,}|\*{3,}|_{3,})$"#, in: trimmed) != nil
    }

    /// 行首 ≤3 个空格后的 `>`；剥掉 `>` 和紧随的一个空格。
    private static func quoteContent(in line: String) -> String? {
        guard let result = RegexUtil.firstMatch(#"^ {0,3}>(.*)$"#, in: line) else { return nil }
        var content = (line as NSString).substring(with: result.range(at: 1))
        if content.hasPrefix(" ") { content.removeFirst() }
        return content
    }

    /// 表格分隔行：含 `|` 和 `-`，去掉 `|` 与 `:` 后只剩空白与 `-`（对齐标记 :---: 也算）。
    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), trimmed.contains("-") else { return false }
        let stripped = trimmed
            .replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: ":", with: "")
        return !stripped.isEmpty
            && stripped.allSatisfy { $0 == " " || $0 == "\t" || $0 == "-" }
    }

    private static func tableCells(_ line: String) -> [String] {
        var body = line
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// `- 项目` / `1. 项目` / `1) 项目`（允许前导缩进）。
    private static func listItem(in line: String) -> MarkdownBlock.Item? {
        let pattern = #"^([ \t]*)([-*+]|\d{1,9}[.)])[ \t]+(.*)$"#
        guard let result = RegexUtil.firstMatch(pattern, in: line) else { return nil }
        // 三个 group 都可能为空串（缩进/正文），RegexUtil.group 对空串返回 nil，逐个直取
        let ns = line as NSString
        let indent = ns.substring(with: result.range(at: 1))
        let marker = ns.substring(with: result.range(at: 2))
        let text = ns.substring(with: result.range(at: 3))
        let level = min(
            indent.map { $0 == "\t" ? 4 : 1 }.reduce(0, +) / 2,
            3
        )
        let number: Int? = marker.first?.isNumber == true
            ? Int(marker.dropLast(1))
            : nil
        return MarkdownBlock.Item(level: level, number: number, text: text)
    }
}
