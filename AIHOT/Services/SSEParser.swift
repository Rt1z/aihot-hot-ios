import Foundation

/// 从流式回复里认出来的东西（与具体协议无关）。
///
/// 刻意做得很薄：这里只表达「要往界面上写什么」「模型要调哪个工具」「这一轮怎么结束的」，
/// 不携带 thinking 的正文 —— 那些块我们**不回传**（见 AIChatModel 顶部关于「只回文本」的说明）。
///
/// 两家协议的工具调用形状完全不同（Anthropic 是 `tool_use` 块 + `input_json_delta`，
/// OpenAI 兼容是 `delta.tool_calls[]` + `function.arguments` 分片），但都映射到下面
/// 这两个事件上 —— 于是累加器、循环、界面都不必再分协议。
enum AIChatEvent: Equatable {
    /// 正文增量。
    case text(String)
    /// 模型在思考（只用来点亮状态行，不显示内容）。
    case thinking
    /// 模型开始请求调用工具。`id` 是回传 tool_result 时要对的号。
    case toolCallStarted(index: Int, id: String?, name: String?)
    /// 工具参数的增量片段：两家的参数都是分片流式过来的，要按 index 拼起来。
    case toolCallArguments(index: Int, fragment: String)
    /// 这一轮的结束原因：end_turn / tool_use / max_tokens / refusal / pause_turn …
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

/// 把响应体的字节切成**行**（行尾的交上去），空行原样产出。
///
/// 为什么不用平台的 `AsyncSequence.lines`：它**把空行整个丢掉**（CI 实测：
/// `"data: a\n\ndata: b\n\n"` → `["data: a", "data: b"]`，
/// 见 `SSEParserTests.testPlatformLineSplitterDropsBlankLinesWhichIsWhyWeDoNotUseIt`），
/// 而空行是 SSE 分帧的**唯一**依据 —— `SSEFrameReader` 只有见到空行才交出一帧。
/// 后果是固定的：整条流被拼成**一帧** → 拼起来的 JSON 解不出来 → 每个事件都认不出来
/// → 界面上「一个字都没有」加一句看不懂的提示（真机上报回来的正是这个形状：
/// 提示里贴出的开头是一段完好的 OpenAI 兼容分片，却一个事件都没认出来）。
/// 更坏的是**全部夹具用例照旧全绿** —— 它们自己按 `\n` 切好行再喂，恰好绕开了这一段。
///
/// 所以这一段自己切：规则简单到可以**逐字节**钉住（见 `SSEParserTests`）。
///
/// 只认 LF（`0x0A`）一种行尾：CRLF 里的 `\r` 由 `SSEFrameReader.consume` 剥掉
/// （那里本来就在剥）。裸 CR 作行尾（老 Mac 风格）的响应至今没遇到过，真遇到的话
/// 这一路会认不出来 —— 宁可少抽，那时再补。
struct SSELineSplitter {

    /// 单行上限。对方一直不发换行时不能把内存吃光 ——
    /// 超出的部分直接丢弃，那一行本来也解不出来。
    private static let maximumLineLength = 64 * 1024

    private var buffer: [UInt8] = []

    /// 喂一个字节。攒到换行就交出一整行（可能是个空串，那正是分帧的开关）。
    mutating func consume(byte: UInt8) -> String? {
        guard byte == 0x0A else {
            if buffer.count < Self.maximumLineLength { buffer.append(byte) }
            return nil
        }
        return takeLine()
    }

    /// 流结束时调用：最后一行没有以换行收尾时也要交出来（两个夹具就是这么结尾的）。
    mutating func flush() -> String? {
        guard !buffer.isEmpty else { return nil }
        return takeLine()
    }

    private mutating func takeLine() -> String {
        // 非法 UTF-8 交给 String 替换成 U+FFFD：这一行大概率解不出来，
        // 但绝不能因为它就把整条流丢掉。
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        return line
    }
}

// MARK: - Anthropic Messages 协议

/// 把 Anthropic 的 `data:` JSON 认成 `AIChatEvent`。
///
/// 解码用的结构体**每个字段都是可选的、且是扁平类型**：服务端会加新的事件类型
/// 和新的字段（比如 `fallback` 块、`citations_delta`），只要我们不认识的字段
/// 不会导致解码失败，就不会因为对方加功能而挂掉。
///
/// 返回的是**数组**：一帧里可能同时出现多个工具调用的信息。
enum AnthropicSSEDecoder {

