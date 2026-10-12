import Foundation

/// 从流式回复里认出来的东西（与具体协议无关）。
///
/// 刻意做得很薄：这里只表达「要往界面上写什么」和「这一轮怎么结束的」，
/// 不携带 thinking / 工具结果的原文 —— 那些块我们**不回传**（见 AIChatModel
/// 顶部关于「只回文本」的说明）。
enum AIChatEvent: Equatable {
    /// 正文增量。
    case text(String)
    /// 模型在思考（只用来点亮状态行，不显示内容）。
    case thinking
    /// 服务端工具（web_search / web_fetch）开始跑。
    case toolStarted(name: String)
    /// 这一轮的结束原因：end_turn / max_tokens / refusal / pause_turn …
    case stopReason(String)
    case error(String)
    case done
}

/// 一帧 SSE（一次 `\n\n` 之间的内容）。
struct SSEFrame: Equatable {
    /// `event:` 行的值。Anthropic 会发，但**权威是 data JSON 里的 type 字段**，
    /// 所以这个值只用于排查，不参与判断。
    let event: String?
    /// `data:` 行的内容；多行 data 按规范用 `\n` 连接。
    let data: String
}

/// SSE 分帧器：只负责把字节流切成帧，不碰 JSON。
///
/// 按 WHATWG 的 EventSource 规范处理几个容易被忽略的点：
/// - 空行 = 一帧结束；
/// - 以 `:` 开头的是注释行（有些中转站用它做心跳），整行丢掉；
/// - `data:` 后面**最多剥掉一个**前导空格（`data:  x` 的值是 `" x"`）；
/// - 多行 `data:` 用 `\n` 连接；
/// - 字段名后面可以没有冒号（裸 `data` 等价于空值）；
/// - 行尾允许 `\r\n`（有些中转站发 CRLF）。
///
/// 做成 struct 而不是「把整段响应一次解析完」，是因为流式下每次只拿到一行。
struct SSEFrameReader {

    private var eventName: String?
    private var dataLines: [String] = []

    init() {}

    /// 喂一行（不含行尾）。返回 nil 表示「这一行还没凑成一帧」。
    mutating func consume(line rawLine: String) -> SSEFrame? {
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }

        if line.isEmpty {
            return flush()
        }

        // 注释/心跳行
        if line.hasPrefix(":") { return nil }

        let (field, value) = Self.split(line)

        switch field {
        case "event":
            eventName = value
        case "data":
            dataLines.append(value)
        default:
            // id / retry / 其它字段：我们这个场景用不到
            break
        }
        return nil
    }

    /// 流结束时调用：最后一段没有以空行收尾时，把它当成一帧。
    mutating func flush() -> SSEFrame? {
        guard !dataLines.isEmpty || eventName != nil else { return nil }
        let frame = SSEFrame(event: eventName, data: dataLines.joined(separator: "\n"))
        eventName = nil
        dataLines.removeAll()
        return frame
    }

    /// 拆 `字段: 值`，并按规范只剥掉一个前导空格。
    private static func split(_ line: String) -> (field: String, value: String) {
        guard let colon = line.firstIndex(of: ":") else {
            return (line, "")
        }
        let field = String(line[line.startIndex..<colon])
        var value = String(line[line.index(after: colon)...])
        if value.hasPrefix(" ") { value.removeFirst() }
        return (field, value)
    }
}

// MARK: - Anthropic Messages 协议

/// 把 Anthropic 的 `data:` JSON 认成 `AIChatEvent`。
///
/// 解码用的结构体**每个字段都是可选的、且是扁平类型**：服务端会加新的事件类型
/// 和新的字段（比如 `fallback` 块、`citations_delta`），只要我们不认识的字段
/// 不会导致解码失败，就不会因为对方加功能而挂掉。
enum AnthropicSSEDecoder {

    static func decode(_ frame: SSEFrame) -> AIChatEvent? {
        guard let payload = decodePayload(frame.data) else { return nil }

        switch payload.type {
        case "content_block_delta":
            guard let delta = payload.delta else { return nil }
            switch delta.type {
            case "text_delta":
                guard let text = delta.text, !text.isEmpty else { return nil }
                return .text(text)
            case "thinking_delta":
                return .thinking
            default:
                // signature_delta / input_json_delta / citations_delta：不需要
                return nil
            }

        case "content_block_start":
            // 服务端工具开始跑 —— 用来显示「正在联网搜索…」
            guard payload.contentBlock?.type == "server_tool_use" else { return nil }
            return .toolStarted(name: payload.contentBlock?.name ?? "")

        case "message_delta":
            guard let reason = payload.delta?.stopReason else { return nil }
            return .stopReason(reason)

        case "message_stop":
            return .done

        case "error":
            return .error(payload.error?.message ?? "流式响应里出现了一个错误")

        default:
            // message_start / content_block_stop / ping / 以及将来新增的类型：
            // 一律静默跳过，绝不抛错。
            //
            // 注意 fallbacks 打开时，中途切换模型会产生**第二个 message_start**，
            // 所以这里也绝不能假设「一次响应只有一个 message_start」。
            return nil
        }
    }

    private static func decodePayload(_ data: String) -> Payload? {
        guard let bytes = data.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: bytes)
    }

    private struct Payload: Decodable {
        let type: String?
        let delta: Delta?
        let contentBlock: ContentBlock?
        let error: Failure?

        enum CodingKeys: String, CodingKey {
            case type, delta, error
            case contentBlock = "content_block"
        }

        struct Delta: Decodable {
            let type: String?
            let text: String?
            let stopReason: String?

            enum CodingKeys: String, CodingKey {
                case type, text
                case stopReason = "stop_reason"
            }
        }

        struct ContentBlock: Decodable {
            let type: String?
            let name: String?
        }

        struct Failure: Decodable {
            let message: String?
        }
    }
}

// MARK: - OpenAI 兼容协议（chat/completions）

/// 把 OpenAI 兼容端点的 `data:` JSON 认成 `AIChatEvent`。
///
/// 两个坑（DeepSeek / Kimi / GLM / 各种中转站）：
/// - 思考内容走 `delta.reasoning_content`，和 `delta.content` 并列。所以字段
///   全可选——把 content 写成非可选的话，**第一个思考块就会让整条流解码失败**。
/// - `data: [DONE]` 不是所有中转站都会发，流也可能直接断掉。收尾由调用方
///   兼顾「收到 [DONE]」和「流自然结束」两种情况。
enum OpenAISSSEDecoder {

    static func decode(_ frame: SSEFrame) -> AIChatEvent? {
        let data = frame.data
        if data == "[DONE]" { return .done }
        guard let bytes = data.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: bytes)
        else { return nil }

        if let message = payload.error?.message {
            return .error(message)
        }

        guard let choice = payload.choices?.first else { return nil }

        if let finish = choice.finishReason, !finish.isEmpty {
            // length 表示被 max_tokens 截断 —— 界面要照实说
            return .stopReason(finish)
        }

        if let content = choice.delta?.content, !content.isEmpty {
            return .text(content)
        }

        if let reasoning = choice.delta?.reasoningContent, !reasoning.isEmpty {
            return .thinking
        }

        return nil
    }

    private struct Payload: Decodable {
        let choices: [Choice]?
        let error: Failure?

        struct Choice: Decodable {
            let delta: Delta?
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case delta
                case finishReason = "finish_reason"
            }
        }

        struct Delta: Decodable {
            let content: String?
            let reasoningContent: String?

            enum CodingKeys: String, CodingKey {
                case content
                case reasoningContent = "reasoning_content"
            }
        }

        struct Failure: Decodable {
            let message: String?
        }
    }
}
