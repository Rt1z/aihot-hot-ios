import Foundation

/// 本机 RSSHub 的 B 站路由。
///
/// 路由只接受 `/bilibili/...`，并且拒绝 scheme/host/`..`/`#` ——
/// 配置文件是用户手写的，不能让一条写错的 route 把 App 变成「局域网任意地址取东西」
/// 的跳板（见 `SubscriptionConfigParser.normalizedBilibiliRoute`）。
final class RSSHubAPI {

    private let session: URLSession

    init(session: URLSession = SubscriptionHTTP.makeSession(
        requestTimeout: 15,
        resourceTimeout: 30,
        accept: "application/rss+xml, application/xml, text/xml;q=0.9"
    )) {
        self.session = session
    }

    func fetch(baseURLRaw: String, source: SubscriptionSource) async throws -> ParsedFeed {
        let url = try Self.requestURL(baseURLRaw: baseURLRaw, source: source)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue(AIHOTAPI.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "application/rss+xml, application/xml, text/xml;q=0.9",
            forHTTPHeaderField: "Accept"
        )

        let data = try await SubscriptionHTTP.perform(
            request,
            session: session,
            localHint: true,
            unauthorizedIsBadKey: false
        )
        return try RSSFeedParser.parse(data: data, source: source)
    }

    static func requestURL(baseURLRaw: String, source: SubscriptionSource) throws -> URL {
        guard case let .bilibili(route) = source.request else {
            throw SubscriptionError(kind: .invalidConfig, message: "这条信源不是 B 站路由")
        }
        guard let normalizedRoute = SubscriptionConfigParser.normalizedBilibiliRoute(route) else {
            throw SubscriptionError(kind: .invalidConfig, message: "B 站路由不合法（必须以 /bilibili/ 开头）")
        }
        guard let base = AIChatConfig.normalizedBaseURL(from: baseURLRaw) else {
            throw SubscriptionError(kind: .invalidConfig, message: "RSSHub 地址必须是 http(s) 地址")
        }
        guard let url = URL(string: base.absoluteString + normalizedRoute),
              let host = url.host,
              !host.isEmpty
        else {
            throw SubscriptionError(kind: .invalidConfig, message: "RSSHub 地址与路由拼不出合法链接")
        }
        return url
    }
}
