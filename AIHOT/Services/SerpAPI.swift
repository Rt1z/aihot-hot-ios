import Foundation

/// 抽出来是为了让工具分发逻辑能在单测里跑，不联网（与 `TavilyCalling` 同形）。
protocol SerpAPICalling {
    func call(tool: String, arguments: [String: Any], apiKey: String) async throws -> String
}

/// SerpAPI 客户端：**只有搜索，没有读网页**（官方产品线里没有正文抽取这一项，
/// 能力矩阵对 `read_url` 是 ✗ —— `SearchToolChain` 会先把它过滤掉，这里是防御）。
///
/// 接口契约（照 serpapi.com/search-api 文档，并已实际调通、抓过夹具）：
///
/// - `GET https://serpapi.com/search?engine=google&q=…&api_key=…` —— Key 在**查询串**里，
///   没有鉴权头。因此**错误文案绝不允许出现完整请求 URL**（那等于把 Key 印出去）；
/// - 成功体在 `organic_results[]`（title / link / snippet …）。两个边界：
///   ① **200 也可能带顶层 `"error"` 字符串**，解析必须先查它，别把报错当结果；
///   ② 条目**可以没有 `snippet`**（真夹具 9 条里就有 2 条没有），解析要容缺；
/// - 错误体是**单字段** `{"error": "<一句话>"}`（不是 `error.message` 信封，
///   `AIChatAPI.problemMessage` 认不出来，所以 `topError` 自己解）：
///   401 Key 无效、429 额度/限速、400 缺参、503 搜索失败。
///
/// 夹具 `AIHOTTests/Fixtures/serpapi-search.json`（200，9 条）与 `serpapi-error.json`
/// （401 单字段）都是**真抓的字节**；200-with-error 那条分支没有免费触发的办法，
/// 用例是合成的（测试里有标注）。
final class SerpAPI: SerpAPICalling, @unchecked Sendable {

    static let shared = SerpAPI()

    private let endpoint = URL(string: "https://serpapi.com/search")!
    private let session: URLSession

    init(session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()) {
        self.session = session
    }

