import Foundation

/// `links.aihot` 这个「给人看的 HTML 地址」→ `/items/{id}` 里的那个 id。
///
/// 与 `StoryID` 同一条纪律：**绝不直接拿 HTML 地址去当接口请求**。
/// 但比 `StoryID` 多一道**路径锚点** —— 条目链接固定是 `/items/{id}`，
/// 而往期的 `links.aihot` 形如 `/weekly/2026-W42`（8 个字符、全在合法字符集里），
/// 只看末段会把期号当成条目 id 发出去。所以必须先认出 `items` 这一段。
enum ReportItemID {

    /// 至少这么长才认为是合法 id（实测是 22 位小写字母数字）。
    private static let minimumLength = 8

    static func id(fromItemLink link: String?) -> String? {
        guard let link = link, !link.isEmpty else { return nil }
        guard let url = URL(string: link) else { return nil }

        // query / fragment 由 URL 自动剥离
        let segments = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard segments.count >= 2 else { return nil }
        guard segments[segments.count - 2].lowercased() == "items" else { return nil }

        let candidate = (segments.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.count >= minimumLength else { return nil }
        guard candidate.lowercased() != "items" else { return nil }

        // 只允许 id 里常见的字符，避免把奇怪的路径段拼进请求
        let allowed = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_.")
        guard candidate.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }

        return candidate
    }
}

/// 周报/月报条目站内页（`/items/{id}`）的**正文**解析。
///
/// 与 `HotPageEnricher` / `LeaderboardParser` 同属「从网页抽数据」那一类，
/// 但锚点纪律不一样：正文整段住在 `<div class="prose">` 里，这是**唯一的**
/// 定位标记（React Router SSR，没有 `__NEXT_DATA__`，结构化载荷是 turbo-stream，
/// 在 Swift 里解不动）。所以这里锚的就是这一个 class —— 改版风险由四份 2026-10-21
/// 的真实抓取夹具钉住（`report-item-google/xai/techcrunch/anthropic.html`），
/// 改版时测试会红、一眼可见。
///
/// **纯函数**：不读 `Date()`、不碰网络/磁盘，同一份字节永远得到同一组块，
/// 由 Swift 用例与 `tools/logic_tests.py` 的镜像 20 双向钉住（规则 4：Swift 是权威）。
enum ReportItemBody {

    /// 一条行内片段。`url` 只在 `<a href>` 里有、`bold` 只在 `<b>/<strong>` 里为真 ——
    /// 两者都可能在一段里交替出现，所以是 runs 而不是「一段一个样式」。
    struct Run: Equatable, Hashable {
        let text: String
        let url: URL?
        let bold: Bool
    }

    enum Block: Equatable, Hashable {
        /// `h2`–`h6`；level 是原始数字（h2 → 2），渲染层自己决定字号
        case heading(level: Int, text: String)
        case paragraph([Run])
        /// 无序或有序列表；每项是一串行内片段（`<li>` 里也常有链接与加粗）
        case bullets([[Run]])
        /// `<hr>`；原文里的分节线，留着才有「这一段结束了」的信息
        case divider
    }

    /// 正文动辄上万字符（实测夹具 7k–11k），全部展开既不好读也没必要。
    /// 在**块边界**截断：宁可少显示几段，也不要把一段拦腰切开。
    static let maximumCharacters = 20000

    /// 从整页 HTML 里取出正文块；认不出正文（没有 `<div class="prose">`）
    /// 返回 nil —— 上层退回「AI 导读 + 打开原文」那一版，不显示半个页面。
    static func parse(html: String) -> [Block]? {
        guard let fragment = proseFragment(of: html) else { return nil }
        var blocks: [Block] = []
        var total = 0

        for chunk in blockChunks(in: fragment) {
            guard let block = makeBlock(chunk) else { continue }
            let cost = blockCost(block)
            // 第一段就超限也要给一段 —— 空正文比少几段更糟
            if total > 0, total + cost > maximumCharacters { break }
            blocks.append(block)
            total += cost
        }
        return blocks.isEmpty ? nil : blocks
    }

    // MARK: - 正文区域

