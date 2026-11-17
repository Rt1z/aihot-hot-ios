import Foundation

/// 从网页 HTML 里取标题：优先 `og:title`，退回 `<title>`。
///
/// 这是第四个「从网页文本抽数据」的解析器（前三个是 `HotPageEnricher`、
/// `LeaderboardParser`、`ReportItemBody`），但目标最简单：只要一行标题。
/// 锚点是标准的 `<meta property="og:title">` 与 `<title>`，不锚任何 class。
/// 取不到返回 nil —— 上层用域名兜底，绝不编造标题。
///
/// 纯函数；单测与镜像 24 读同一份合成夹具（`link-title.html`，
/// 说明见测试注释：这是手写的，不是抓取）。
enum LinkTitleParser {

    static func parse(html: String) -> String? {
        if let title = metaTitle(in: html) { return title }

        // `<title>` 有时是站点的通用标题（「微信公众平台」），这时先看公众号
        // 页面里的 `msg_title` 变量，再退回那个通用标题。
        let documentTitle = htmlTitle(in: html)
        if let title = documentTitle, !isGenericTitle(title) { return title }
        if let title = messageTitle(in: html) { return title }
        return documentTitle
    }

    /// 这些不是文章标题，是站点/风控页的标题。抓到它们等于没抓到。
    static func isGenericTitle(_ title: String) -> Bool {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return true }
        let generic = [
            "微信公众平台",
            "请在微信客户端打开",
            "请在微信客户端打开链接",
            "环境异常",
            "微信公众平台 - 请在微信客户端打开",
        ]
        if generic.contains(value) { return true }
        return value.contains("验证") && value.count <= 12
    }

    /// 公众号历史模板里的 `var msg_title = "…"`；有些页面只有 `<title>`。
    static func messageTitle(in html: String) -> String? {
        guard let match = RegexUtil.firstMatch(
            #"(?:var\s+)?msg_title\s*=\s*["']([^"']+)["']"#,
            in: html,
            options: [.caseInsensitive]
        ), let raw = RegexUtil.group(match, at: 1, in: html) else { return nil }
        return cleaned(raw)
    }

    /// 两种属性顺序都要认：`property` 在前或 `content` 在前。
    static func metaTitle(in html: String) -> String? {
        let patterns = [
            #"<meta[^>]*\bproperty\s*=\s*["']og:title["'][^>]*\bcontent\s*=\s*["']([^"']*)["']"#,
            #"<meta[^>]*\bcontent\s*=\s*["']([^"']*)["'][^>]*\bproperty\s*=\s*["']og:title["']"#,
        ]
        for pattern in patterns {
            guard let match = RegexUtil.firstMatch(pattern, in: html, options: [.caseInsensitive]),
                  let raw = RegexUtil.group(match, at: 1, in: html),
                  let cleaned = cleaned(raw)
            else { continue }
            return cleaned
        }
        return nil
    }

    static func htmlTitle(in html: String) -> String? {
        guard let match = RegexUtil.firstMatch(#"(?is)<title[^>]*>(.*?)</title>"#, in: html),
              let raw = RegexUtil.group(match, at: 1, in: html),
              let cleaned = cleaned(raw)
        else { return nil }
        return cleaned
    }

    static func cleaned(_ raw: String) -> String? {
        let decoded = HTMLTextExtractor.decodeEntities(raw)
        return SharedLinkURL.cleanedTitle(decoded)
    }
}
