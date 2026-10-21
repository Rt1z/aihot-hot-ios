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

    // MARK: - 周报 / 月报（有 JSON 接口，带 ETag —— 与模型榜的 HTML 抓取相反）

    /// 最新一期周报。`s-maxage=300` 且有 ETag，条件请求真的有效（CLAUDE.md 规则 19）。
    func weeklyLatest(ignoreCache: Bool = false) async throws -> LoadOutcome<ReportResponse> {
        try await getJSON(
            path: "/api/v1/weeklies/latest",
            cacheKey: "weeklies-latest",
            as: ReportResponse.self,
            useETag: !ignoreCache
        )
    }

    /// 周报全量索引（实测 12 期，无分页）。
    func weeklyIndex(ignoreCache: Bool = false) async throws -> LoadOutcome<ReportIndexResponse> {
        try await getJSON(
            path: "/api/v1/weeklies",
            cacheKey: "weeklies-index",
            as: ReportIndexResponse.self,
            useETag: !ignoreCache
        )
    }

    /// 某一周的周报（`period` 形如 `2026-W41`）。
    func weeklyReport(period: String, ignoreCache: Bool = false) async throws -> LoadOutcome<ReportResponse> {
        try await getJSON(
            path: "/api/v1/weeklies/\(Self.escaped(period))",
            cacheKey: "weekly-\(period)",
            as: ReportResponse.self,
            useETag: !ignoreCache
        )
    }

    func monthlyLatest(ignoreCache: Bool = false) async throws -> LoadOutcome<ReportResponse> {
        try await getJSON(
            path: "/api/v1/monthlies/latest",
            cacheKey: "monthlies-latest",
            as: ReportResponse.self,
            useETag: !ignoreCache
        )
    }

    func monthlyIndex(ignoreCache: Bool = false) async throws -> LoadOutcome<ReportIndexResponse> {
        try await getJSON(
            path: "/api/v1/monthlies",
            cacheKey: "monthlies-index",
            as: ReportIndexResponse.self,
            useETag: !ignoreCache
        )
    }

    /// 某一月的月报（`period` 形如 `2026-09`）。
    func monthlyReport(period: String, ignoreCache: Bool = false) async throws -> LoadOutcome<ReportResponse> {
        try await getJSON(
            path: "/api/v1/monthlies/\(Self.escaped(period))",
            cacheKey: "monthly-\(period)",
            as: ReportResponse.self,
            useETag: !ignoreCache
        )
    }

    private static func escaped(_ period: String) -> String {
        period.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? period
    }

    /// 模型榜页面 HTML（榜页 path 见 `LeaderboardCategory.path`，详情页传
    /// `/leaderboard/<slug>`）。榜单没有公开 JSON 接口，只能整页抓回来解析。
    ///
    /// - Note: 这些页面 `s-maxage` ≈ 300/600 且没有 ETag —— 上层按 300s 节流，
    ///   这里不做条件请求。
    func leaderboardHTML(path: String) async throws -> String {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = "GET"
        request.setValue(AIHOTAPI.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await perform(request)
        try validate(response: response, data: data)
        return String(decoding: data, as: UTF8.self)
    }

    /// 条目站内页 HTML（`/items/{id}`，id 取自 `links.aihot` 的末段）。
    ///
    /// 这一页**没有 JSON 接口**（`/api/v1/items/*` 全部 404），结构化载荷是
    /// React Router 的 turbo-stream，Swift 里解不动 —— 只能整页抓回来从
    /// `<div class="prose">` 里取正文（见 `ReportItemBody`）。
    ///
    /// - Note: 实测 `max-age=300, s-maxage=599` 且**没有 ETag** ——
    ///   所以这里不做条件请求（做了也没用，还会撞上规则 2 那个「304 却没有正文」
    ///   的坑）。已发布的条目不可变，上层拿到一次就永久内存缓存，只有失败才重试。
    func itemHTML(id: String) async throws -> String {
        var request = URLRequest(url: url(for: "/items/\(id)"))
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
