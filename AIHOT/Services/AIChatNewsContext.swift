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
    你是一个中文新闻助手，帮用户读懂「AI 热点榜」里的某一条热点。
    这条热点的资料会在我第一条消息里给出；回答请优先依据这些资料。
    资料不够、又确实需要更多信息时，可以联网搜索，或直接读取资料里给出的原文链接。
    资料里没有依据的内容不要编造；不确定就直说不确定。
    用中文回答，简洁清楚，不要客套话，也不要重复我已经知道的资料。
    """

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
