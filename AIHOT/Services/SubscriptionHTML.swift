import Foundation

/// RSS `description` 里常见的 HTML：压成摘要、抽第一张封面。
///
/// 不引入 HTML 解析库：封面只需要第一个 `<img src>`，摘要交给已有的
/// `HTMLTextExtractor`。两条规则都与镜像 22 共用夹具。
enum SubscriptionHTML {

    static let coverPattern = #"<img\b[^>]*?\bsrc\s*=\s*(?:"([^"]+)"|'([^']+)'|([^\s>]+))"#

    /// 摘要：去标签、实体、折叠空白，截断 2000 字。
    static func summary(from html: String, limit: Int = 2000) -> String {
        let text = HTMLTextExtractor.plainText(from: html)
        return SubscriptionText.clamp(collapseWhitespace(text), limit: limit)
    }

    /// 标题：只解实体、折叠空白。不跑 `plainText` —— 标题里的 `<` 不是标签，
    /// 交给它会误删（`A < B` 变成 `A`）。
    static func cleanTitle(_ raw: String) -> String {
        collapseWhitespace(HTMLTextExtractor.decodeEntities(raw))
    }

    /// 从描述 HTML 里取第一张封面。`//host/x.jpg` 补成 `https:`；
    /// 相对路径用条目链接解析；解析不出来就 nil（宁可不显示，不显示坏图）。
    static func coverURL(from html: String, baseURL: String?) -> String? {
        guard let result = RegexUtil.firstMatch(
            coverPattern,
            in: html,
            options: [.caseInsensitive]
        ) else { return nil }

        for index in 1...3 {
            if let value = RegexUtil.group(result, at: index, in: html) {
                return normalizeCoverURL(value, baseURL: baseURL)
            }
        }
        return nil
    }

    static func normalizeCoverURL(_ raw: String, baseURL: String?) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("//") {
            return "https:" + trimmed
        }

        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           let host = url.host,
           !host.isEmpty {
            return url.absoluteString
        }

        guard let base = baseURL, let base = URL(string: base) else { return nil }
        guard let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty
        else { return nil }
        return url.absoluteString
    }

    static func collapseWhitespace(_ text: String) -> String {
        var pieces: [Substring] = []
        for piece in text.split(whereSeparator: { $0.isWhitespace }) {
            pieces.append(piece)
        }
        return pieces.joined(separator: " ")
    }
}
