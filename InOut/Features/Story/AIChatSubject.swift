import Foundation

/// 一次 AI 对话的「主题」：热点详情，或从外部导入的文章。
///
/// 只负责三件与界面无关的事：会话 key（落盘分组）、系统提示词、第一条消息里的资料。
/// 两者共用同一套 `AIChatModel` / 传输层 / 工具链，区别只在资料怎么拼 ——
/// 不要让导入文章去伪造一个 `HotTopic`，那样上下文里会出现假的名次与热度。
enum AIChatSubject {

    case hot(item: HotTopic, story: Story?, prefetchedDigest: String?)
    case savedLink(link: SavedLink, articleText: String?)

    /// 对话历史按这个 key 落盘：热点用 `HotTopic.id`，导入文章用 `link:<url>`。
    var sessionKey: String {
        switch self {
        case .hot(let item, _, _):
            return item.id
        case .savedLink(let link, _):
            return "link:\(link.url)"
        }
    }

    var title: String {
        switch self {
        case .hot(let item, let story, _):
            return story?.title ?? item.title
        case .savedLink(let link, _):
            return link.title
        }
    }

    var system: String {
        switch self {
        case .hot:
            return AIChatNewsContext.system
        case .savedLink:
            return AIChatNewsContext.linkSystem
        }
    }

    var newsContext: String {
        switch self {
        case .hot(let item, let story, let digest):
            return AIChatNewsContext.make(item: item, story: story, prefetchedDigest: digest)
        case .savedLink(let link, let text):
            return AIChatNewsContext.make(link: link, articleText: text)
        }
    }

    /// 复制回答时附带的出处链接。
    var sourceLink: String? {
        switch self {
        case .hot(let item, let story, _):
            return item.links?.original
                ?? item.links?.aihot
                ?? story?.links?.original
                ?? story?.links?.aihot
        case .savedLink(let link, _):
            return link.url
        }
    }

    /// 空态说明：照实说模型手里有什么（尤其正文没取到时别让它假装看过）。
    var capabilityNote: String {
        switch self {
        case .hot:
            return "它已经看过这条的摘要与报道时间线；需要时会自己去联网搜索，或去读原文。"
        case .savedLink(_, let text):
            if let text = text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "它已经看过这篇文章的正文；需要时会自己去联网搜索，或读取文中的链接。"
            }
            return "正文还没取到；它可以从标题和链接开始，需要时用 read_url 读原文。"
        }
    }

    var suggestions: [String] {
        switch self {
        case .hot:
            return ["这条为什么火？", "用三句话讲清楚", "还有后续吗？"]
        case .savedLink:
            return ["这篇文章讲了什么？", "提炼三个关键点", "作者的论证有什么漏洞？"]
        }
    }

    var emptyTitle: String {
        switch self {
        case .hot:
            return "就这条新闻问点什么"
        case .savedLink:
            return "就这篇文章问点什么"
        }
    }

    var composerPlaceholder: String {
        switch self {
        case .hot:
            return "就这条新闻问点什么…"
        case .savedLink:
            return "就这篇文章问点什么…"
        }
    }
}
