import Foundation

/// 「AI 点评」的提示词（纯函数）。
///
/// 纪律只有一条：**它是教练，不是代笔**。所以提示词里写死了四件事 ——
/// 覆盖度、准确性、一个追问、不重写不夸奖；并且材料只有导读时必须明说，
/// 不许假装看过全文（同「不编造数字」那条规则）。
///
/// 不读 `Date()`、不碰网络/磁盘；单测与 `tools/logic_tests.py` 的镜像 23 两边钉住。
enum PracticeReviewPrompt {

    /// 送给模型的文章材料上限。全文实测 7k–11k 字符，不截断会显著拉高成本与延迟；
    /// 8k 足够判断「有没有漏掉关键点」，也不至于把一次点评变成一篇长文生成。
    static let maximumArticleCharacters = 8000

    struct Built: Equatable {
        let system: String
        let user: String
        /// 「全文」或「导读」—— 要一起存进点评快照。
        let basis: String
    }

    static let system = """
    你是一位严格、克制的写作教练，正在批改用户读完一篇文章后写的归纳总结。只做四件事：

    1. 覆盖度：从文章材料里提炼 3–6 个关键点，逐条标注「你写了」或「你没写」。
    2. 准确性：逐条指出总结里没有材料支撑的说法；确实没有就写「没有发现编造」。
    3. 一个追问：针对总结里最薄弱的一处，提一个具体、可回答的问题。
    4. 全文用中文和 Markdown，控制在 400 字以内。

    禁止：重写或润色用户的总结、打分、泛泛夸奖、编造材料里没有的事实。
    如果材料类型标注为「导读」，你只能看到导读，必须明说这一点，不要假装看过全文。
    """

    static func make(
        article: PracticeArticle,
        articleText: String?,
        content: PracticeContent
    ) -> Built {
        let fullText = PracticeText.clean(articleText)
        let basis = fullText == nil ? "导读" : "全文"
        let material = fullText
            ?? PracticeText.clean(article.digest)
            ?? "（没有可用的文章材料）"

        var lines: [String] = []
        lines.append("文章标题：\(article.title)")
        lines.append("来源：\(PracticeText.clean(article.sourceName) ?? "（未注明）")")
        lines.append("材料类型：\(basis)")
        lines.append("")
        lines.append("文章材料：")
        lines.append(clamped(material))
        lines.append("")
        lines.append("---")
        lines.append("")
        lines.append("我的归纳总结：")
        lines.append(summary(from: content))

        return Built(system: system, user: lines.joined(separator: "\n"), basis: basis)
    }

    /// 超过上限就在**字符**边界截断，并明确告诉模型「后文省略了」——
    /// 不告诉它的话，它会把「材料里没有」误判成用户漏写。
    static func clamped(_ text: String) -> String {
        guard text.count > maximumArticleCharacters else { return text }
        return String(text.prefix(maximumArticleCharacters)) + "\n\n（材料过长，后文已省略）"
    }

    /// 把用户写的那份整理成模型好读的形状。空的部分整行省略。
    static func summary(from content: PracticeContent) -> String {
        switch content.mode {
        case .free:
            return PracticeText.clean(content.freeText) ?? "（还没有写）"

        case .structured:
            var parts: [String] = []
            if let idea = PracticeText.clean(content.mainIdea) {
                parts.append("主旨：\(idea)")
            }
            let points = PracticeText.normalizedPoints(content.points)
            if !points.isEmpty {
                parts.append("要点：\n" + points.map { "- \($0)" }.joined(separator: "\n"))
            }
            if let takeaway = PracticeText.clean(content.takeaway) {
                parts.append("我的判断：\(takeaway)")
            }
            return parts.isEmpty ? "（还没有写）" : parts.joined(separator: "\n\n")
        }
    }
}