    /// 取 `<div class="prose">` 到**配平**的 `</div>` 之间的内容。
    ///
    /// 用扫描而不是正则：正文里嵌着 `<a href="…?x=1&y=2">` 之类的属性，
    /// 贪婪/非贪婪正则都会在嵌套 div 上出错，而这里是唯一不能出错的一步。
    private static func proseFragment(of html: String) -> String? {
        // class 可能带修饰（"prose"、"prose dark:prose-invert"），按词边界认
        let pattern = #"<div[^>]*\bclass\s*=\s*["'][^"']*\bprose\b[^"']*["'][^>]*>"#
        guard let match = RegexUtil.firstMatch(pattern, in: html, options: [.caseInsensitive]),
              let openRange = Range(match.range, in: html) else { return nil }

        var depth = 1
        var cursor = openRange.upperBound
        while cursor < html.endIndex,
              let lt = html[cursor...].firstIndex(of: "<") {
            let tagEnd = html[lt...].firstIndex(of: ">") ?? html.endIndex
            let name = tagName(from: html[lt..<tagEnd])
            // 只数 div：正文里出现别的标签不该影响配平
            if name == "div" {
                let isClosing = html.index(after: lt) < html.endIndex && html[html.index(after: lt)] == "/"
                depth += isClosing ? -1 : 1
                if depth == 0 {
                    return String(html[openRange.upperBound..<lt])
                }
            }
            cursor = tagEnd < html.endIndex ? html.index(after: tagEnd) : html.endIndex
        }
        return nil
    }

    // MARK: - 块切分

