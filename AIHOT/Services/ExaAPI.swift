import Foundation

/// 抽出来是为了让工具分发逻辑能在单测里跑，不联网（与 `TavilyCalling` 同形）。
protocol ExaCalling {
    func call(tool: String, arguments: [String: Any], apiKey: String) async throws -> String
}

/// Exa 客户端：**搜索 + 读网页都有**（能力矩阵两项都 ✓，`x-api-key` 必填，没有匿名模式）。
///
/// 接口契约（照 exa.ai/docs，并已实际调通、抓过夹具）：
///
/// - 搜索 `POST https://api.exa.ai/search`，体
///   `{"query":…, "numResults":5, "contents":{"text":{"maxCharacters":500}}}`
///   —— 实测返回的 `text` **全部恰好 500 字**，参数生效；
/// - 读网页 `POST https://api.exa.ai/contents`，体
///   `{"urls":[url], "contents":{"text":{"maxCharacters":8000}}}`
///   —— 实测回了 **10689 字**（请求了 8000），**参数不是硬保证**，
///   回传靠 `AIChatToolResult.clamp`（8000）兜底，别指望它自己截；
/// - 读网页响应带 **`statuses[]` 成败表**（`{id, status, source}`，`id` 就是 URL）
///   = Tavily `failed_results` 的对应物：**HTTP 200 也可能有失败条目，必须先查再拼正文**
///   （规则 13 的教训，见 `contentsText`）；
/// - 错误信封 `{requestId, error, tag}`（`error` 是**字符串**，不是对象；
///   `problemMessage` 认不出，`topError` 自己解）：401 Key 无效、402 额度用尽、429 频繁。
///
/// 夹具 `AIHOTTests/Fixtures/exa-search.json`（200，5 条 ×500 字）、`exa-contents.json`
/// （200，1 条 10689 字 + statuses 全 success）与 `exa-error.json`（401 信封）
/// 都是**真抓的字节**；`statuses` 失败分支没有免费触发的办法，用例是合成的（测试里有标注）。
final class ExaAPI: ExaCalling, @unchecked Sendable {

    static let shared = ExaAPI()

    private let searchEndpoint = URL(string: "https://api.exa.ai/search")!
    private let contentsEndpoint = URL(string: "https://api.exa.ai/contents")!
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
        let endpoint: URL
        switch tool {
        case "search":
            endpoint = searchEndpoint
        case "contents":
            endpoint = contentsEndpoint
        default:
            throw APIError(kind: .decoding("exa"), message: "Exa 没有这个工具：\(tool)")
        }

