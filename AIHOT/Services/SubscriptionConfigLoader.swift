import Foundation

/// 从电脑上的静态文件服务器拉 `subscriptions.json`。
///
/// 不做条件请求（不设 ETag）：静态服务器不一定给，而且规则 2 的
/// 「304 但本地没有正文」坑不值得为一份额外的配置文件再踩一次。
/// 上次成功的原文由 store 缓存在 UserDefaults，加载失败时继续用它。
final class SubscriptionConfigLoader {

    private let session: URLSession

    init(session: URLSession = SubscriptionHTTP.makeSession(
        requestTimeout: 15,
        resourceTimeout: 30,
        accept: "application/json"
    )) {
        self.session = session
    }

    func fetch(url: URL) async throws -> Data {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty
        else {
            throw SubscriptionError(
                kind: .invalidConfig,
                message: "订阅配置地址必须是 http(s) 地址"
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue(AIHOTAPI.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        return try await SubscriptionHTTP.perform(
            request,
            session: session,
            localHint: true,
            unauthorizedIsBadKey: false
        )
    }
}
