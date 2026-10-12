import Foundation

/// 一次请求的结果：新鲜数据 or 304 未变化。
enum LoadOutcome<Value> {
    case modified(Value)
    case notModified
}

struct APIError: Error, LocalizedError {

    enum Kind: Equatable {
        case offline
        case rateLimited(retryAfter: Int?)
        case server(Int)
        case transport(String)
        case decoding(String)
    }

    let kind: Kind
    let message: String

    var errorDescription: String? { message }

    var retryAfter: Int? {
        if case let .rateLimited(seconds) = kind { return seconds }
        return nil
    }
}

/// ETag 持久化（UserDefaults 足够，键很少）。
final class ETagStore {

    static let shared = ETagStore()

    private let defaults: UserDefaults
    private let prefix = "aihot.etag."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func etag(for key: String) -> String? {
        defaults.string(forKey: prefix + key)
    }

    func setETag(_ value: String?, for key: String) {
        if let value = value, !value.isEmpty {
            defaults.set(value, forKey: prefix + key)
        } else {
            defaults.removeObject(forKey: prefix + key)
        }
    }

    func clear() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }
}

/// AIHOT 公开接口客户端（匿名只读，无需 Key）。
///
/// 遵守对方的使用约定：
/// - 请求带 `If-None-Match`，未变化时是 304 空体；
/// - 刷新间隔不短于 `s-maxage`（60s，由上层 Store 节流）；
/// - 429 / 503 读 `Retry-After`，不并行重试。
final class AIHOTAPI: @unchecked Sendable {

    static let shared = AIHOTAPI()

    private let baseURL: URL
    private let session: URLSession
    private let etags: ETagStore

    private let hotTopicsPath = "/api/v1/hot-topics"
    private let hotPagePath = "/hot"

    init(
        baseURL: URL = URL(string: "https://aihot.news")!,
        session: URLSession? = nil,
        etags: ETagStore = .shared
    ) {
        self.baseURL = baseURL
        self.etags = etags

        if let session = session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            configuration.waitsForConnectivity = false
            configuration.requestCachePolicy = .useProtocolCachePolicy
            // 不手动设置 Accept-Encoding：URLSession 默认就会发 gzip/br 并透明解压。
            configuration.httpAdditionalHeaders = [
                "User-Agent": AIHOTAPI.userAgent,
                "Accept": "application/json"
            ]
            self.session = URLSession(configuration: configuration)
        }
    }

    static var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "AIHOT-iOS/\(version) (personal use; +https://aihot.news)"
    }

    // MARK: - 公开接口

    func hotTopics(ignoreCache: Bool = false) async throws -> LoadOutcome<HotTopicsResponse> {
        try await getJSON(
            path: hotTopicsPath,
            cacheKey: "hot-topics",
            as: HotTopicsResponse.self,
            useETag: !ignoreCache
        )
    }

    func story(publicId: String, ignoreCache: Bool = false) async throws -> LoadOutcome<StoryResponse> {
        let encoded = publicId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? publicId
        return try await getJSON(
            path: "/api/v1/stories/\(encoded)",
            cacheKey: "story-\(publicId)",
            as: StoryResponse.self,
            useETag: !ignoreCache
        )
    }

    /// 只给「网页文本增强」用：拿热点榜页面的 HTML。
    func hotPageHTML() async throws -> String {
        var request = URLRequest(url: url(for: hotPagePath))
        request.httpMethod = "GET"
        request.setValue(AIHOTAPI.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await perform(request)
        try validate(response: response, data: data)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 内部

    private func url(for path: String) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        return components?.url ?? baseURL
    }

    /// - Parameter useETag: 是否发 `If-None-Match`。ETag 会持久化在 UserDefaults 里，
    ///   而正文可能只存在于内存 —— 当本地没有正文可展示时，上层会要求忽略缓存重新取，
    ///   否则会一直拿到 304 而没有内容可用（详见 StoryCache 的注释）。
    private func getJSON<T: Decodable>(
        path: String,
        cacheKey: String,
        as type: T.Type,
        useETag: Bool = true
    ) async throws -> LoadOutcome<T> {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = "GET"
        request.setValue(AIHOTAPI.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if useETag, let etag = etags.etag(for: cacheKey) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await perform(request)

        if let http = response as? HTTPURLResponse, http.statusCode == 304 {
            return .notModified
        }

        try validate(response: response, data: data)

        if let http = response as? HTTPURLResponse,
           let etag = http.value(forHTTPHeaderField: "ETag") {
            etags.setETag(etag, for: cacheKey)
        }

        do {
            let decoded = try JSONDecoder.aihot.decode(T.self, from: data)
            return .modified(decoded)
        } catch {
            throw APIError(kind: .decoding(String(describing: error)), message: "数据格式异常，可能接口已更新")
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut, .dataNotAllowed:
                throw APIError(kind: .offline, message: "网络不可用，正在显示上次缓存")
            default:
                throw APIError(kind: .transport(error.localizedDescription), message: "网络错误：\(error.localizedDescription)")
            }
        } catch {
            throw APIError(kind: .transport(error.localizedDescription), message: "网络错误：\(error.localizedDescription)")
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError(kind: .transport("no http response"), message: "响应异常")
        }

        switch http.statusCode {
        case 200...299:
            return
        case 429, 503:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }
            let seconds = retryAfter.map { "\($0) 秒" } ?? "一会儿"
            throw APIError(
                kind: .rateLimited(retryAfter: retryAfter),
                message: "请求过于频繁，\(seconds)后再试"
            )
        default:
            let detail = Self.problemDetail(from: data)
            throw APIError(
                kind: .server(http.statusCode),
                message: detail ?? "服务返回 \(http.statusCode)"
            )
        }
    }

    /// 解析 RFC7807 的 problem+json，拿一句给人看的说明。
    private static func problemDetail(from data: Data) -> String? {
        struct Problem: Decodable {
            let title: String?
            let detail: String?
        }
        guard let problem = try? JSONDecoder().decode(Problem.self, from: data) else { return nil }
        return problem.detail ?? problem.title
    }
}