        // 调用方摆好请求体（含嵌套的 contents 配置），这里只负责序列化 POST
        guard JSONSerialization.isValidJSONObject(arguments) else {
            throw APIError(kind: .decoding("exa"), message: "Exa 请求构造失败")
        }
        let body = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            forHTTPHeaderField: "x-api-key"
        )

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
                    message: "地址不是 https，被系统拦下了（Exa 自己是 https，只在地址被改坏时才会发生）"
                )
            }
            throw APIError(
                kind: .transport(error.localizedDescription),
                message: "连不上 Exa：\(error.localizedDescription)"
            )
        } catch {
            throw APIError(kind: .transport(error.localizedDescription), message: "Exa 请求失败：\(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError(kind: .transport("响应不是 HTTP"), message: "Exa 返回了看不懂的响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.apiError(statusCode: http.statusCode, data: data)
        }
        switch tool {
        case "search":
            return try Self.searchText(from: data)
        default:
            return try Self.contentsText(from: data)
        }
    }

    /// 搜索 200 体 → Markdown 结果（`results[]`）。
    static func searchText(from data: Data) throws -> String {
        struct Payload: Decodable {
            struct Item: Decodable {
                let title: String?
                let url: String?
                let text: String?
            }
            let error: String?
            let results: [Item]?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw APIError(kind: .decoding("exa"), message: "Exa 返回了看不懂的内容")
        }
        // 防御：401 已在 apiError 处理，200 带顶层 error 没见过，先查零成本
        let topProblem = trimmed(payload.error)
        if !topProblem.isEmpty {
            throw APIError(kind: .decoding("exa"), message: "Exa 报错：\(topProblem)")
        }
        var sections: [String] = []
        for item in payload.results ?? [] {
            let title = trimmed(item.title)
            let link = trimmed(item.url)
            let snippet = trimmed(item.text)
            guard !title.isEmpty || !link.isEmpty || !snippet.isEmpty else { continue }
            let heading = title.isEmpty ? link : title
            var section = "### \(sections.count + 1). \(heading)"
            if !link.isEmpty, link != heading {
                section += "\n" + link
            }
            if !snippet.isEmpty {
                section += "\n\n" + snippet
            }
            sections.append(section)
        }
        guard !sections.isEmpty else {
            throw APIError(kind: .decoding("exa"), message: "Exa 没有返回可用内容")
        }
        return sections.joined(separator: "\n\n")
    }

    /// 读网页 200 体 → 正文。**先查 `statuses[]` 再拼 `results[].text`**：
    /// 这是 Tavily `failed_results` 的同款陷阱 —— HTTP 200 但目标 URL 提取失败时，
    /// 不先查就会把「失败」当成空正文（或把半截东西）喂给模型。
    static func contentsText(from data: Data) throws -> String {
        struct Payload: Decodable {
            struct Status: Decodable {
                let id: String?
                let status: String?
                // 失败条目的 error 字段没真抓过，全可选（同 Tavily failed_results 的理由）
                let error: String?
            }
            struct Item: Decodable {
                let title: String?
                let url: String?
                let text: String?
            }
            let statuses: [Status]?
            let results: [Item]?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw APIError(kind: .decoding("exa"), message: "Exa 返回了看不懂的内容")
        }
        if let statuses = payload.statuses {
            let failed = statuses.filter { entry in
                guard let status = entry.status?.lowercased(), !status.isEmpty else { return false }
                return status != "success"
            }
            if let first = failed.first {
                let reason = trimmed(first.error)
                let page = trimmed(first.id)
                let status = trimmed(first.status)
                var detail = reason
                if detail.isEmpty, !page.isEmpty {
                    detail = "\(page) 提取失败"
                }
                if detail.isEmpty {
                    detail = status.isEmpty ? "有页面没能提取" : "状态：\(status)"
                }
                throw APIError(kind: .server(-1), message: "Exa 提取失败：\(detail)")
            }
        }
        let contents = (payload.results ?? [])
            .map { trimmed($0.text) }
            .filter { !$0.isEmpty }
        guard !contents.isEmpty else {
            throw APIError(kind: .decoding("exa"), message: "Exa 没有返回可用内容")
        }
        return contents.joined(separator: "\n\n")
    }

    /// 错误信封里 `error` 是字符串 —— `problemMessage` 认不出（它期待对象），自己解。
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
                    "Exa 的 Key 无效或已停用（\(statusCode)）。到「设置 → AI 对话 → 搜索工具」换一个 Key，或停用 Exa 改用其它家"
                )
            )
        }
        if statusCode == 402 {
            return APIError(
                kind: .server(statusCode),
                message: withDetail(
                    "Exa 额度用尽（402）。到「设置 → AI 对话 → 搜索工具」停用 Exa 换一家，或给 Exa 账户充值"
                )
            )
        }
        if statusCode == 429 {
            return APIError(
                kind: .rateLimited(retryAfter: nil),
                message: withDetail(
                    "Exa 请求过于频繁（429），稍等片刻再试；也可到「设置 → AI 对话 → 搜索工具」换一家"
                )
            )
        }
        return APIError(
            kind: .server(statusCode),
            message: "Exa 返回 \(statusCode)" + (detail.map { "：\($0)" } ?? "")
        )
    }

    /// 与 `TavilyAPI.trimmed` 同约定：**返回非可选**（nil 当空串）。
    private static func trimmed(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 把模型请求的工具调用落到 Exa 上（由 `SearchToolChain` 按用户顺序调用；
/// 空 Key 由链先挡，这里是防御）。与 `TavilyToolRunner` 同形。
struct ExaToolRunner: AIChatToolExecuting {
    let apiKey: String
    let api: ExaCalling

    /// 搜索结果条数（夹具就是按 5 抓的）。
    static let searchResults = 5
    /// 搜索内联摘要的截断上限（夹具实测每条恰好 500 字）。
    static let searchSnippetCharacters = 500
    /// 读网页正文字数请求上限（实测服务端不严格遵守，靠 `AIChatToolResult.clamp` 兜底）。
    static let contentsCharacters = 8000

    init(apiKey: String, api: ExaCalling = ExaAPI.shared) {
        self.apiKey = apiKey
        self.api = api
    }

    func execute(call: AIChatToolCall) async -> (text: String, isError: Bool) {
        guard let name = call.name else {
            return AIChatToolResult.failure("工具", "这次调用没有给出工具名")
        }
        // Exa 没有匿名模式（链会先按 Key 过滤，这里是防御）
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AIChatToolResult.failure(
                name,
                "还没填 Exa 的 Key（Exa 不支持匿名）。到「设置 → AI 对话 → 搜索工具」填一个，或停用 Exa"
            )
        }
        switch name {
        case AIChatToolName.webSearch:
            guard let query = call.string("query") else {
                return AIChatToolResult.missingArgument(name)
            }
            do {
                let text = try await api.call(
                    tool: "search",
                    arguments: [
                        "query": query,
                        "numResults": Self.searchResults,
                        "contents": ["text": ["maxCharacters": Self.searchSnippetCharacters]],
                    ],
                    apiKey: apiKey
                )
                return (AIChatToolResult.clamp(text), false)
            } catch let error as APIError {
                return AIChatToolResult.failure(name, error.message)
            } catch {
                return AIChatToolResult.failure(name, error.localizedDescription)
            }
        case AIChatToolName.readURL:
            guard let url = call.string("url") else {
                return AIChatToolResult.missingArgument(name)
            }
            do {
                let text = try await api.call(
                    tool: "contents",
                    arguments: [
                        "urls": [url],
                        "contents": ["text": ["maxCharacters": Self.contentsCharacters]],
                    ],
                    apiKey: apiKey
                )
                return (AIChatToolResult.clamp(text), false)
            } catch let error as APIError {
                return AIChatToolResult.failure(name, error.message)
            } catch {
                return AIChatToolResult.failure(name, error.localizedDescription)
            }
        default:
            return AIChatToolResult.failure(name, "没有这个工具")
        }
    }
}
