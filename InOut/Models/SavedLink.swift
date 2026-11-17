import Foundation

/// 从外部收进来的一条网页（公众号文章或普通链接）。
///
/// 只存**链接与标题**，不存正文：正文在原文网站，App 打开系统阅读器即可；
/// 存全文既不可靠（公众号页面结构会变）又没必要。标题可以手填，
/// 留空时按站点类型给一个说明性的兜底（「微信公众号文章」或域名）——
/// 不编造标题，也不在列表里摆一条光秃秃的 URL。
struct SavedLink: Codable, Hashable {

    /// 规范化后的绝对 http(s) 地址（去掉 fragment）。
    let url: String
    let title: String

    init(url: String, title: String? = nil) {
        let normalized = SharedLinkURL.normalized(url)?.absoluteString ?? url
        self.url = normalized
        self.title = SharedLinkURL.cleanedTitle(title)
            ?? SharedLinkURL.defaultTitle(for: normalized)
    }

    var host: String { URL(string: url)?.host ?? "" }

    var isWeChatArticle: Bool { SharedLinkURL.isWeChatHost(host) }

    var sourceLabel: String { isWeChatArticle ? "公众号文章" : "链接" }

    /// 列表/详情里显示的来源：公众号只写「公众号文章」，普通链接带域名。
    var sourceLine: String {
        isWeChatArticle ? sourceLabel : "\(sourceLabel) · \(host)"
    }
}
