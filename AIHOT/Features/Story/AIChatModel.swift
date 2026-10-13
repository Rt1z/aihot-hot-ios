import Combine
import Foundation

/// 界面上的一条消息。
struct AIChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: AIChatTurn.Role
    var text: String
    var isStreaming: Bool

    /// 恢复历史时要原样拿回旧 id（`ChatHistoryStore.StoredMessage.id`）；
    /// 新消息用默认值，所以所有现有调用点（`AIChatMessage(role:text:)` 等）照常编译。
    init(id: UUID = UUID(), role: AIChatTurn.Role, text: String, isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
    }
}

/// 详情页那个对话弹窗的状态与流式循环。
///
/// **按新闻落盘**：`sessionKey`（= `HotTopic.id`）非 nil 时，对话历史写进
/// `ChatHistoryStore`（Application Support/chat-sessions.json —— 用户数据，
/// 不是缓存，`clearCache()` 也碰不到它），杀掉 App 重开还在。保存时机是
/// `finishStreaming()`，它在 `run` 的 `defer` 里 —— 成功、报错、取消三种收场
/// 都会走到，所以中途杀 App 只会丢「最后一轮还在流的那句」。
/// 垃圾桶按钮（`reset`）连盘一起删。`sessionKey == nil`（测试与默认构造）不落盘。
///
/// 工具循环：模型可以要求调用 `web_search` / `read_url`，由设置里选的搜索工具
/// （AnySearch 或 Tavily，见 `makeSearchRunner()`）执行，结果作为 tool_result 回传，
/// 直到它给出最终回答。两家协议的工具块形状完全不同，
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
    /// 这条对话属于哪条新闻（= `HotTopic.id`）。nil = 不落盘。
    private let sessionKey: String?
    private let historyStore: ChatHistoryStore
    private var streamTask: Task<Void, Never>?
    /// 攒起来的增量，还没刷进 messages。
    private var pendingText = ""
    private var flushTask: Task<Void, Never>?

    /// 攒多久刷一次。text_delta 常常只有 1–5 个字，每个都改 @Published
    /// 会让 SwiftUI 逐字重排、长回复明显卡顿。
    private static let flushInterval: Duration = .milliseconds(70)

    /// 一次提问里最多跑几轮工具。防止模型来回搜个没完 —— 每轮都是钱。
    private static let maximumToolRounds = 5

    /// 构造时就恢复盘上的历史（首次渲染前完成，没有空屏闪烁）。
    /// 恢复出来的消息一律是已完成的 —— 盘上从不存 `isStreaming`。
    init(
        api: AIChatAPI = .shared,
        sessionKey: String? = nil,
        historyStore: ChatHistoryStore = .shared
    ) {
        self.api = api
        self.sessionKey = sessionKey
        self.historyStore = historyStore
        if let sessionKey, let restored = historyStore.load(key: sessionKey) {
            messages = restored
        }
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
        let history = Self.history(from: messages)
        messages.append(AIChatMessage(role: .assistant, text: "", isStreaming: true))
        isStreaming = true
        bumpScroll()

        let newsContext = AIChatNewsContext.make(
            item: item, story: story, prefetchedDigest: prefetchedDigest
        )
        let system = AIChatNewsContext.system
        let searchRunner = Self.makeSearchRunner()

        streamTask = Task { [weak self] in
            await self?.run(
                config: config,
                system: system,
                newsContext: newsContext,
                history: history,
                searchRunner: searchRunner
            )
        }
    }

    /// 按设置造当前的搜索工具执行者（Key 读取也收在这一处）。
    /// 工具声明是提供方无关的，所以切换只换执行者，请求体一行不动。
    private static func makeSearchRunner() -> any AIChatToolExecuting {
        switch AppSettings.searchToolProvider {
        case .anySearch: return AnySearchToolRunner(apiKey: AppSettings.anySearchKey())
        case .tavily: return TavilyToolRunner(apiKey: AppSettings.tavilyKey())
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
        // 清空 = 连盘一起删。被取消那轮的 defer 还会再跑一次 finishStreaming，
        // 那时 messages 已空、persistSession 只会再删一次（幂等），不会把旧对话写回来。
        if let sessionKey {
            historyStore.delete(key: sessionKey)
        }
    }

    // MARK: - 流式循环

    /// 一轮流式读取攒出来的东西。
    private struct StreamedRound {
        var text = ""
        var toolCalls: [AIChatToolCall] = []
        var stopReason: String?
        var sawDone = false

        // 下面四项只为一件事：一轮什么都没认出来时，能说清**到底收到了什么**。
        // 侧载的 App 没法挂调试器，用户能带回来的只有界面上那行字。
        /// 一共切出几帧。
        var frameCount = 0
        /// 一共认出几个事件。
        var recognizedEventCount = 0
        /// 第一行非空原文 —— 万一对方回的根本不是 SSE（有些中转站会谎报 Content-Type）。
        var firstRawLine: String?
        /// 认不出来的 data 原文，最多留 5 段，用来判断「是不是另一条协议的流」。
        var unrecognizedSamples: [String] = []
    }

    private func run(
        config: AIChatConfig,
        system: String,
        newsContext: String,
        history: [AIChatTurn],
        searchRunner: any AIChatToolExecuting
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
                    if text.isEmpty {
                        // 走这条分支却一个字都没有，说明整段响应也没解析出正文。
                        // 不说的话界面上什么都没有、也不报错（空气泡被删掉了）。
                        notice = "接口没有按流式返回，整段响应里也找不到正文。请到「设置 → AI 对话」核对接口地址与协议是否配套。"
                    }
                    return

                case .stream(let bytes):
                    round = try await consume(bytes, chatProtocol: config.chatProtocol)
                }

                // 只要有工具调用就跑 —— 不看 stop_reason：有些中转站给了
                // tool_calls 却把 finish_reason 报成 "stop"。
                guard !round.toolCalls.isEmpty else {
                    applyStopReason(
                        round.stopReason,
                        sawDone: round.sawDone,
                        round: round,
                        chatProtocol: config.chatProtocol
                    )
                    return
                }

                guard toolRounds.count < Self.maximumToolRounds else {
                    notice = "这一轮已经查了 \(Self.maximumToolRounds) 次，先说到这。"
                    return
                }

                let results = try await execute(round.toolCalls, runner: searchRunner)
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
        var splitter = SSELineSplitter()
        var reader = SSEFrameReader()
        var accumulator = AIChatToolCallAccumulator()
        var round = StreamedRound()

        /// 一行的处理，字节路径与收尾路径共用。
        func take(_ line: String) throws {
            record(line: line, round: &round)
            guard let frame = reader.consume(line: line) else { return }
            let events = decode(frame, chatProtocol: chatProtocol, round: &round)
            try process(events, round: &round, accumulator: &accumulator)
        }

        // 自己做切行，而不是 `bytes.lines`：空行是 SSE 分帧的唯一依据，
        // 谁把它吞掉整条流就会被拼成一帧、一个事件都认不出来（见 SSELineSplitter）。
        for try await byte in bytes {
            try Task.checkCancellation()
            if let line = splitter.consume(byte: byte) { try take(line) }
        }
        if let line = splitter.flush() { try take(line) }
        if let frame = reader.flush() {
            let events = decode(frame, chatProtocol: chatProtocol, round: &round)
            try process(events, round: &round, accumulator: &accumulator)
        }

        flushNow()
        round.toolCalls = accumulator.result
        return round
    }

    /// 边读边把「收到了什么」记进 `round`，只用于事后说清失败原因。
    ///
    /// 这里不做判断、不影响流程，纯粹留证据：侧载的 App 没法挂调试器，
    /// 用户能带回来的只有界面上那行字（见 `truncationNotice`）。
    private func record(line: String, round: inout StreamedRound) {
        // 第一行非空原文：万一对方回的根本不是 SSE，这行就是全部线索
        if round.firstRawLine == nil, !line.isEmpty {
            round.firstRawLine = Self.excerpt(line)
        }
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

    private func decode(
        _ frame: SSEFrame,
        chatProtocol: AIChatProtocol,
        round: inout StreamedRound
    ) -> [AIChatEvent] {
        let events = Self.decode(frame, chatProtocol: chatProtocol)
        round.frameCount += 1
        round.recognizedEventCount += events.count
        // 留几段认不出来的原文：既用来判断「是不是另一条协议的流」，
        // 也在什么都认不出来时原样贴给用户看。
        //
        // 留 5 段而不是 1 段，是因为真实流的头几帧本身可能是「结构性」的
        // （Anthropic 的 message_start、OpenAI 的 role 分片），单独看都认不出来，
        // 要往后一点才出现能认的帧。用夹具把两个方向都钉住了（见 AIChatModelTests）。
        if events.isEmpty, !frame.data.isEmpty, round.unrecognizedSamples.count < 5 {
            round.unrecognizedSamples.append(Self.excerpt(frame.data))
        }
        return events
    }

    private static func decode(_ frame: SSEFrame, chatProtocol: AIChatProtocol) -> [AIChatEvent] {
        switch chatProtocol {
        case .anthropicMessages: return AnthropicSSEDecoder.decode(frame)
        case .openAICompatible: return OpenAISSSEDecoder.decode(frame)
        }
    }

    /// 诊断用短摘要：压成一行，最多 200 字。
    private static func excerpt(_ text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        guard oneLine.count > 200 else { return oneLine }
        return String(oneLine.prefix(200)) + "…"
    }

    /// 跑模型要的工具。执行者由调用方按设置造好传进来（AnySearch 或 Tavily），
    /// 这里只负责循环：状态行、取消检查、逐个执行、拼回传载荷。
    private func execute(
        _ calls: [AIChatToolCall],
        runner: any AIChatToolExecuting
    ) async throws -> [AIChatToolRound.AIChatToolResultPayload] {
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
    private func applyStopReason(
        _ reason: String?,
        sawDone: Bool,
        round: StreamedRound,
        chatProtocol: AIChatProtocol
    ) {
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
                notice = Self.truncationNotice(
                    frameCount: round.frameCount,
                    recognizedEventCount: round.recognizedEventCount,
                    firstRawLine: round.firstRawLine,
                    unrecognizedSamples: round.unrecognizedSamples,
                    hadText: !round.text.isEmpty,
                    chatProtocol: chatProtocol
                )
            }
        }
    }

    /// 一轮「既没等到结束原因、也没等到收尾标记」时到底该说哪句话。
    ///
    /// 这里原本只有一句「连接提前中断，回复可能不完整」，把四种完全不同的情况
    /// 说成了同一句 —— 用户照着那句话什么都查不出来，我们这边也只能猜。
    /// 现在按**流里究竟收到了什么**分开说：
    ///
    /// | 收到的 | 说明 | 该说的话 |
    /// | --- | --- | --- |
    /// | 切不出帧 | 对方回的就不是 SSE（有些中转站会谎报 Content-Type） | 贴出开头原文 |
    /// | 有帧、认不出，但**另一条协议能认** | 协议与地址不配套（最常见） | 点名该换成哪条协议 |
    /// | 有帧、认不出，两条都认不出 | 天知道是什么 | 贴出**帧数**与开头/结尾原文 |
    /// | 认出来了却一个字没有 | 只收到思考块之类的，流就断了 | 说「还没给出回复」 |
    /// | 有正文、只是收尾标记没来 | 真的可能被截断 | 保留原话 |
    ///
    /// 「两条都认不出」那一支必须带上**帧数**：真机报回来的是
    /// `{…完整的第一帧…}` 这种开头，而流的第一帧（`role` 分片 / `message_start`）
    /// 本来就认不出来 —— 光看开头分不清「只切出一帧（整条流被拼在一起）」
    /// 和「切出几十帧但都不认识」。帧数一说清，这两种故障就分开了。
    ///
    /// 纯函数、不碰 UI，单测与 Python 镜像共用（见 `AIChatModelTests` / 镜像 11）。
    static func truncationNotice(
        frameCount: Int,
        recognizedEventCount: Int,
        firstRawLine: String?,
        unrecognizedSamples: [String],
        hadText: Bool,
        chatProtocol: AIChatProtocol
    ) -> String {
        let other: AIChatProtocol = chatProtocol == .anthropicMessages ? .openAICompatible : .anthropicMessages

        guard recognizedEventCount > 0 else {
            // 一帧都没切出来：对方回的不是流式格式
            guard frameCount > 0 else {
                guard let raw = firstRawLine else {
                    return "接口没有返回任何内容，请稍后重试。"
                }
                return "接口回的内容不是流式格式，解析不了。请到「设置 → AI 对话」核对接口地址与协议是否配套。接口开头是：\(raw)"
            }
            // 切出了帧却一个事件都认不出来 —— 最常见的原因是协议选错了。
            // 拿另一条协议的解码器试一下就能当场证明（这也是本地唯一能验的路径）。
            let looksLikeOther = unrecognizedSamples.contains { sample in
                !decode(SSEFrame(event: nil, data: sample), chatProtocol: other).isEmpty
            }
            if looksLikeOther {
                return "这个地址回的是「\(other.title)」格式的流，跟「协议」里选的「\(chatProtocol.title)」对不上。请把协议改成「\(other.title)」，或把接口地址换成「\(chatProtocol.title)」的地址。"
            }
            guard let sample = unrecognizedSamples.first else {
                return "接口没有返回任何内容，请稍后重试。"
            }
            var detail = "共切出 \(frameCount) 帧，开头是：\(sample)"
            if unrecognizedSamples.count > 1, let last = unrecognizedSamples.last {
                detail += "；最后一段是：\(last)"
            }
            return "接口回的内容既不像「\(chatProtocol.title)」也不像「\(other.title)」的流式格式（\(detail)）。请核对接口地址与协议是否配套。"
        }

        // 认出了东西却一个字都没有（比如只收到思考块）就断了
        guard hadText else {
            return "接口还没给出回复就断开了，请重试。"
        }
        return "连接提前中断，回复可能不完整。"
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
        persistSession()
    }

    /// 把当前对话存进盘。每轮结束调一次（`run` 的 `defer` 覆盖成功/报错/取消）。
    private func persistSession() {
        guard let sessionKey else { return }
        if messages.isEmpty {
            historyStore.delete(key: sessionKey)
        } else {
            historyStore.save(messages: messages, key: sessionKey)
        }
    }

    private func setStatus(_ text: String) {
        if statusText != text { statusText = text }
    }

    private func bumpScroll() {
        scrollTick &+= 1
    }

    /// 攒出这次提问要带的历史 —— **多轮会话的全部状态就在这里**。
    ///
    /// 逐条原样带走（角色 + 文本），所以上一轮的问和答必然出现在下一轮的请求里；
    /// 只把**一个字都没有**的消息滤掉。
    ///
    /// 收尾那道闸不在这里：`finishStreaming()` 本来就会把没出字的空气泡删掉
    /// （「别留个空气泡」）。所以一轮什么都没产出时，留下的其实是**一对连续的
    /// user 消息** —— 两条都要留着，按角色去重会把用户自己那句话也丢掉。
    /// 这里过滤空文本是第二道闸，钉住本函数自己的契约。
    ///
    /// 做成 `static` 且接收数组，是为了让单测能直接喂一份自己造的历史 ——
    /// `messages` 是 `private(set)`，用例没法自己摆状态（见 `AIChatModelTests`）。
    static func history(from messages: [AIChatMessage]) -> [AIChatTurn] {
        messages.compactMap { message in
            guard !message.text.isEmpty else { return nil }
            return AIChatTurn(role: message.role, text: message.text)
        }
    }
}
