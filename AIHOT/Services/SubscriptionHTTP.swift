import Foundation

/// 订阅两条网络线路共用的请求/错误映射。
///
/// 和 `AIHOTAPI` 的会话分开：RSSHub 在局域网、可能很慢，Dajiala 是付费接口，
/// 两边的超时与错误文案都不一样，复用同一个 `URLSession` 只会让问题更难查。
enum SubscriptionHTTP {

    static func makeSession(
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval,
        accept: String
    ) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = [
            "User-Agent": AIHOTAPI.userAgent,
            "Accept": accept
        ]
        return URLSession(configuration: configuration)
    }

    static func perform(
        _ request: URLRequest,
        session: URLSession,
        localHint: Bool,
        unauthorizedIsBadKey: Bool
    ) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw mapURLError(error, localHint: localHint)
        }
        try validate(response: response, unauthorizedIsBadKey: unauthorizedIsBadKey)
        return data
    }

    static func validate(response: URLResponse, unauthorizedIsBadKey: Bool) throws {
        guard let http = response as? HTTPURLResponse else {
            throw SubscriptionError(kind: .server, message: "响应异常")
        }
        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            if unauthorizedIsBadKey {
                throw SubscriptionError(
                    kind: .badKey,
                    message: "Dajiala Key 无效或已停用 —— 到 设置 → 订阅 换一个 Key"
                )
            }
            throw SubscriptionError(
                kind: .server,
                message: "服务拒绝访问（HTTP \(http.statusCode)）；RSSHub 若开了访问码请先关闭或走 HTTPS"
            )
        case 429, 503:
            let seconds = retryAfter(from: http)
            let message = seconds.map { "请求过于频繁，\($0) 秒后再试" }
                ?? "请求过于频繁，稍后再试"
            throw SubscriptionError(kind: .rateLimited, message: message, retryAfter: seconds)
        default:
            throw SubscriptionError(
                kind: .server,
                message: "服务返回 \(http.statusCode)"
            )
        }
    }

    static func retryAfter(from response: HTTPURLResponse) -> Int? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 把 URLSession 的错误翻成「能照着做」的中文。
    ///
    /// 本地网络被拒与 ATS 被拒是两件不同的事：
    /// - 本地网络被拒通常是 `-1009`，要去「设置 → 隐私与安全性 → 本地网络」放行；
    /// - ATS 被拒是 `-1022`，要改地址或改用 HTTPS。
    /// 两者都不能只回一句「网络不可用」。
    static func mapURLError(_ error: Error, localHint: Bool) -> SubscriptionError {
        guard let urlError = error as? URLError else {
            return SubscriptionError(kind: .offline, message: "网络错误：\(error.localizedDescription)")
        }

        switch urlError.code {
        case .appTransportSecurityRequiresSecureConnection:
            return SubscriptionError(
                kind: .invalidConfig,
                message: "iOS 拒绝了明文 HTTP：请检查订阅地址，或改用 HTTPS"
            )
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .timedOut,
             .dataNotAllowed:
            if localHint {
                return SubscriptionError(
                    kind: .offline,
                    message: "连不上电脑上的服务：请确认 iPhone 和电脑在同一 Wi-Fi，并在 设置 → 隐私与安全性 → 本地网络 里允许本 App；地址也可以改用电脑的本机名（例如 MacBook.local）"
                )
            }
            return SubscriptionError(kind: .offline, message: "网络不可用，正在显示上次缓存")
        default:
            return SubscriptionError(
                kind: .offline,
                message: "网络错误：\(urlError.localizedDescription)"
            )
        }
    }
}