    static func decode(_ frame: SSEFrame) -> [AIChatEvent] {
        guard let payload = decodePayload(frame.data) else { return [] }

        switch payload.type {
        case "content_block_delta":
            guard let delta = payload.delta else { return [] }
            switch delta.type {
            case "text_delta":
                guard let text = delta.text, !text.isEmpty else { return [] }
                return [.text(text)]
            case "thinking_delta":
                return [.thinking]
            case "input_json_delta":
                // 工具参数是分片过来的，交给累加器按 index 拼
                guard let index = payload.index, let fragment = delta.partialJson, !fragment.isEmpty else {
                    return []
                }
                return [.toolCallArguments(index: index, fragment: fragment)]
            default:
                // signature_delta / citations_delta：不需要
                return []
            }

        case "content_block_start":
            guard payload.contentBlock?.type == "tool_use", let index = payload.index else { return [] }
            return [.toolCallStarted(
                index: index,
                id: payload.contentBlock?.id,
                name: payload.contentBlock?.name
            )]

        case "message_delta":
            guard let reason = payload.delta?.stopReason else { return [] }
            return [.stopReason(reason)]

        case "message_stop":
            return [.done]

        case "error":
            return [.error(payload.error?.message ?? "流式响应里出现了一个错误")]

        default:
            // message_start / content_block_stop / ping / 以及将来新增的类型：
            // 一律静默跳过，绝不抛错。
            //
            // 注意 fallbacks 打开时，中途切换模型会产生**第二个 message_start**，
            // 所以这里也绝不能假设「一次响应只有一个 message_start」。
            return []
        }
    }

    private static func decodePayload(_ data: String) -> Payload? {
        guard let bytes = data.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: bytes)
    }

    private struct Payload: Decodable {
        let type: String?
        let index: Int?
        let delta: Delta?
        let contentBlock: ContentBlock?
        let error: Failure?

        enum CodingKeys: String, CodingKey {
            case type, index, delta, error
            case contentBlock = "content_block"
        }

        struct Delta: Decodable {
            let type: String?
            let text: String?
            let partialJson: String?
            let stopReason: String?

            enum CodingKeys: String, CodingKey {
                case type, text
                case partialJson = "partial_json"
                case stopReason = "stop_reason"
            }
        }

        struct ContentBlock: Decodable {
            let type: String?
            let id: String?
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
/// 三个坑（DeepSeek / Kimi / GLM / 各种中转站）：
/// - 思考内容走 `delta.reasoning_content`，和 `delta.content` 并列。所以字段
///   全可选 —— 把 content 写成非可选的话，**第一个思考块就会让整条流解码失败**。
/// - 工具调用走 `delta.tool_calls[]`，首个分片带 `id` 与 `function.name`，
///   函数参数 `function.arguments` 是**逐片拼**的字符串。
/// - `data: [DONE]` 不是所有中转站都会发，流也可能直接断掉。收尾由调用方
///   兼顾「收到 [DONE]」和「流自然结束」两种情况。
enum OpenAISSSEDecoder {

    static func decode(_ frame: SSEFrame) -> [AIChatEvent] {
        let data = frame.data
        if data == "[DONE]" { return [.done] }
        guard let bytes = data.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: bytes)
        else { return [] }

        if let message = payload.error?.message {
            return [.error(message)]
        }

        guard let choice = payload.choices?.first else { return [] }

        var events: [AIChatEvent] = []

        if let calls = choice.delta?.toolCalls {
            for call in calls {
                let index = call.index ?? 0
                if let name = call.function?.name, !name.isEmpty {
                    events.append(.toolCallStarted(index: index, id: call.id, name: name))
                } else if let id = call.id, !id.isEmpty {
                    events.append(.toolCallStarted(index: index, id: id, name: nil))
                }
                if let fragment = call.function?.arguments, !fragment.isEmpty {
                    events.append(.toolCallArguments(index: index, fragment: fragment))
                }
            }
            if !events.isEmpty { return events }
        }

        if let finish = choice.finishReason, !finish.isEmpty {
            // "length" 表示被 max_tokens 截断，"tool_calls" 表示要跑工具 —— 界面照实说
            return [.stopReason(finish)]
        }

        if let content = choice.delta?.content, !content.isEmpty {
            return [.text(content)]
        }

        if let reasoning = choice.delta?.reasoningContent, !reasoning.isEmpty {
            return [.thinking]
        }

        return []
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
            let toolCalls: [ToolCall]?

            enum CodingKeys: String, CodingKey {
                case content
                case reasoningContent = "reasoning_content"
                case toolCalls = "tool_calls"
            }
        }

        struct ToolCall: Decodable {
            let index: Int?
            let id: String?
            let function: Function?

            struct Function: Decodable {
                let name: String?
                let arguments: String?
            }
        }

        struct Failure: Decodable {
            let message: String?
        }
    }
}
