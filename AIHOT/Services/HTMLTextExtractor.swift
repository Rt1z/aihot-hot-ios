import Foundation

/// 极简正则工具（避免为了几行匹配引入第三方依赖）。
enum RegexUtil {

    static func fullRange(_ text: String) -> NSRange {
        NSRange(location: 0, length: (text as NSString).length)
    }

    static func matches(
        _ pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        return regex.matches(in: text, options: [], range: fullRange(text))
    }

    static func firstMatch(
        _ pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> NSTextCheckingResult? {
        matches(pattern, in: text, options: options).first
    }

    static func replace(
        _ pattern: String,
        in text: String,
        with template: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: fullRange(text),
            withTemplate: template
        )
    }

    static func group(_ result: NSTextCheckingResult, at index: Int, in text: String) -> String? {
        guard index < result.numberOfRanges else { return nil }
        let range = result.range(at: index)
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        return (text as NSString).substring(with: range)
    }
}

/// 把 HTML 压成「一行一段可见文字」的纯文本。
///
/// 这是给「网页文本增强」用的降级方案：只依赖**可见文案**，不依赖 class 名，
/// 所以官网换皮（Tailwind 类名重排、组件重构）一般不会失效。
enum HTMLTextExtractor {

    static func plainText(from html: String) -> String {
        var text = html
        text = stripElement(text, tag: "script")
        text = stripElement(text, tag: "style")
        text = stripElement(text, tag: "noscript")
        text = stripElement(text, tag: "svg")
        text = stripElement(text, tag: "template")

        // 注释
        text = RegexUtil.replace("<!--.*?-->", in: text, with: "\n", options: [.dotMatchesLineSeparators])

        // 源码里的换行与缩进只是排版，不是语义换行：真实页面里
        // `<span>爆</span>` 和 `<span>↑ 629%</span>` 之间是有换行的，
        // 若照搬成断行，徽章就被拆到两行，涨跌会整块丢失。
        // 所以先整体折叠成单个空格，之后只由块级标签决定在哪里断行。
        text = RegexUtil.replace("\\s+", in: text, with: " ", options: [])

        // 块级标签的结束位置换成换行，保留「一行一段」的结构
        text = RegexUtil.replace(
            "<(br|/p|/div|/li|/ul|/ol|/dl|/dd|/h[1-6]|/section|/article|/header|/footer|/tr|/td|/th|/table|/main|/nav|/aside|/head|/title|/body|/html|/figure|/figcaption|/blockquote|/pre|/form|/time)[^>]*>",
            in: text,
            with: "\n",
            options: [.caseInsensitive]
        )

        // 剩下的标签丢掉，用一个空格占位，避免把相邻文字粘成一个词
        text = RegexUtil.replace("<[^>]*>", in: text, with: " ", options: [])

        text = decodeEntities(text)
        return normalize(text)
    }

    static func stripElement(_ html: String, tag: String) -> String {
        // 结束标签必须是 "</\(tag)>"。这里曾经多写了一个反斜杠
        // （"</\\(tag)>"），运行时模式就成了 "</" + \s（空白）
        // + "cript>"，永远匹配不到 —— script/style 于是从来没被剔除过。
        // 注意别照着开头 "<\(tag)\\b" 的样子，把这里也写成两个反斜杠。
        let pattern = "<\(tag)\\b[^>]*>.*?</\(tag)>"
        return RegexUtil.replace(
            pattern,
            in: html,
            with: "\n",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
    }

    static func decodeEntities(_ input: String) -> String {
        var text = input

        // 先解数字实体（倒序替换，避免下标错位）
        let numeric = RegexUtil.matches("&#(x?)([0-9A-Fa-f]+);", in: text)
        if !numeric.isEmpty {
            var working: NSString = text as NSString
            for result in numeric.reversed() {
                let isHex = !(RegexUtil.group(result, at: 1, in: text) ?? "").isEmpty
                guard let digits = RegexUtil.group(result, at: 2, in: text) else { continue }
                let value = isHex ? UInt32(digits, radix: 16) : UInt32(digits, radix: 10)
                guard let scalarValue = value, let scalar = Unicode.Scalar(scalarValue) else { continue }
                working = working.replacingCharacters(in: result.range, with: String(Character(scalar))) as NSString
            }
            text = working as String
        }

        let named: [String: String] = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&middot;": "·",
            "&hellip;": "…",
            "&mdash;": "—",
            "&ndash;": "–",
            "&times;": "×",
            "&laquo;": "«",
            "&raquo;": "»"
        ]
        for (entity, replacement) in named {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text
    }

    /// 每行去空白、丢掉空行，行间用一个换行连接。
    static func normalize(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
