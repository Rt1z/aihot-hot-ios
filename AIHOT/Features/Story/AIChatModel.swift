import Combine
import Foundation

/// 界面上的一条消息。
struct AIChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: AIChatTurn.Role
    var text: String
    var isStreaming = false
}

/// 详情页那个对话弹窗的状态与流式循环。
///
/// 只活在这次弹窗打开期间：**不落盘**，关掉即随视图销毁（这也是为什么这里
/// 没有任何持久化代码）。
///
/// 工具循环：模型可以要求调用 `web_search` / `read_url`，由 AnySearch 执行，
/// 结果作为 tool_result 回传，直到它给出最终回答。两家协议的工具块形状完全不同，
/// 但都先被 `SSEParser` 归一成同一套事件、再由 `AIChatToolCallAccumulator` 拼好，
/// 所以这个循环本身不必分协议。
///
/// **跨轮只回文本**：本轮的工具块只在本轮的请求里带上（见 AIChatRequestBuilder）。
@MainActor
final class AIChatModel: ObservableObject {

    @Published private(set) var messages: [AIChatMessage] = []
    @Published var input: String = ""
    @Published private(set) var isStreaming = false
    /// 状态行：思考中 / 正在联网搜索：<关键词> / 正在读取网页
    @Published private(set) var statusText: String?
    @Published private(set) var notice: String?
    /// 每刷新一次 +1，界面据此滚到底（用 Int 而不是监听 messages：
    /// 边流边比一个越来越长的字符串数组是 O(n²)）。
    @Published private(set) var scrollTick = 0

    private let api: AIChatAPI
    private var streamTask: Task<Void, Never>?
    /// 攒起来的增量，还没刷进 messages。
    private var pendingText = ""
    private var flushTask: Task<Void, Never>?

    /// 攒多久刷一次。text_delta 常常只有 1–5 个字，每个都改 @Published
    /// 会让 SwiftUI 逐字重排、长回复明显卡顿。
    private static let flushInterval: Duration = .milliseconds(70)

    /// 一次提问里最多跑几轮工具。防止模型来回搜个没完 —— 每轮都是钱。
    private static let maximumToolRounds = 5

    init(api: AIChatAPI = .shared) {
        self.api = api
    }

    var canSend: Bool {
        !isStreaming && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 发送

    func send(item: HotTopic, story: Story?, prefetchedDigest: String?) {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isStreaming else { return }

        guard let config = AppSettings.currentAIChatConfig() else {
            notice = "还没配好 AI 接口（地址 / 模型），请到「设置 → AI 对话」填写"
            return
        }
        guard !config.apiKey.isEmpty else {
            notice = "还没填 API Key，请到「设置 → AI 对话」填写"
            return
        }

        input = ""
        notice = nil
        statusText = nil
        pendingText = ""

        messages.append(AIChatMessage(role: .user, text: question))
        let history = turnsForRequest()
        messages.append(AIChatMessage(role: .assistant, text: "", isStreaming: true))
        isStreaming = true
        bumpScroll()

        let newsContext = AIChatNewsContext.make(
            item: item, story: story, prefetchedDigest: prefetchedDigest
        )
        let system = AIChatNewsContext.system
        let searchKey = AppSettings.anySearchKey()

        streamTask = Task { [weak self] in
            await self?.run(
                config: config,
                system: system,
                newsContext: newsContext,
                history: history,
                searchKey: searchKey
            )
        }
    }

    /// 停止生成。不停止的话请求会继续跑、继续计费，而界面上已经看不见了。
    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    func reset() {
        stop()
        messages.removeAll()
        pendingText = ""
        notice = nil
        statusText = nil
        flushTask?.cancel()
        flushTask = nil
    }

    // MARK: - 流式循环

    /// 一轮流式读取攒出来的东西。
    private struct StreamedRound {
        var text = ""
        var toolCalls: [AIChatToolCall] = []
        var stopReason: String?
        var sawDone = false
    }

    private func run(
        config: AIChatConfig,
        system: String,
        newsContext: String,
        history: [AIChatTurn],
        searchKey: String
    ) async {
        defer { finishStreaming() }

        var toolRounds: [AIChatToolRound] = []

        do {
            while true {
                let response = try await api.streamChat(
                    config: config,
                    system: system,
                    newsContext: newsContext,
                    turns: history,
                    toolRounds: toolRounds
                )

                var round = StreamedRound()
                switch response {
                case .complete(let text):
                    // 中转站没走流式：一次性给完整回答，也就没有工具可跑
                    append(text)
                    flushNow()
                    return

                case .stream(let bytes):
                    round = try await consume(bytes, chatProtocol: config.chatProtocol)
                }

                // 只要有工具调用就跑 —— 不看 stop_reason：有些中转站给了
                // tool_calls 却把 finish_reason 报成 "stop"。
                guard !round.toolCalls.isEmpty else {
                    applyStopReason(round.stopReason, sawDone: round.sawDone)
                    return
                }

                guard toolRounds.count < Self.maximumToolRounds else {
                    notice = "这一轮已经查了 \(Self.maximumToolRounds) 次，先说到这。"
                    return
                }

                let results = try await execute(round.toolCalls, searchKey: searchKey)
                toolRounds.append(
                    AIChatToolRound(
                        assistantText: round.text,
                        calls: round.toolCalls,
                        results: results
                    )
                )
                // 下一轮接着往同一个气泡里写
                setStatus("正在整理…")
            }
        } catch is CancellationError {
            // 用户点了「停止」或关掉了弹窗：这是正常收场，不是错误。
            // 不单独接住的话，每次中途停止都会弹一个错误条。
        } catch let error as URLError where error.code == .cancelled {
            // 同上的另一种形态
        } catch let error as APIError {
            // 接口自己的原话已经在 message 里了
            notice = error.message
        } catch {
            notice = error.localizedDescription
        }
    }

    private func consume(
        _ bytes: URLSession.AsyncBytes,
        chatProtocol: AIChatProtocol
    ) async throws -> StreamedRound {
        var reader = SSEFrameReader()
        var accumulator = AIChatToolCallAccumulator()
        var round = StreamedRound()

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let frame = reader.consume(line: line) else { continue }
            try process(decode(frame, chatProtocol: chatProtocol), round: &round, accumulator: &accumulator)
        }
        if let frame = reader.flush() {
            try process(decode(frame, chatProtocol: chatProtocol), round: &round, accumulator: &accumulator)
        }

        flushNow()
        round.toolCalls = accumulator.result
        return round
    }

