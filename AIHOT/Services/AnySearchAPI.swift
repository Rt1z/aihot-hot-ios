import Foundation

/// 抽出来是为了让工具分发逻辑能在单测里跑，不联网。
protocol AnySearchCalling {
    func call(tool: String, arguments: [String: Any], apiKey: String) async throws -> String
}

/// AnySearch 客户端：联网搜索 + 整页提取，模型要的两种工具都由它提供。
///
/// 接口契约（照官方 `doc` 的规格，并已实际调通验证）：
///
/// - `POST https://api.anysearch.com/mcp`，**JSON-RPC 2.0**，method 固定 `"tools/call"`；
/// - 鉴权可选：带 `Authorization: Bearer <key>` 走该 key 的付费额度，不带就是匿名
///   （限速更低）。注意**带了无效 key 不会静默退回匿名**，会直接 401/403；
/// - 工具名：`search`（参数 query / max_results / domain / sub_domain / sub_domain_params）
///   与 `extract`（参数 url，HTML 整页转 Markdown，单页上限 5 万字）；
/// - 返回是**普通 JSON、不是 SSE**：`result.content[0].text`。而那段 text 本身就是
///   排好的 Markdown（标题 + URL + 摘要），可以直接当工具结果交给模型，不必再解析。
final class AnySearchAPI: AnySearchCalling, @unchecked Sendable {

    static let shared = AnySearchAPI()

    private let session: URLSession
    private let endpoint = URL(string: "https://api.anysearch.com/mcp")!

    init(session: URLSession? = nil) {
        if let session = session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.default
        // 搜索一般一两秒就回；提取稍慢。这里不需要 AI 那边那么长的超时。
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    static var clientHeader: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "aihot-ios/\(version)"
    }

    /// 调一个工具，返回它给的文本。失败抛 `APIError`（带接口原话）。
    func call(tool: String, arguments: [String: Any], apiKey: String) async throws -> String {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": tool, "arguments": arguments],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            throw APIError(kind: .decoding("anysearch"), message: "搜索请求构造失败")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.clientHeader, forHTTPHeaderField: "X-Anysearch-Client")
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as CancellationError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .appTransportSecurityRequiresSecureConnection {
                // 只在用户把地址改坏时才会发生；AnySearch 自己是 https
                throw APIError(kind: .transport("ats"), message: "搜索服务地址不被允许（明文 HTTP）")
            }
            throw APIError(
                kind: .offline,
                message: "连不上搜索服务：\(error.localizedDescription)"
            )
        } catch {
            throw APIError(kind: .transport(error.localizedDescription), message: "搜索失败：\(error.localizedDescription)")
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let detail = AIChatAPI.problemMessage(from: data)
            if http.statusCode == 401 || http.statusCode == 403 {
                // 契约里写明了：带了无效 key 不会静默退回匿名
                throw APIError(
                    kind: .server(http.statusCode),
                    message: "AnySearch 的 Key 无效或已停用（\(http.statusCode)）。可以到「设置 → AI 对话」清空它改用匿名，或换一个 Key"
                )
            }
            throw APIError(
                kind: .server(http.statusCode),
                message: "搜索服务返回 \(http.statusCode)\(detail.map { "：\($0)" } ?? "")"
            )
        }

        return try Self.resultText(from: data)
    }

    // MARK: - 响应解析（纯函数，便于单测）

    /// 从 JSON-RPC 响应里取出工具结果文本。
    static func resultText(from data: Data) throws -> String {
        struct Envelope: Decodable {
            struct Result: Decodable {
                struct Item: Decodable {
                    let type: String?
                    let text: String?
                }
                let content: [Item]?
            }
            struct Failure: Decodable {
                let message: String?
            }
            let result: Result?
            let error: Failure?
        }

        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw APIError(kind: .decoding("anysearch"), message: "搜索服务返回了看不懂的内容")
        }

        if let message = envelope.error?.message, !message.isEmpty {
            throw APIError(kind: .server(-1), message: "搜索失败：\(message)")
        }

        let text = (envelope.result?.content ?? [])
            .filter { $0.type == "text" }
            .compactMap { $0.text }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            throw APIError(kind: .decoding("anysearch"), message: "搜索没有返回可用内容")
        }
        return text
    }
}

/// 把模型请求的工具调用落到 AnySearch 上。
///
/// 做成 struct + 可注入的 api，单测就能拿一个假的 api 跑完整循环而不联网。
struct AnySearchToolRunner: AIChatToolExecuting {

    let apiKey: String
    let api: AnySearchCalling

    /// 每次搜索取几条。给 5 条就够模型判断，多了只是多烧 token。
    static let searchResults = 5

    init(apiKey: String, api: AnySearchCalling = AnySearchAPI.shared) {
        self.apiKey = apiKey
        self.api = api
    }

    func execute(call: AIChatToolCall) async -> (text: String, isError: Bool) {
        guard let name = call.name else {
            return AIChatToolResult.failure("工具", "这次调用没有给出工具名")
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
                let text = try await api.call(tool: "extract", arguments: ["url": url], apiKey: apiKey)
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