    /// 把正文切成「块级标签 → 内容」的片段。**只认块级标签**，
    /// 其余（含嵌在正文里的 div）一律跳过 —— 宁可少抽，不可抽错。
    private static let containerTags: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "blockquote", "pre"]

    private struct Chunk {
        let tag: String
        let inner: String
    }

    private static func blockChunks(in fragment: String) -> [Chunk] {
        var chunks: [Chunk] = []
        var cursor = fragment.startIndex

        while cursor < fragment.endIndex,
              let lt = fragment[cursor...].firstIndex(of: "<") {
            let gt = fragment[lt...].firstIndex(of: ">") ?? fragment.endIndex
            let raw = fragment[lt..<gt]
            let name = tagName(from: raw)
            let after = gt < fragment.endIndex ? fragment.index(after: gt) : fragment.endIndex

            if name == "hr" {
                // 自闭合的分节线，没有内容
                chunks.append(Chunk(tag: "hr", inner: ""))
                cursor = after
                continue
            }

            guard containerTags.contains(name), !isClosing(raw) else {
                cursor = after
                continue
            }

            // 找同名闭合标签（同名嵌套要配平）
            guard let end = matchingClose(of: name, in: fragment, from: after) else {
                cursor = after
                continue
            }
            chunks.append(Chunk(tag: name, inner: String(fragment[after..<end])))
            cursor = end < fragment.endIndex ? fragment.index(after: end) : fragment.endIndex
        }
        return chunks
    }

    /// 从 `from` 开始找 `</tag>`，按同名开标签计数配平。找不到返回 nil。
    private static func matchingClose(of tag: String, in text: String, from: String.Index) -> String.Index? {
        var depth = 1
        var cursor = from
        while cursor < text.endIndex,
              let lt = text[cursor...].firstIndex(of: "<") {
            let gt = text[lt...].firstIndex(of: ">") ?? text.endIndex
            let raw = text[lt..<gt]
            let name = tagName(from: raw)
            if name == tag {
                if isClosing(raw) {
                    depth -= 1
                    if depth == 0 { return lt }
                } else {
                    depth += 1
                }
            }
            cursor = gt < text.endIndex ? text.index(after: gt) : text.endIndex
        }
        return nil
    }

    private static func makeBlock(_ chunk: Chunk) -> Block? {
        switch chunk.tag {
        case "hr":
            return .divider
        case "ul", "ol":
            let items = listItems(in: chunk.inner).filter { !isNoise(plainText(runs: $0)) }
            return items.isEmpty ? nil : .bullets(items)
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let text = plainText(runs: inlineRuns(chunk.inner))
            guard !isNoise(text) else { return nil }
            return .heading(level: Int(chunk.tag.dropFirst()) ?? 2, text: text)
        default:
            let runs = inlineRuns(chunk.inner)
            let text = plainText(runs: runs)
            guard !isNoise(text) else { return nil }
            return .paragraph(runs)
        }
    }

    /// `<li>` 之间切开，每一项再按行内格式解析。
    private static func listItems(in html: String) -> [[Run]] {
        var items: [[Run]] = []
        var cursor = html.startIndex
        while cursor < html.endIndex,
              let lt = html[cursor...].firstIndex(of: "<") {
            let gt = html[lt...].firstIndex(of: ">") ?? html.endIndex
            let raw = html[lt..<gt]
            let after = gt < html.endIndex ? html.index(after: gt) : html.endIndex
            guard tagName(from: raw) == "li", !isClosing(raw),
                  let end = matchingClose(of: "li", in: html, from: after) else {
                cursor = after
                continue
            }
            let runs = inlineRuns(String(html[after..<end]))
            if !plainText(runs: runs).isEmpty {
                items.append(runs)
            }
            cursor = end < html.endIndex ? html.index(after: end) : html.endIndex
        }
        return items
    }

    // MARK: - 行内片段

    /// 一趟扫描，用一个栈记录「现在在不在 `<a>` / `<strong>` 里」。
    /// 文本与标签交替出现，所以按「遇到标签就结算前面那段纯文本」来切。
    static func inlineRuns(_ html: String) -> [Run] {
        var runs: [Run] = []
        var url: URL? = nil
        var boldDepth = 0
        var plain = ""

        func flush() {
            let text = collapseSpaces(HTMLTextExtractor.decodeEntities(plain))
            plain = ""
            guard !text.isEmpty else { return }
            // 合并相邻且样式相同的片段：`<p>a<b>b</b>c</p>` 里的 a 和 c 各自成段，
            // 但 `</b>` 之后紧跟的纯文本与前一段同样式时会被下一轮 flush 各自成段 —— 无害
            if let last = runs.last, last.url == url, last.bold == (boldDepth > 0) {
                runs[runs.count - 1] = Run(text: last.text + text, url: last.url, bold: last.bold)
            } else {
                runs.append(Run(text: text, url: url, bold: boldDepth > 0))
            }
        }

        var cursor = html.startIndex
        while cursor < html.endIndex, let lt = html[cursor...].firstIndex(of: "<") {
            plain += String(html[cursor..<lt])
            let gt = html[lt...].firstIndex(of: ">") ?? html.endIndex
            let raw = html[lt..<gt]
            let name = tagName(from: raw)
            let isClose = isClosing(raw)

            switch name {
            case "a":
                if isClose {
                    flush()
                    url = nil
                } else {
                    url = href(from: raw)
                }
            case "b", "strong":
                if isClose {
                    flush()
                    boldDepth = max(0, boldDepth - 1)
                } else {
                    boldDepth += 1
                }
            case "br", "sup", "sub":
                // 硬换行只是排版；上下标保留文字（脚注编号要能看见）
                if name == "br" { plain += " " }
            default:
                break
            }
            cursor = gt < html.endIndex ? html.index(after: gt) : html.endIndex
        }
        plain += String(html[cursor...])
        flush()
        return runs
    }

    // MARK: - 文本

    /// 一组片段拼成纯文本（标题用）。
    static func plainText(runs: [Run]) -> String {
        collapseSpaces(runs.map(\.text).joined())
    }

    /// 这段文本是不是**站点自己的残留**而不是文章内容。只有三种确定的形态：
    /// 全空；一个字母数字都没有（`<p><span>|</span></p>` 这种纯分隔符）；
    /// 模板变量没被填上（`[[duration]] 分钟`）。三条都是**通用信号**，
    /// 不照着某一家的中文文案写死 —— 宁可少滤，不可滤错，所以「收听文章」
    /// 这类站点文案仍然会留下（谁家的都认不出来，硬编码就是猜）。
    private static func isNoise(_ text: String) -> Bool {
        if text.isEmpty { return true }
        if !text.contains(where: { $0.isLetter || $0.isNumber }) { return true }
        return text.contains("[[") && text.contains("]]")
    }

    private static func blockCost(_ block: Block) -> Int {
        switch block {
        case .heading(_, let text): return text.count
        case .paragraph(let runs): return plainText(runs: runs).count
        case .bullets(let items): return items.reduce(0) { $0 + plainText(runs: $1).count }
        case .divider: return 0
        }
    }

    // MARK: - 标签工具

    /// `"<a href=…>"` / `"</a>"` / `"<br/>"` → `"a"` / `"a"` / `"br"`。
    private static func tagName(from raw: Substring) -> String {
        var i = raw.startIndex
        guard i < raw.endIndex, raw[i] == "<" else { return "" }
        i = raw.index(after: i)
        if i < raw.endIndex, raw[i] == "/" { i = raw.index(after: i) }
        while i < raw.endIndex, raw[i].isWhitespace { i = raw.index(after: i) }
        let start = i
        while i < raw.endIndex, raw[i].isLetter || raw[i].isNumber { i = raw.index(after: i) }
        return String(raw[start..<i]).lowercased()
    }

    private static func isClosing(_ raw: Substring) -> Bool {
        raw.count > 1 && raw[raw.index(after: raw.startIndex)] == "/"
    }

    private static func href(from raw: Substring) -> URL? {
        guard let match = RegexUtil.firstMatch(
            #"href\s*=\s*["']([^"']+)["']"#,
            in: String(raw),
            options: [.caseInsensitive]
        ), let value = RegexUtil.group(match, at: 1, in: String(raw)) else { return nil }
        return URL(string: HTMLTextExtractor.decodeEntities(value))
    }

    private static func collapseSpaces(_ text: String) -> String {
        RegexUtil.replace(#"\s+"#, in: text, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
