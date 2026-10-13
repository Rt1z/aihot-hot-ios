import Foundation

/// 抽出来是为了让工具分发逻辑能在单测里跑，不联网（与 `TavilyCalling` 同形）。
protocol SerperCalling {
    func call(tool: String, arguments: [String: Any], apiKey: String) async throws -> String
}

/// Serper（google.serper.dev）客户端：**只有搜索，没有读网页**（能力矩阵对 `read_url`
/// 是 ✗ —— `SearchToolChain` 会先把它过滤掉，这里是防御）。
///
/// 接口契约（照用户给的接入样例，并已实际调通、抓过夹具）：
///
/// - `POST https://google.serper.dev/search`，头 `X-API-KEY`，体**只有** `{"q": query}`
///   （不做多余字段；`Content-Type: application/json`）；
/// - 成功体在 `organic[]`（position / title / link / snippet / date …）。
///   `date` 格式杂乱不解析；条目缺字段就容缺；
/// - 错误形状**官方文档不可达**，靠随机假 Key 的免费探针抓到真字节：
///   **HTTP 403 `{"message":"Unauthorized.","statusCode":403}`**（夹具 `serper-error.json`，
///   44 字节）。顶层 `message` 恰好是 `AIChatAPI.problemMessage` 认得的形状；
///   200-with-error 的形状没见过，`searchText` 只做防御性检查（见该方法注释）。
///
/// 夹具 `AIHOTTests/Fixtures/serper-search.json`（200，10 条）与 `serper-error.json`
/// 都是**真抓的字节**。
final class SerperAPI: SerperCalling, @unchecked Sendable {

    static let shared = SerperAPI()

    private let endpoint = URL(string: "https://google.serper.dev/search")!
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
            throw APIError(kind: .decoding("serper"), message: "Serper 没有这个工具：\(tool)")
        }

        // 调用方给的是自家参数名（q），这里原样序列化成请求体
        guard JSONSerialization.isValidJSONObject(arguments) else {
            throw APIError(kind: .decoding("serper"), message: "Serper 请求构造失败")
        }
        let body = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            forHTTPHeaderField: "X-API-KEY"
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
                    message: "地址不是 https，被系统拦下了（Serper 自己是 https，只在地址被改坏时才会发生）"
                )
            }
            throw APIError(
                kind: .transport(error.localizedDescription),
                message: "连不上 Serper：\(error.localizedDescription)"
            )
        } catch {
            throw APIError(kind: .transport(error.localizedDescription), message: "Serper 请求失败：\(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError(kind: .transport("响应不是 HTTP"), message: "Serper 返回了看不懂的响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.apiError(statusCode: http.statusCode, data: data)
        }
        return try Self.searchText(from: data)
    }

    /// 200 体 → Markdown 结果。防御性查顶层 `error` / `message`：200 带报错的形状
    /// 没抓过（文档不可达），但先查零成本，查到就抛，绝不把报错当结果。
    static func searchText(from data: Data) throws -> String {
        struct Payload: Decodable {
            struct Item: Decodable {
                let title: String?
                let link: String?
                let snippet: String?
            }
            let error: String?
            let message: String?
            let organic: [Item]?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw APIError(kind: .decoding("serper"), message: "Serper 返回了看不懂的内容")
        }
        let topProblem = trimmed(payload.error)
        if !topProblem.isEmpty {
            throw APIError(kind: .decoding("serper"), message: "Serper 报错：\(topProblem)")
        }
        var sections: [String] = []
        for item in payload.organic ?? [] {
            let title = trimmed(item.title)
            let link = trimmed(item.link)
            let snippet = trimmed(item.snippet)
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
        if sections.isEmpty {
            // 一条都没有时，顶层 message（若有）比「没有内容」更能说明原因
            let message = trimmed(payload.message)
            if !message.isEmpty {
                throw APIError(kind: .decoding("serper"), message: "Serper 报错：\(message)")
            }
            throw APIError(kind: .decoding("serper"), message: "Serper 没有返回可用内容")
        }
        return sections.joined(separator: "\n\n")
    }

    /// 错误体是顶层 `{"message": "Unauthorized.", "statusCode": 403}`
    /// （探针抓的真字节）—— `problemMessage` 正好认 `message`。
    static func apiError(statusCode: Int, data: Data) -> APIError {
        let detail = AIChatAPI.problemMessage(from: data)
        func withDetail(_ base: String) -> String {
            guard let detail = detail, !detail.isEmpty else { return base }
            return base + "。接口原话：" + detail
        }
        if statusCode == 401 || statusCode == 403 {
            return APIError(
                kind: .server(statusCode),
                message: withDetail(
                    "Serper 的 Key 无效或已停用（\(statusCode)）。到「设置 → AI 对话 → 搜索工具」换一个 Key，或停用 Serper 改用其它家"
                )
            )
        }
        if statusCode == 429 {
            return APIError(
                kind: .rateLimited(retryAfter: nil),
                message: withDetail(
                    "Serper 请求过于频繁或额度用尽（429），稍等片刻再试；也可到「设置 → AI 对话 → 搜索工具」换一家"
                )
            )
        }
        return APIError(
            kind: .server(statusCode),
            message: "Serper 返回 \(statusCode)" + (detail.map { "：\($0)" } ?? "")
        )
    }

    /// 与 `TavilyAPI.trimmed` 同约定：**返回非可选**（nil 当空串）。
    private static func trimmed(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 把模型请求的工具调用落到 Serper 上（由 `SearchToolChain` 按用户顺序调用；
/// 空 Key 与 `read_url` 都由链先挡，这里是防御）。与 `TavilyToolRunner` 同形。
struct SerperToolRunner: AIChatToolExecuting {
    let apiKey: String
    let api: SerperCalling

    init(apiKey: String, api: SerperCalling = SerperAPI.shared) {
        self.apiKey = apiKey
        self.api = api
    }

    func execute(call: AIChatToolCall) async -> (text: String, isError: Bool) {
        guard let name = call.name else {
            return AIChatToolResult.failure("工具", "这次调用没有给出工具名")
        }
        // Serper 没有匿名模式（链会先按 Key 过滤，这里是防御）
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AIChatToolResult.failure(
                name,
                "还没填 Serper 的 Key（Serper 不支持匿名）。到「设置 → AI 对话 → 搜索工具」填一个，或停用 Serper"
            )
        }
        switch name {
        case AIChatToolName.webSearch:
            guard let query = call.string("query") else {
                return AIChatToolResult.missingArgument(name)
            }
            do {
                // Serper 的参数名是 q（用户样例里就是它），这里只给这一个字段
                let text = try await api.call(tool: "search", arguments: ["q": query], apiKey: apiKey)
                return (AIChatToolResult.clamp(text), false)
            } catch let error as APIError {
                return AIChatToolResult.failure(name, error.message)
            } catch {
                return AIChatToolResult.failure(name, error.localizedDescription)
            }
        case AIChatToolName.readURL:
            // 链按能力矩阵不会把 read_url 路由到这里；真到了照实回绝，一次网络都不发
            return AIChatToolResult.failure(name, "Serper 只支持搜索，不支持读网页")
        default:
            return AIChatToolResult.failure(name, "没有这个工具")
        }
    }
}
