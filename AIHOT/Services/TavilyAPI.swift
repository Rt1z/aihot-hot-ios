import Foundation

/// 抽出来是为了让工具分发逻辑能在单测里跑，不联网（与 `AnySearchCalling` 同形）。
protocol TavilyCalling {
    func call(tool: String, arguments: [String: Any], apiKey: String) async throws -> String
}

/// Tavily 客户端：联网搜索 + 整页提取，五家搜索工具之一（见 `SearchToolChain`）。
///
/// 接口契约（照官方文档 docs.tavily.com，并已实际调通、抓过夹具）：
///
/// - `POST https://api.tavily.com/search` 与 `POST https://api.tavily.com/extract`，
///   body 就是**普通 JSON 对象**（不是 AnySearch 那种 JSON-RPC）；
/// - 鉴权 `Authorization: Bearer <key>` **必填** —— 与 AnySearch 不同，Tavily
///   **没有匿名模式**，所以空 key 在 `TavilyToolRunner` 里就被挡住、根本不发网络；
/// - `search` 的结果在 `results[]`（title / url / content），`answer` 可能为 null；
///   `extract` 的正文是 `results[].raw_content`（本身就是 Markdown），请求要带
///   `format: "markdown"`，参数名是 `urls`（**数组**）而不是 `url`；
/// - 失败主要靠 **HTTP 状态码**（401/403 Key 无效、429 频繁 …），原因写在响应体里。
///
/// 但有一个 AnySearch `isError` 的同款陷阱：**HTTP 200 也可能带非空的 `failed_results`**
/// （多 URL 提取时部分失败）。只看状态码会把「一半失败」当成功喂给模型 —— 所以
/// `extractText` 必须先查 `failed_results`。规则 13 的教训：失败形状只查一种，
/// 错误文案就会被当成结果静默流出。
///
/// 两份夹具 `AIHOTTests/Fixtures/tavily-search.json` / `tavily-extract.json` 是**真抓的**
/// 200 响应；错误体的用例是合成的（真实错误形状没抓过），测试里有标注。
final class TavilyAPI: TavilyCalling, @unchecked Sendable {

    static let shared = TavilyAPI()

    private let session: URLSession
    private let searchEndpoint = URL(string: "https://api.tavily.com/search")!
    private let extractEndpoint = URL(string: "https://api.tavily.com/extract")!

    init(session: URLSession? = nil) {
        if let session = session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.default
        // 搜索一般一两秒就回；extract 稍慢（整页正文）。与 AnySearch 同一档超时。
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    /// 调一个工具，返回它给的文本。失败抛 `APIError`（带接口原话）。
    ///
    /// `arguments` 原样作为请求体（与 AnySearch 的 JSON-RPC 包裹不同）——
    /// 由 `TavilyToolRunner` 负责摆成 Tavily 认的形状（`urls` 数组、`format` 等）。
    func call(tool: String, arguments: [String: Any], apiKey: String) async throws -> String {
        let endpoint: URL
        switch tool {
        case "search": endpoint = searchEndpoint
        case "extract": endpoint = extractEndpoint
        default:
            throw APIError(kind: .decoding("tavily"), message: "Tavily 没有这个工具：\(tool)")
        }

        guard let body = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]) else {
            throw APIError(kind: .decoding("tavily"), message: "搜索请求构造失败")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // key 必填（没有匿名模式）。空 key 由 TavilyToolRunner 先挡；真要裸发会吃到 401，
        // 那条走 apiError 的主路径。
        request.setValue(
            "Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
            forHTTPHeaderField: "Authorization"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as CancellationError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .appTransportSecurityRequiresSecureConnection {
                // 只在用户把地址改坏时才会发生；Tavily 自己是 https
                throw APIError(kind: .transport("ats"), message: "搜索服务地址不被允许（明文 HTTP）")
            }
            throw APIError(
                kind: .offline,
                message: "连不上 Tavily：\(error.localizedDescription)"
            )
        } catch {
            throw APIError(kind: .transport(error.localizedDescription), message: "Tavily 请求失败：\(error.localizedDescription)")
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw Self.apiError(statusCode: http.statusCode, data: data)
        }

        switch tool {
        case "search": return try Self.searchText(from: data)
        default: return try Self.extractText(from: data)
        }
    }

    // MARK: - 响应解析（纯函数，便于单测）

    /// `search` 响应 → 模型可直接读的 Markdown。夹具 `tavily-search.json` 钉住。
    ///
    /// 形状：`### {序号}. {标题}\n{URL}\n\n{摘要}`，条目之间空行分隔；
    /// `answer` 非空时用引用块前置（夹具里是 null，所以正常路径不出现）。
    static func searchText(from data: Data) throws -> String {
        struct Payload: Decodable {
            struct Item: Decodable {
                let title: String?
                let url: String?
                let content: String?
            }
            let answer: String?
            let results: [Item]?
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw APIError(kind: .decoding("tavily"), message: "Tavily 返回了看不懂的内容")
        }

        var sections: [String] = []
        for item in payload.results ?? [] {
            let title = trimmed(item.title)
            let url = trimmed(item.url)
            let content = trimmed(item.content)
            // 宁可少抽，不可抽错：没有标题也没有正文的空壳条目直接跳过
            guard !title.isEmpty || !content.isEmpty else { continue }

            var section = "### \(sections.count + 1). \(title.isEmpty ? url : title)"
            if !title.isEmpty, !url.isEmpty { section += "\n" + url }
            if !content.isEmpty { section += "\n\n" + content }
            sections.append(section)
        }
        guard !sections.isEmpty else {
            throw APIError(kind: .decoding("tavily"), message: "Tavily 没有返回可用内容")
        }

        var text = sections.joined(separator: "\n\n")
        let answer = trimmed(payload.answer)
        if !answer.isEmpty {
            text = "> \(answer)\n\n" + text
        }
        return text
    }