    private func process(
        _ events: [AIChatEvent],
        round: inout StreamedRound,
        accumulator: inout AIChatToolCallAccumulator
    ) throws {
        accumulator.consume(events)

        for event in events {
            switch event {
            case .text(let chunk):
                round.text += chunk
                append(chunk)
            case .thinking:
                setStatus("思考中…")
            case .toolCallStarted, .toolCallArguments:
                break // 交给累加器
            case .stopReason(let reason):
                round.stopReason = reason
            case .error(let message):
                throw APIError(kind: .transport("stream"), message: message)
            case .done:
                round.sawDone = true
            }
        }
    }

    private func decode(_ frame: SSEFrame, chatProtocol: AIChatProtocol) -> [AIChatEvent] {
        switch chatProtocol {
        case .anthropicMessages: return AnthropicSSEDecoder.decode(frame)
        case .openAICompatible: return OpenAISSSEDecoder.decode(frame)
        }
    }

    /// 跑模型要的工具。AnySearch 的 Key 是可选的（不填就匿名）。
    private func execute(
        _ calls: [AIChatToolCall],
        searchKey: String
    ) async throws -> [AIChatToolRound.AIChatToolResultPayload] {
        let runner = AnySearchToolRunner(apiKey: searchKey)
        var payloads: [AIChatToolRound.AIChatToolResultPayload] = []

        for call in calls {
            try Task.checkCancellation()
            setStatus(activityText(for: call))
            let outcome = await runner.execute(call: call)
            payloads.append(
                AIChatToolRound.AIChatToolResultPayload(
                    toolUseID: call.id,
                    text: outcome.text,
                    isError: outcome.isError
                )
            )
        }
        return payloads
    }

    private func activityText(for call: AIChatToolCall) -> String {
        let title = AIChatToolName.title(call.name ?? "")
        if let query = call.string("query") {
            return "\(title)：\(query)"
        }
        return title + "…"
    }

    /// 结束原因要**先于**看正文判断：被拒绝时正文是空的，
    /// 不说明的话界面上就是一个什么都没有的气泡。
    private func applyStopReason(_ reason: String?, sawDone: Bool) {
        switch reason {
        case "refusal":
            notice = "模型拒绝回答这个问题。"
        case "max_tokens", "length":
            notice = "回复太长被截断了。"
        case "pause_turn":
            notice = "本轮搜索步骤已达上限，回复可能不完整。"
        default:
            // 拿到结束原因就算正常收尾了。只有「既没有结束原因、也没等到收尾标记」
            // 才算截断 —— 有些中转站不发 `data: [DONE]`，只给 finish_reason，
            // 那种情况报「连接中断」是误报。
            if reason == nil && !sawDone {
                notice = "连接提前中断，回复可能不完整。"
            }
        }
    }

    // MARK: - 正文刷新

    private func append(_ chunk: String) {
        pendingText += chunk
        // 开始出字了，就不必再占着状态行
        if statusText != nil { statusText = nil }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: AIChatModel.flushInterval)
            guard let self else { return }
            self.flushTask = nil
            self.flushNow()
        }
    }

    private func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        guard !pendingText.isEmpty else { return }
        if let index = messages.indices.last, messages[index].role == .assistant {
            messages[index].text += pendingText
        }
        pendingText = ""
        bumpScroll()
    }

    private func finishStreaming() {
        flushNow()
        isStreaming = false
        statusText = nil
        if let index = messages.indices.last, messages[index].role == .assistant {
            messages[index].isStreaming = false
            // 一个字都没出来的（比如直接报错），别留个空气泡
            if messages[index].text.isEmpty {
                messages.removeLast()
            }
        }
    }

    private func setStatus(_ text: String) {
        if statusText != text { statusText = text }
    }

    private func bumpScroll() {
        scrollTick &+= 1
    }

    private func turnsForRequest() -> [AIChatTurn] {
        messages.compactMap { message in
            guard !message.text.isEmpty else { return nil }
            return AIChatTurn(role: message.role, text: message.text)
        }
    }
}
