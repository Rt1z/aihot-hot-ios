import Combine
import Foundation

/// 一次「AI 点评」的流式状态。
///
/// 与 `AIChatModel` 刻意分开：点评是**一次性短请求** —— 不带工具、不带思考、
/// 没有多轮历史、不落聊天记录。共用的只有传输层（`AIChatAPI`）与 SSE 解析
/// （`SSELineSplitter` / `SSEFrameReader` / 两个解码器）。
///
/// **逐字节切行，绝不用 `bytes.lines`**：平台那个会吞掉空行，而空行是 SSE
/// 分帧的唯一依据（规则 17）。这里与对话走同一条路，不是因为习惯，是因为
/// 吞掉空行后整条流会被拼成一帧、一个事件都认不出来。
@MainActor
final class PracticeReviewModel: ObservableObject {

    @Published private(set) var text = ""
    @Published private(set) var isStreaming = false
    @Published private(set) var notice: String?

    private let api: AIChatAPI

    /// 增量攒多久刷一次界面：每个 delta 只有 1–5 个字，逐个改 `@Published`
    /// 会让 SwiftUI 逐字重排（同 `AIChatModel.flushInterval` 的理由）。
    private static let flushInterval: TimeInterval = 0.07
    private static let flushCharacters = 120

    init(api: AIChatAPI = .shared) {
        self.api = api
    }

    /// 返回最终点评正文；失败/取消返回 nil，原因在 `notice` 里。
    /// 调用方负责取消：把这次调用放在一个 `Task` 里，取消那个 Task 即可。
    func review(config: AIChatConfig, system: String, user: String) async -> String? {
        guard !isStreaming else { return nil }
        text = ""
        notice = nil
        isStreaming = true
        defer { isStreaming = false }

        do {
            let response = try await api.streamChat(
                config: config,
                system: system,
                newsContext: "",
                turns: [AIChatTurn(role: .user, text: user)],
                includeTools: false
            )

            switch response {
            case .complete(let full):
                text = full
            case .stream(let bytes):
                try await consume(bytes, chatProtocol: config.chatProtocol)
            }

            let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.isEmpty else {
                notice = "接口没有返回可识别的正文。请到「设置 → AI 对话」核对接口地址与协议是否配套。"
                return nil
            }
            return result

        } catch is CancellationError {
            // 用户离开页面/再次点击：正常收场，不弹错误
            return nil
        } catch let error as APIError {
            notice = error.message
            return nil
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    // MARK: - 流式读取

    private func consume(_ bytes: URLSession.AsyncBytes, chatProtocol: AIChatProtocol) async throws {
        var splitter = SSELineSplitter()
        var reader = SSEFrameReader()
        var pending = ""
        var lastFlush = Date()

        func flush(force: Bool) {
            guard !pending.isEmpty else { return }
            let now = Date()
            guard force
                || pending.count >= Self.flushCharacters
                || now.timeIntervalSince(lastFlush) >= Self.flushInterval
            else { return }
            text += pending
            pending = ""
            lastFlush = now
        }

        func handle(_ frame: SSEFrame) throws {
            let events: [AIChatEvent]
            switch chatProtocol {
            case .anthropicMessages: events = AnthropicSSEDecoder.decode(frame)
            case .openAICompatible: events = OpenAISSSEDecoder.decode(frame)
            }

            for event in events {
                switch event {
                case .text(let chunk):
                    pending += chunk
                case .error(let message):
                    throw APIError(kind: .transport("stream"), message: message)
                case .thinking, .toolCallStarted, .toolCallArguments, .stopReason, .done:
                    // 点评请求不带工具；思考/结束标记对这段文字没有意义
                    break
                }
            }
            flush(force: false)
        }

        func take(_ line: String) throws {
            guard let frame = reader.consume(line: line) else { return }
            try handle(frame)
        }

        for try await byte in bytes {
            try Task.checkCancellation()
            if let line = splitter.consume(byte: byte) { try take(line) }
        }
        if let line = splitter.flush() { try take(line) }
        if let frame = reader.flush() { try handle(frame) }

        flush(force: true)
    }
}