    func call(tool: String, arguments: [String: Any], apiKey: String) async throws -> String {
        guard tool == "search" else {
            throw APIError(kind: .decoding("serpapi"), message: "SerpAPI 没有这个工具：\(tool)")
        }

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        // 调用方摆好参数名（engine/q），这里只负责拼进查询串
        var items: [URLQueryItem] = []
        for (name, value) in arguments {
            guard let text = value as? String, !text.isEmpty else { continue }
            items.append(URLQueryItem(name: name, value: text))
        }
        // Key 最后追加：它只进查询串，绝不进任何文案
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        items.append(URLQueryItem(name: "api_key", value: key))
        components?.queryItems = items
        guard let url = components?.url else {
            throw APIError(kind: .decoding("serpapi"), message: "SerpAPI 请求构造失败")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .appTransportSecurityRequiresSecureConnection {
                throw APIError(
                    kind: .transport(error.localizedDescription),
                    message: "地址不是 https，被系统拦下了（SerpAPI 自己是 https，只在地址被改坏时才会发生）"
                )
            }
            throw APIError(
                kind: .transport(error.localizedDescription),
                message: "连不上 SerpAPI：\(error.localizedDescription)"
            )
        } catch {
            throw APIError(kind: .transport(error.localizedDescription), message: "SerpAPI 请求失败：\(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError(kind: .transport("响应不是 HTTP"), message: "SerpAPI 返回了看不懂的响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            // 取状态码与响应体进文案；**绝不碰 request.url** —— 查询串里有 api_key
            throw Self.apiError(statusCode: http.statusCode, data: data)
        }
        return try Self.searchText(from: data)
    }

    /// 200 体 → Markdown 结果。先查顶层 `error`（200-with-error 分支），再解析 `organic_results`。
    static func searchText(from data: Data) throws -> String {
        struct Payload: Decodable {
            struct Item: Decodable {
                let title: String?
                let link: String?
                let snippet: String?
            }
            let error: String?
            let organicResults: [Item]?
            enum CodingKeys: String, CodingKey {
                case error
                case organicResults = "organic_results"
            }
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw APIError(kind: .decoding("serpapi"), message: "SerpAPI 返回了看不懂的内容")
        }
        // 200 也可能带顶层 error —— 先查它，别把报错当结果喂给模型
        let topProblem = trimmed(payload.error)
        if !topProblem.isEmpty {
            throw APIError(kind: .decoding("serpapi"), message: "SerpAPI 报错：\(topProblem)")
        }
        var sections: [String] = []
        for item in payload.organicResults ?? [] {
            let title = trimmed(item.title)
            let link = trimmed(item.link)
            let snippet = trimmed(item.snippet)
            guard !title.isEmpty || !link.isEmpty || !snippet.isEmpty else { continue }
            let heading = title.isEmpty ? link : title
            var section = "### \(sections.count + 1). \(heading)"
            // 标题本身就是链接时不再重复一行（真夹具第 1 条就是这样）
            if !link.isEmpty, link != heading {
                section += "\n" + link
            }
            if !snippet.isEmpty {
                section += "\n\n" + snippet
            }
            sections.append(section)
        }
        guard !sections.isEmpty else {
            throw APIError(kind: .decoding("serpapi"), message: "SerpAPI 没有返回可用内容")
        }
        return sections.joined(separator: "\n\n")
    }

    /// 错误体是单字段 `{"error": "…"}` —— `problemMessage` 认不出这种信封，自己解。
    static func topError(from data: Data) -> String? {
        struct Payload: Decodable {
            let error: String?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        let text = trimmed(payload.error)
        return text.isEmpty ? nil : text
    }

    static func apiError(statusCode: Int, data: Data) -> APIError {
        let detail = topError(from: data) ?? AIChatAPI.problemMessage(from: data)
        func withDetail(_ base: String) -> String {
            guard let detail = detail, !detail.isEmpty else { return base }
            return base + "。接口原话：" + detail
        }
        if statusCode == 401 || statusCode == 403 {
            return APIError(
                kind: .server(statusCode),
                message: withDetail(
                    "SerpAPI 的 Key 无效或已停用（\(statusCode)）。到「设置 → AI 对话 → 搜索工具」换一个 Key，或停用 SerpAPI 改用其它家"
                )
            )
        }
        if statusCode == 429 {
            return APIError(
                kind: .rateLimited(retryAfter: nil),
                message: withDetail(
                    "SerpAPI 请求过于频繁或额度用尽（429），稍等片刻再试；也可到「设置 → AI 对话 → 搜索工具」换一家"
                )
            )
        }
        return APIError(
            kind: .server(statusCode),
            message: "SerpAPI 返回 \(statusCode)" + (detail.map { "：\($0)" } ?? "")
        )
    }

    /// 与 `TavilyAPI.trimmed` 同约定：**返回非可选**（nil 当空串），
    /// 调用方直接 `.isEmpty`，不用处处 `if let`。
    private static func trimmed(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 把模型请求的工具调用落到 SerpAPI 上（由 `SearchToolChain` 按用户顺序调用；
/// 空 Key 与 `read_url` 都由链先挡，这里是防御）。与 `TavilyToolRunner` 同形：
/// 做成 struct + 可注入的 api，单测拿假 api 跑完整分发而不联网。
struct SerpAPIToolRunner: AIChatToolExecuting {
    let apiKey: String
    let api: SerpAPICalling

    init(apiKey: String, api: SerpAPICalling = SerpAPI.shared) {
        self.apiKey = apiKey
        self.api = api
    }

    func execute(call: AIChatToolCall) async -> (text: String, isError: Bool) {
        guard let name = call.name else {
            return AIChatToolResult.failure("工具", "这次调用没有给出工具名")
        }
        // SerpAPI 没有匿名模式（链会先按 Key 过滤，这里是防御）
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AIChatToolResult.failure(
                name,
                "还没填 SerpAPI 的 Key（SerpAPI 不支持匿名）。到「设置 → AI 对话 → 搜索工具」填一个，或停用 SerpAPI"
            )
        }
        switch name {
        case AIChatToolName.webSearch:
            guard let query = call.string("query") else {
                return AIChatToolResult.missingArgument(name)
            }
            do {
                // SerpAPI 的参数名是 q（engine 固定 google）——由这里摆好，API 层只负责拼进查询串
                let text = try await api.call(
                    tool: "search",
                    arguments: ["engine": "google", "q": query],
                    apiKey: apiKey
                )
                return (AIChatToolResult.clamp(text), false)
            } catch let error as APIError {
                return AIChatToolResult.failure(name, error.message)
            } catch {
                return AIChatToolResult.failure(name, error.localizedDescription)
            }
        case AIChatToolName.readURL:
            // 链按能力矩阵不会把 read_url 路由到这里；真到了照实回绝，一次网络都不发
            return AIChatToolResult.failure(name, "SerpAPI 只支持搜索，不支持读网页")
        default:
            return AIChatToolResult.failure(name, "没有这个工具")
        }
    }
}
