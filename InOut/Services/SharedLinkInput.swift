import Foundation

/// `aihot://add?url=…&title=…` 的解析。
///
/// 这是**不用分享扩展**的分享入口：快捷指令、自动化或任何能打开 URL 的地方
/// 都可以把链接交给 App。两条约束：
/// - 只认 `aihot://add`，其它 host 一律忽略（避免将来加路由时误伤）；
/// - 内层 URL 走 `SharedLinkURL.normalized`，所以私有地址、非 http(s)、
///   超长链接都进不来。
///
/// 调用方需要把 `url` 参数做 percent-encoding（尤其是链接里的 `&`），
/// 否则会被外层查询串截断。
struct SharedLinkInput: Equatable {

    let url: URL
    let title: String?

    static func parse(_ incoming: URL) -> SharedLinkInput? {
        guard incoming.scheme?.lowercased() == "aihot",
              incoming.host?.lowercased() == "add",
              let components = URLComponents(url: incoming, resolvingAgainstBaseURL: false),
              let rawURL = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let url = SharedLinkURL.normalized(rawURL)
        else { return nil }

        let rawTitle = components.queryItems?.first(where: { $0.name == "title" })?.value
        return SharedLinkInput(url: url, title: SharedLinkURL.cleanedTitle(rawTitle))
    }
}