    /// `extract` 响应 → 正文 Markdown。夹具 `tavily-extract.json` 钉住。
    ///
    /// **先查 `failed_results`**：HTTP 200 也可能带失败条目（Tavily 版的 `isError` 陷阱），
    /// 不查这一项，「提取失败」的说明会被当成正文喂给模型。
    static func extractText(from data: Data) throws -> String {
        struct Payload: Decodable {
            struct Failed: Decodable {
                let url: String?
                let error: String?
                let message: String?
            }
            struct Item: Decodable {
                let title: String?
                let url: String?
                let rawContent: String?

                enum CodingKeys: String, CodingKey {
                    case title, url
                    case rawContent = "raw_content"
                }
            }
            let failedResults: [Failed]?
            let results: [Item]?

            enum CodingKeys: String, CodingKey {
                case results
                case failedResults = "failed_results"
            }
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw APIError(kind: .decoding("tavily"), message: "Tavily 返回了看不懂的内容")
        }

        // failed_results 的条目形状没有真抓过（夹具里是 []），字段全可选：
        // 认得出原因就说原因，认不出也必须整块报错，绝不把失败当正文。
        if let failed = payload.failedResults, !failed.isEmpty {
            let first = failed[0]
            let reason = trimmed(first.error).isEmpty ? trimmed(first.message) : trimmed(first.error)
            let page = trimmed(first.url)
            var detail = reason
            if detail.isEmpty {
                detail = page.isEmpty ? "有页面没能提取" : "\(page) 提取失败"
            }
            throw APIError(kind: .server(-1), message: "Tavily 提取失败：\(detail)")
        }

        let contents = (payload.results ?? [])
            .map { trimmed($0.rawContent) }
            .filter { !$0.isEmpty }
        guard !contents.isEmpty else {
            throw APIError(kind: .decoding("tavily"), message: "Tavily 没有返回可用内容")
        }
        // raw_content 本身是 Markdown（夹具里以页面自己的标题行开头），原样交给模型
        return contents.joined(separator: "\n\n")
    }

    /// 非 2xx → `APIError`。401/403 在这里就是**主路径**（不像 AnySearch 那样只是兜底）。
    static func apiError(statusCode: Int, data: Data) -> APIError {
        if statusCode == 401 || statusCode == 403 {
            return APIError(
                kind: .server(statusCode),
                message: "Tavily 的 Key 无效或已停用（\(statusCode)）。到「设置 → AI 对话 → 搜索工具」换一个 Key，或停用 Tavily 改用其它家"
            )
        }
        if statusCode == 429 {
            return APIError(
                kind: .rateLimited(retryAfter: nil),
                message: "Tavily 请求过于频繁（429），稍等片刻再试"
            )
        }
        let detail = AIChatAPI.problemMessage(from: data)
        return APIError(
            kind: .server(statusCode),
            message: "Tavily 返回 \(statusCode)\(detail.map { "：\($0)" } ?? "")"
        )
    }

    private static func trimmed(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 把模型请求的工具调用落到 Tavily 上（与 `AnySearchToolRunner` 同形，
/// 由 `SearchToolChain` 按用户顺序调用；空 Key 由链先挡，这里是防御）。与 AnySearch 的两处不同：
///
/// - **没有匿名模式**：key 为空时不发网络，直接回一句可照做的话；
/// - `extract` 的参数是 `urls`（数组）+ `format: "markdown"`，而 AnySearch 是单个 `url`。
///
/// 做成 struct + 可注入的 api，单测就能拿一个假的 api 跑完整循环而不联网。
struct TavilyToolRunner: AIChatToolExecuting {

    let apiKey: String
    let api: TavilyCalling

    /// 每次搜索取几条。给 5 条就够模型判断，多了只是多烧 token。
    static let searchResults = 5

    init(apiKey: String, api: TavilyCalling = TavilyAPI.shared) {
        self.apiKey = apiKey
        self.api = api
    }

    func execute(call: AIChatToolCall) async -> (text: String, isError: Bool) {
        guard let name = call.name else {
            return AIChatToolResult.failure("工具", "这次调用没有给出工具名")
        }

        // Tavily 没有匿名模式 —— 没 key 就别发网络，回一句能照做的话
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AIChatToolResult.failure(
                name,
                "还没填 Tavily 的 Key（Tavily 不支持匿名）。到「设置 → AI 对话 → 搜索工具」填一个，或停用 Tavily"
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
                    arguments: ["query": query, "max_results": Self.searchResults],
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
                // Tavily 的提取参数是 urls 数组 + format（见类头注释），不是单个 url
                let text = try await api.call(
                    tool: "extract",
                    arguments: ["urls": [url], "format": "markdown"],
                    apiKey: apiKey
                )
                return (AIChatToolResult.clamp(text), false)
            } catch let error as APIError {
                return AIChatToolResult.failure(name, error.message)
            } catch {
                return AIChatToolResult.failure(name, error.localizedDescription)
            }

        default:
            // 模型偶尔会编一个不存在的工具名，照实回绝就行
            return AIChatToolResult.failure(name, "没有这个工具")
        }
    }
}
