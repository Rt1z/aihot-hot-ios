import Foundation

/// 一次流式请求的结果。
enum AIChatStreamResponse {
    /// 正常的 SSE 流：由调用方逐行读。
    case stream(URLSession.AsyncBytes)
    /// 有些中转站会忽略 `stream: true`，一次性返回完整 JSON。
    /// 不认这个分支的话，遇到这类中转站只会得到一个空气泡、还不报错。
    case complete(String)
}

/// AI 对话的传输层。两套协议共用这一个入口，差异都在 AIChatRequestBuilder 里。
final class AIChatAPI: @unchecked Sendable {

    static let shared = AIChatAPI()

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session = session {
            self.session = session
            return
        }

        let configuration = URLSessionConfiguration.default
        // **刻意不复用 AIHOTAPI 那个 session**：它是 15 秒空闲 / 30 秒总时长，
        // 而带思考又联网的一轮轻松超过 30 秒 —— 会把每个请求都掐死在 30 秒，
        // 而且现象看起来像「接口坏了」，最难查。这里给足时间。
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = false
        // 流式响应绝不能被缓存
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": AIChatAPI.userAgent]

        self.session = URLSession(configuration: configuration)
    }

    static var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "AIHOT-iOS/\(version) (personal use; +https://aihot.news)"
    }

    // MARK: - 对话

    func streamChat(
        config: AIChatConfig,
        system: String,
        newsContext: String,
        turns: [AIChatTurn]
    ) async throws -> AIChatStreamResponse {
        guard let url = AIChatRequestBuilder.chatEndpoint(for: config) else {
            throw APIError(kind: .transport("bad url"), message: "接口地址不可用，请到「设置 → AI 对话」检查")
        }

        let body: Data?
        switch config.chatProtocol {
        case .anthropicMessages:
            body = AIChatRequestBuilder.anthropicBody(
                config: config, system: system, newsContext: newsContext, turns: turns
            )
        case .openAICompatible:
            body = AIChatRequestBuilder.openAICompatibleBody(
                config: config, system: system, newsContext: newsContext, turns: turns
            )
        }
        guard let payload = body else {
            throw APIError(kind: .decoding("body"), message: "请求构造失败")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        for (field, value) in AIChatRequestBuilder.headers(for: config) {
            request.setValue(value, forHTTPHeaderField: field)
        }

        return try await perform(request, chatProtocol: config.chatProtocol)
    }

    private func perform(
        _ request: URLRequest,
        chatProtocol: AIChatProtocol
    ) async throws -> AIChatStreamResponse {
        let outcome: (URLSession.AsyncBytes, URLResponse)
        do {
            outcome = try await session.bytes(for: request)
        } catch let error as CancellationError {
            throw error
        } catch let error as URLError {
            // 取消要原样抛出去：用户点「停止」或关窗不是错误，
            // 包成普通错误的话每次中途停止都会弹一个错误条。
            if error.code == .cancelled { throw CancellationError() }
            throw Self.apiError(from: error)
        } catch {
            throw APIError(kind: .transport(error.localizedDescription), message: "网络错误：\(error.localizedDescription)")
        }

        let (bytes, response) = outcome

        guard let http = response as? HTTPURLResponse else {
            throw APIError(kind: .transport("no http response"), message: "响应异常")
        }

        guard (200...299).contains(http.statusCode) else {
            let body = try await Self.drain(bytes)
            throw Self.apiError(from: http, body: body)
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("text/event-stream") {
            return .stream(bytes)
        }

        // 不是 SSE：有些中转站直接把整段 JSON 回给我们
        let body = try await Self.drain(bytes)
        return .complete(Self.completeText(from: body, chatProtocol: chatProtocol))
    }

    // MARK: - 测试连接

    /// 「测试连接」：打模型列表，**不产生生成计费**。
    /// 顺带核对配置的模型 id 在不在返回列表里 —— 把「绿不绿」变成
    /// 「你的模型名是不是打错了 / 这个账号能不能用这个模型」。
    func testConnection(config: AIChatConfig) async -> Result<String, APIError> {
        guard let url = AIChatRequestBuilder.modelsEndpoint(for: config) else {
            return .failure(APIError(kind: .transport("bad url"), message: "接口地址不可用"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (field, value) in AIChatRequestBuilder.headers(for: config) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        // 列表接口不要 SSE
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(APIError(kind: .transport("no http response"), message: "响应异常"))
            }
            guard (200...299).contains(http.statusCode) else {
                return .failure(Self.apiError(from: http, body: data))
            }
            return .success(Self.describeModels(data: data, wanted: config.model))
        } catch is CancellationError {
            return .failure(APIError(kind: .transport("cancelled"), message: "已取消"))
        } catch let error as URLError {
            return .failure(Self.apiError(from: error))
        } catch {
            return .failure(APIError(kind: .transport(error.localizedDescription), message: "网络错误：\(error.localizedDescription)"))
        }
    }

    // MARK: - 响应体解析（纯函数，便于单测）

    static func describeModels(data: Data, wanted: String) -> String {
        struct Envelope: Decodable {
            struct Model: Decodable { let id: String? }
            let data: [Model]?
        }
        let ids = ((try? JSONDecoder().decode(Envelope.self, from: data))?.data ?? []).compactMap { $0.id }
        guard !ids.isEmpty else { return "连接正常（返回里没有模型列表）" }
        if ids.contains(wanted) {
            return "连接正常 · 共 \(ids.count) 个模型 · 已包含 \(wanted)"
        }
        return "连接正常，但返回的 \(ids.count) 个模型里没有「\(wanted)」，请核对模型名"
    }

    /// 非 SSE 的完整响应：Anthropic 取 `content[].text`，OpenAI 兼容取
    /// `choices[0].message.content`。
    static func completeText(from data: Data, chatProtocol: AIChatProtocol) -> String {
        switch chatProtocol {
        case .anthropicMessages:
            struct Envelope: Decodable {
                struct Block: Decodable {
                    let type: String?
                    let text: String?
                }
                let content: [Block]?
            }
            let blocks = (try? JSONDecoder().decode(Envelope.self, from: data))?.content ?? []
            return blocks.filter { $0.type == "text" }.compactMap { $0.text }.joined()

        case .openAICompatible:
            struct Envelope: Decodable {
                struct Choice: Decodable {
                    struct Message: Decodable { let content: String? }
                    let message: Message?
                }
                let choices: [Choice]?
            }
            return (try? JSONDecoder().decode(Envelope.self, from: data))?.choices?.first?.message?.content ?? ""
        }
    }

    /// 把接口自己的错误原话带出来。
    ///
    /// 这是整个功能里最值钱的可调试性决定：Anthropic 的 400 会带着
    /// 「Extra inputs are not permitted」这种精确说明，只显示「请求失败 (400)」
    /// 会把一行代码能修的问题变成一次盲改 + 一次重新侧载。
    static func apiError(from http: HTTPURLResponse, body: Data) -> APIError {
        if let message = problemMessage(from: body) {
            return APIError(kind: .server(http.statusCode), message: "\(http.statusCode)：\(message)")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            return APIError(
                kind: .server(http.statusCode),
                message: "密钥无效或没有权限（\(http.statusCode)），请到「设置 → AI 对话」检查"
            )
        }
        return APIError(kind: .server(http.statusCode), message: "接口返回 \(http.statusCode)")
    }

    /// 两家的错误体：Anthropic 是 `{"type":"error","error":{"message":…}}`，
    /// OpenAI 兼容是 `{"error":{"message":…}}`；也有中转站直接回纯文本。
    static func problemMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        struct Envelope: Decodable {
            struct Inner: Decodable { let message: String? }
            let error: Inner?
            let message: String?
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            if let message = envelope.error?.message, !message.isEmpty { return message }
            if let message = envelope.message, !message.isEmpty { return message }
        }

        let text = String(decoding: data.prefix(400), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - 内部

    private static func drain(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var buffer: [UInt8] = []
        buffer.reserveCapacity(8192)
        for try await byte in bytes {
            buffer.append(byte)
        }
        return Data(buffer)
    }

    private static func apiError(from error: URLError) -> APIError {
        switch error.code {
        case .cancelled:
            return APIError(kind: .transport("cancelled"), message: "已取消")
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut, .dataNotAllowed:
            return APIError(kind: .offline, message: "网络不可用或超时，请检查网络后重试")
        case .appTransportSecurityRequiresSecureConnection:
            // 见 README：本机策略不放行明文 HTTP
            return APIError(
                kind: .transport("ats"),
                message: "接口地址是 http，iOS 默认不允许明文连接。请改用 https（或按 README 为该地址单独加例外）"
            )
        default:
            return APIError(kind: .transport(error.localizedDescription), message: "网络错误：\(error.localizedDescription)")
        }
    }
}
