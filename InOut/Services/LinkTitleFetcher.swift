import Foundation

/// 抓一次网页标题（用户点「自动获取标题」或 URL Scheme 导入时才会调用）。
///
/// 刻意**不**在用户输入 URL 时自动跑：那会变成「边打字边向陌生站点发请求」。
/// 失败一律返回 nil —— 上层用域名兜底，标题不是这条链接的必需品。
///
/// 只抓最多 2 MB、只给 10 秒；超时/非 2xx/取不到标题都算失败，不重试。
final class LinkTitleFetcher: @unchecked Sendable {

    static let shared = LinkTitleFetcher()

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session = session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = [
            // 不少站点对非浏览器 UA 直接返回验证页
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            "Accept": "text/html,application/xhtml+xml",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.5",
        ]
        self.session = URLSession(configuration: configuration)
    }

    func fetch(linkURL: String) async -> String? {
        guard let url = SharedLinkURL.normalized(linkURL) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  data.count <= 2_000_000
            else { return nil }
            return LinkTitleParser.parse(html: String(decoding: data, as: UTF8.self))
        } catch {
            return nil
        }
    }
}
