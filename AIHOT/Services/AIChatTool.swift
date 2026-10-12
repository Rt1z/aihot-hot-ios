import Foundation

/// 交给模型的工具名。两家协议共用同一套名字（`read_url` 取代了原来
/// Anthropic 服务端的 `web_fetch`，现在两条协议都能读原网页）。
enum AIChatToolName {
    static let webSearch = "web_search"
    static let readURL = "read_url"

    static func title(_ name: String) -> String {
        switch name {
        case webSearch: return "正在联网搜索"
        case readURL: return "正在读取网页"
        default: return "正在调用工具"
        }
    }
}

/// 一次完整的工具调用。参数是**分片流式**过来的，这里放的是拼好的结果。
struct AIChatToolCall: Equatable {
    let index: Int
    var id: String?
    var name: String?
    var argumentsJSON: String

    /// 参数解析成字典。模型给空参数是 `{}` 或干脆空串，两种都要能应付；
    /// 解析不出来就返回空字典（调用方据此报「参数无效」，而不是崩掉）。
    var arguments: [String: Any] {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { return [:] }
        return dictionary
    }

    func string(_ key: String) -> String? {
        guard let value = arguments[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 把流式里分片过来的工具调用拼成完整调用。
///
/// 纯逻辑：喂 `AIChatEvent`，出完整调用。两家协议都映射到同样的事件，
/// 所以这里不必知道对面是 Anthropic 还是 OpenAI 兼容。
struct AIChatToolCallAccumulator {

    private var order: [Int] = []
    private var calls: [Int: AIChatToolCall] = [:]

    init() {}

    mutating func consume(_ events: [AIChatEvent]) {
        for event in events {
            consume(event)
        }
    }

    mutating func consume(_ event: AIChatEvent) {
        switch event {
        case .toolCallStarted(let index, let id, let name):
            // 同一个 index 可能出现多次（先给 name，后给 id，或反过来）
            if calls[index] == nil {
                order.append(index)
                calls[index] = AIChatToolCall(index: index, id: nil, name: nil, argumentsJSON: "")
            }
            if let id = id, !id.isEmpty { calls[index]?.id = id }
            if let name = name, !name.isEmpty { calls[index]?.name = name }

        case .toolCallArguments(let index, let fragment):
            if calls[index] == nil {
                order.append(index)
                calls[index] = AIChatToolCall(index: index, id: nil, name: nil, argumentsJSON: "")
            }
            calls[index]?.argumentsJSON += fragment

        default:
            break
        }
    }

    /// 按出现顺序返回。丢掉没有名字的（半截数据，跑不了）。
    var result: [AIChatToolCall] {
        order
            .sorted()
            .compactMap { calls[$0] }
            .filter { call in
                guard let name = call.name else { return false }
                return !name.isEmpty
            }
    }

    var isEmpty: Bool { result.isEmpty }
}

/// 工具执行结果。做成协议是为了让循环的单测不必真的联网。
protocol AIChatToolExecuting {
    /// 返回要作为 tool_result 回传给模型的文本。
    /// 失败时返回 `(文本, true)` —— 用 `is_error` 回传，模型会自己改主意或换个说法，
    /// 比整轮报错好。
    func execute(call: AIChatToolCall) async -> (text: String, isError: Bool)
}

enum AIChatToolResult {

    /// 回传给模型的文本上限。
    ///
    /// AnySearch 的 `extract` 单页能返回到 5 万字 —— 直接回传会顶爆上下文、也很贵。
    /// 截断时明确写出被截断，免得模型以为看完了。
    static let maximumCharacters = 8000

    static func clamp(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumCharacters else { return trimmed }
        return String(trimmed.prefix(maximumCharacters)) + "\n…（内容过长，已截断）"
    }

    static func missingArgument(_ name: String) -> (text: String, isError: Bool) {
        (text: "调用 \(name) 时缺少必需的参数，请换一种方式再试。", isError: true)
    }

    static func failure(_ name: String, _ message: String) -> (text: String, isError: Bool) {
        (text: "\(name) 执行失败：\(message)", isError: true)
    }
}
