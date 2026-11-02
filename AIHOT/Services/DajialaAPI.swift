import Foundation

/// Dajiala（极致了）公众号历史发文接口。
///
/// 请求体里只放 `page: 1`：翻页会让费用成倍增长，而且订阅页只看最近内容。
/// Key 只进请求体，**绝不进 URL / 日志 / 诊断**；错误文案里也不带 Key。
/// 串行与 0.5 秒间隔由 `SubscriptionStore` 负责，这里只发一次。
final class DajialaAPI {

    static let endpoint = URL(string: "https://www.dajiala.com/fbmain/monitor/v3/post_history")!

    private let session: URLSession

    init(session: URLSession = SubscriptionHTTP.makeSession(
        requestTimeout: 20,
        resourceTimeout: 40,
        accept: "application/json"
    )) {
        self.session = session
    }

    func fetchHistory(source: SubscriptionSource, apiKey: String) async throws -> [SubscriptionItem] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = try Self.makeRequest(source: source, apiKey: key)
        let data = try await SubscriptionHTTP.perform(
            request,
            session: session,
            localHint: false,
            unauthorizedIsBadKey: true
        )
        do {
            return try DajialaParser.parse(data: data, source: source)
        } catch let error as SubscriptionError {
            // 服务端的错误文案有可能回显请求体；Key 绝不能顺着界面/诊断漏出去。
            throw Self.sanitized(error, key: key)
        }
    }

    /// 把服务端文案里可能回显的 Key 换成 `***`（安全边界，同诊断的 hostOnly）。
    static func sanitized(_ error: SubscriptionError, key: String) -> SubscriptionError {
        guard !key.isEmpty, error.message.contains(key) else { return error }
        return SubscriptionError(
            kind: error.kind,
            message: error.message.replacingOccurrences(of: key, with: "***"),
            retryAfter: error.retryAfter
        )
    }

    /// 原样返回响应（不解析）。设置页的「复制公众号原始响应」用它抓夹具：
    /// 真实结构只有拿到字节才能确认，猜的字段名不能当成验收依据（规则 13）。
    func fetchRaw(source: SubscriptionSource, apiKey: String) async throws -> Data {
        let request = try Self.makeRequest(source: source, apiKey: apiKey)
        return try await SubscriptionHTTP.perform(
            request,
            session: session,
            localHint: false,
            unauthorizedIsBadKey: true
        )
    }

    private static func makeRequest(source: SubscriptionSource, apiKey: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw SubscriptionError(
                kind: .badKey,
                message: "还没填 Dajiala Key —— 到 设置 → 订阅 填一个"
            )
        }
        guard case let .wechat(url, biz) = source.request, url != nil || biz != nil else {
            throw SubscriptionError(kind: .invalidConfig, message: "这条信源不是公众号")
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        request.setValue(AIHOTAPI.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try makeBody(source: source, apiKey: key)
        return request
    }

    /// 纯函数，单测直接断言「page 永远是 1、Key 只在 body 里」。
    static func makeBody(source: SubscriptionSource, apiKey: String) throws -> Data {
        guard case let .wechat(url, biz) = source.request else {
            throw SubscriptionError(kind: .invalidConfig, message: "这条信源不是公众号")
        }
        guard url != nil || biz != nil else {
            throw SubscriptionError(kind: .invalidConfig, message: "公众号缺 url 和 biz")
        }

        var body: [String: Any] = [
            "page": 1,
            "key": apiKey,
            "verifycode": ""
        ]
        if let biz = biz, !biz.isEmpty { body["biz"] = biz }
        if let url = url, !url.isEmpty { body["url"] = url }
        if !source.name.isEmpty { body["name"] = source.name }

        do {
            return try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            throw SubscriptionError(kind: .invalidConfig, message: "Dajiala 请求体构造失败")
        }
    }
}
