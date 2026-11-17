import Foundation

/// 喂给模型的「这条热点的资料」与系统提示词。纯函数，便于单测。
///
/// 两个必须守住的性质：
///
/// 1. **确定性**：同样的输入必须产出逐字节相同的输出。所以这里只用
///    `RelativeTime.absoluteShort`（绝对时间），**绝不用** `RelativeTime.relative`
///    —— 「3 小时前」每轮都在变，会把缓存前缀每一轮都打断。
/// 2. **原报道 URL 原样出现**：Anthropic 的 `web_fetch` 只能抓对话里已经出现过的
///    URL，而「按需读原报道」就靠它。
enum AIChatNewsContext {

    /// 资料段总长上限：不要把整篇文章塞进去。
    static let maxCharacters = 6000
    /// 报道时间线最多列几条。
    static let maxReports = 8

    static let system = """
    你是一个中文新闻助手，帮用户读懂「InOut」里的某一条热点。
    这条热点的资料会在我第一条消息里给出；回答请优先依据这些资料。
    需要更多信息时，用 web_search 联网搜索（只给关键词，别给整句话），
    或用 read_url 读某个网页（资料里的原文链接、搜索结果里的任意一条都可以读）。
    搜索结果本身带 URL，回答里提到事实时请顺带说清来源。
    资料里没有依据的内容不要编造；不确定就直说不确定。
    用中文回答，简洁清楚，不要客套话，也不要重复我已经知道的资料。
    """

    /// 导入文章用的系统提示词（与热点那条分开写：资料的形状不一样）。
    static let linkSystem = """
    你是一个中文阅读助手，帮用户读懂一篇网页文章（可能是微信公众号文章）。
    这篇文章的标题、链接与正文会在我第一条消息里给出；回答请优先依据正文。
    需要更多信息时，用 web_search 联网搜索，或用 read_url 读链接（正文里出现的任意 URL 也可以读）。
    正文里没有依据的内容不要编造；不确定就直说不确定。
    用中文回答，简洁清楚，不要客套话，也不要重复我已经知道的资料。
    """

    /// 导入文章的资料。正文由内嵌阅读器取到；取不到时只给标题与链接，
    /// 并明确告诉模型「只有链接」—— 不要让它假装看过全文。
    static func make(link: SavedLink, articleText: String?) -> String {
        var lines: [String] = []

        lines.append("【这篇文章】")
        lines.append("标题：" + link.title)
        lines.append("来源：" + link.sourceLabel + "（" + link.host + "）")
        // 链接必须原样出现：read_url 只能读对话里已经出现过的 URL。
        lines.append("链接：" + link.url)

        if let text = articleText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            lines.append("")
            lines.append("【正文】")
            lines.append(text)
        } else {
            lines.append("")
            lines.append("（正文尚未取到，只有标题与链接。需要时先用 read_url 读上面的链接。）")
        }

        lines.append("")
        lines.append("以上是 App 里已有的资料。请据此回答我下面的问题。")

        return clamp(lines.joined(separator: "\n"))
    }

    static func make(item: HotTopic, story: Story?, prefetchedDigest: String?) -> String {
        var lines: [String] = []

        lines.append("【这条热点】")
        lines.append("标题：" + (story?.title ?? item.title))
        lines.append("当前排名：第 \(item.rank) 位")
        if let name = item.source?.name, !name.isEmpty {
            lines.append("来源：" + name)
        }

        var counts: [String] = []
        if let count = item.sourceCount, count > 0 { counts.append("\(count) 个来源") }
        if let count = item.participantCount, count > 0 { counts.append("\(count) 位参与者") }
        if !counts.isEmpty {
            lines.append("规模：" + counts.joined(separator: " · "))
        }

        if let latest = item.latestAt {
            lines.append("最近报道：" + RelativeTime.absoluteShort(latest) + "（北京时间）")
        }
        if let first = story?.firstReportAt {
            lines.append("首次报道：" + RelativeTime.absoluteShort(first) + "（北京时间）")
        }

        // 原文链接必须原样出现，web_fetch 只能抓对话里已经出现过的 URL。
        if let original = item.links?.original ?? story?.links?.original, !original.isEmpty {
            lines.append("原文链接：" + original)
        }
        if let aihot = item.links?.aihot ?? story?.links?.aihot, !aihot.isEmpty {
            lines.append("站内页：" + aihot)
        }

        if let digest = digestText(story: story, prefetchedDigest: prefetchedDigest) {
            lines.append("")
            lines.append("【AI 摘要】")
            for paragraph in digest.components(separatedBy: "\n") {
                let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    lines.append(trimmed)
                }
            }
        }

        let reports = story?.sortedReports ?? []
        if !reports.isEmpty {
            lines.append("")
            lines.append("【报道时间线】")
            for report in reports.prefix(maxReports) {
                var parts: [String] = []
                if let when = report.publishedAt {
                    parts.append(RelativeTime.absoluteShort(when))
                }
                if let name = report.source?.name, !name.isEmpty { parts.append(name) }
                if let title = report.title, !title.isEmpty { parts.append(title) }
                if !parts.isEmpty {
                    lines.append("- " + parts.joined(separator: " · "))
                }
                if let summary = report.summary, !summary.isEmpty {
                    lines.append("  " + summary)
                }
            }
        }

        lines.append("")
        lines.append("以上是 App 里已有的资料。请据此回答我下面的问题。")

        return clamp(lines.joined(separator: "\n"))
    }

    private static func digestText(story: Story?, prefetchedDigest: String?) -> String? {
        if let digest = story?.digest, !digest.isEmpty { return digest }
        if let prefetched = prefetchedDigest, !prefetched.isEmpty { return prefetched }
        return nil
    }

    private static func clamp(_ text: String) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters)) + "\n…（资料过长，已截断）"
    }
}
