import XCTest

@testable import AIHOT

/// `AIChatModel` 里能离线验证的两块：**攒历史**（`history(from:)`）和
/// **「一个事件都没认出来」时该说哪句话**（`truncationNotice`）。
///
/// 发送路径整个挂在网络上，流式循环要 `URLSession.AsyncBytes`，都只有真机能跑。
/// 但这两处的承重点恰好都是纯的：
/// - 一轮问答结束后，下一问到底把什么当成了历史 —— 错了不会崩，只会让模型失忆；
/// - 失败时那句话说不说得清 —— 侧载的 App 挂不上调试器，**那是唯一的诊断信号**。
///   原来四种完全不同的故障共用一句「连接提前中断」，用户照着一句话什么都查不出来。
///
/// `AIChatModel` 是 @MainActor 的（它的 static 成员也是），所以用例也得跑在主 actor 上，
/// 否则连编译都过不去。逐个方法标 @MainActor，**不要**标在类上 —— 那会连
/// setUp/tearDown 一起变成非隔离父类方法的隔离重写。
final class AIChatModelTests: XCTestCase {

    private func message(_ role: AIChatTurn.Role, _ text: String) -> AIChatMessage {
        AIChatMessage(role: role, text: text)
    }

    /// 照着 `AIChatModel.consume` 的记法走一遍夹具：切帧、解码、留几段认不出来的原文。
    private func scan(
        _ text: String,
        as chatProtocol: AIChatProtocol
    ) -> (frames: Int, recognized: Int, samples: [String]) {
        var reader = SSEFrameReader()
        var frames = 0
        var recognized = 0
        var samples: [String] = []

        func take(_ frame: SSEFrame) {
            frames += 1
            let events = chatProtocol == .anthropicMessages
                ? AnthropicSSEDecoder.decode(frame)
                : OpenAISSSEDecoder.decode(frame)
            recognized += events.count
            if events.isEmpty, !frame.data.isEmpty, samples.count < 5 {
                samples.append(String(frame.data.prefix(200)))
            }
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map({ String($0) }) {
            guard let frame = reader.consume(line: line) else { continue }
            take(frame)
        }
        if let frame = reader.flush() { take(frame) }
        return (frames, recognized, samples)
    }

    // MARK: - 多轮历史

    @MainActor
    func testHistoryOfNothingIsNothing() {
        XCTAssertEqual(AIChatModel.history(from: []), [])
    }

    /// 核心的一条：第二次提问时，历史里必须原样出现**第一问 + 第一答**，
    /// 顺序不变、角色不变。
    @MainActor
    func testHistoryCarriesThePreviousQuestionAndAnswerInOrder() {
        let messages = [
            message(.user, "为什么火？"),
            message(.assistant, "因为被多人转引。"),
            message(.user, "还有后续吗？"),
        ]

        XCTAssertEqual(
            AIChatModel.history(from: messages),
            [
                AIChatTurn(role: .user, text: "为什么火？"),
                AIChatTurn(role: .assistant, text: "因为被多人转引。"),
                AIChatTurn(role: .user, text: "还有后续吗？"),
            ]
        )
    }

    /// 只认文本这一道闸：一个字都没有的消息一律不进历史（否则给模型发一条空的
    /// assistant 消息），但它前后的内容一条都不能少。
    ///
    /// 注意这道闸今天其实到不了 —— 收尾的 `finishStreaming()` 已经把没出字的空气泡
    /// 删掉了。这条钉的是 `history` 自己的契约，不是某条现成的调用路径。
    @MainActor
    func testHistoryDropsMessagesThatNeverGotAnyText() {
        let messages = [
            message(.user, "为什么火？"),
            message(.assistant, ""),
            message(.user, "再试一次"),
        ]

        XCTAssertEqual(
            AIChatModel.history(from: messages),
            [
                AIChatTurn(role: .user, text: "为什么火？"),
                AIChatTurn(role: .user, text: "再试一次"),
            ]
        )
    }

    /// 真正会被 `finishStreaming()` 制造出来的那个状态：一轮什么都没产出时，空气泡被
    /// 删掉，下一问接上就成了一对**连续的 user 消息**。
    ///
    /// 两条都必须在历史里 —— 按角色去重（"上一条也是 user，跳过"）会把用户自己那句
    /// 问题也丢掉，而那是这一轮唯一要问的东西。
    @MainActor
    func testHistoryKeepsTwoConsecutiveUserTurnsWhenATurnProducedNothing() {
        let messages = [
            message(.user, "为什么火？"),
            message(.user, "再试一次"),
        ]

        XCTAssertEqual(
            AIChatModel.history(from: messages),
            [
                AIChatTurn(role: .user, text: "为什么火？"),
                AIChatTurn(role: .user, text: "再试一次"),
            ]
        )
    }

    /// 纯追加：第 N 轮的历史，前若干条必须和第 N-1 轮**逐条相等**。
    /// 这正是提示词缓存前缀能活过整场对话的前提（CLAUDE.md 规则 11），
    /// 哪天有人在这里排序、去重或改写，这条会红。
    @MainActor
    func testHistoryIsAppendOnlyAcrossTurns() {
        let first = [message(.user, "为什么火？")]
        let second = first + [message(.assistant, "被多人转引。"), message(.user, "还有后续吗？")]
        let third = second + [message(.assistant, "还没有。"), message(.user, "来源可靠吗？")]

        let firstHistory = AIChatModel.history(from: first)
        let secondHistory = AIChatModel.history(from: second)
        let thirdHistory = AIChatModel.history(from: third)

        XCTAssertEqual(Array(secondHistory.prefix(firstHistory.count)), firstHistory)
        XCTAssertEqual(Array(thirdHistory.prefix(secondHistory.count)), secondHistory)
        XCTAssertEqual(thirdHistory.count, 5)
    }

    // MARK: - 失败时说的是哪句话

    /// 最要紧的一条：**协议与地址不配套**。
    ///
    /// 用真实夹具的字节：Anthropic 的流喂给 OpenAI 兼容的解码器，一个事件都认不出来 ——
    /// 真机上这就是「没有任何回复 + 连接提前中断」的样子。这时不许再怪连接，
    /// 得点名让用户去把协议改过来（另一条协议的解码器认得这些帧，这就是证据）。
    @MainActor
    func testForeignProtocolStreamIsNamedInsteadOfBlamedOnTheConnection() throws {
        let scanned = scan(try Fixture.text("anthropic-sse", ext: "txt"), as: .openAICompatible)
        XCTAssertEqual(scanned.recognized, 0, "Anthropic 的帧不该被 OpenAI 兼容的解码器认出来")
        XCTAssertFalse(scanned.samples.isEmpty, "认不出来的原文要留一点，否则没法诊断")

        let notice = AIChatModel.truncationNotice(
            frameCount: scanned.frames,
            recognizedEventCount: scanned.recognized,
            firstRawLine: nil,
            unrecognizedSamples: scanned.samples,
            hadText: false,
            chatProtocol: .openAICompatible
        )

        XCTAssertTrue(notice.contains("Anthropic"), notice)
        XCTAssertFalse(notice.contains("连接提前中断"), notice)
    }

    /// 反方向同样要点名（选了 Anthropic、地址其实是 OpenAI 兼容的）。
    @MainActor
    func testForeignProtocolInTheOtherDirectionIsAlsoNamed() throws {
        let scanned = scan(try Fixture.text("openai-sse", ext: "txt"), as: .anthropicMessages)
        XCTAssertEqual(scanned.recognized, 0, "OpenAI 兼容的帧不该被 Anthropic 的解码器认出来")

        let notice = AIChatModel.truncationNotice(
            frameCount: scanned.frames,
            recognizedEventCount: scanned.recognized,
            firstRawLine: nil,
            unrecognizedSamples: scanned.samples,
            hadText: false,
            chatProtocol: .anthropicMessages
        )

        XCTAssertTrue(notice.contains("OpenAI 兼容"), notice)
        XCTAssertFalse(notice.contains("连接提前中断"), notice)
    }

    /// 两条协议都认不出来时，把**接口真正发来的原文**贴出来 ——
    /// 这是我们在没有真机的情况下唯一能拿到的东西。
    @MainActor
    func testUnrecognisableStreamShowsWhatTheEndpointActuallySent() {
        let notice = AIChatModel.truncationNotice(
            frameCount: 3,
            recognizedEventCount: 0,
            firstRawLine: nil,
            unrecognizedSamples: [#"{"hello":"world"}"#],
            hadText: false,
            chatProtocol: .openAICompatible
        )

        XCTAssertTrue(notice.contains(#"{"hello":"world"}"#), notice)
        XCTAssertTrue(
            notice.contains("共切出 3 帧"),
            "帧数必须带上：流的第一帧（role 分片 / message_start）本来就认不出来，"
                + "光看开头分不清「整条流被拼成一帧」和「切了很多帧都不认识」"
        )
        XCTAssertFalse(notice.contains("连接提前中断"), notice)
    }

    /// 留了好几段样本时，头尾都要贴出来。
    ///
    /// 只贴第一段，看到的基本永远是 `{"index":0,"delta":{"role":"assistant"}}`
    /// 这种「结构帧」—— 它按协议本来就不产出事件，等于什么都没说。
    @MainActor
    func testUnrecognisableStreamShowsBothEndsOfTheSamples() {
        let notice = AIChatModel.truncationNotice(
            frameCount: 12,
            recognizedEventCount: 0,
            firstRawLine: nil,
            unrecognizedSamples: [
                #"{"choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}"#,
                #"{"choices":[{"index":0,"delta":{"content":""},"finish_reason":null}]}"#,
            ],
            hadText: false,
            chatProtocol: .openAICompatible
        )

        XCTAssertTrue(notice.contains("共切出 12 帧"), notice)
        XCTAssertTrue(notice.contains(#""role":"assistant""#), notice)
        XCTAssertTrue(notice.contains("最后一段是"), notice)
        XCTAssertFalse(notice.contains("连接提前中断"), notice)
    }

    /// 不是 SSE 的响应体（有些中转站谎报 `Content-Type: text/event-stream`）：
    /// 一帧都切不出来，所以线索是**第一行原文**，不是帧里的 data。
    @MainActor
    func testNonStreamingBodyIsReportedWithItsOwnOpeningBytes() {
        let notice = AIChatModel.truncationNotice(
            frameCount: 0,
            recognizedEventCount: 0,
            firstRawLine: "<!DOCTYPE html><html>…",
            unrecognizedSamples: [],
            hadText: false,
            chatProtocol: .openAICompatible
        )

        XCTAssertTrue(notice.contains("<!DOCTYPE html>"), notice)
        XCTAssertTrue(notice.contains("不是流式"), notice)
        XCTAssertFalse(notice.contains("连接提前中断"), notice)
    }

    /// 连一帧、一行都没有：那就是真没内容，别扯协议。
    @MainActor
    func testStreamWithNoContentAtAllSaysSo() {
        let notice = AIChatModel.truncationNotice(
            frameCount: 0,
            recognizedEventCount: 0,
            firstRawLine: nil,
            unrecognizedSamples: [],
            hadText: false,
            chatProtocol: .openAICompatible
        )

        XCTAssertEqual(notice, "接口没有返回任何内容，请稍后重试。")
    }

    /// 认出了东西却一个字都没有（比如只收到思考块就断了）。
    /// 这种情况下没有「回复」可言，说「回复可能不完整」是错的。
    @MainActor
    func testStreamThatDiedBeforeAnyReplyIsNotCalledATruncatedReply() {
        let notice = AIChatModel.truncationNotice(
            frameCount: 4,
            recognizedEventCount: 3,
            firstRawLine: nil,
            unrecognizedSamples: [],
            hadText: false,
            chatProtocol: .openAICompatible
        )

        XCTAssertTrue(notice.contains("还没给出回复"), notice)
        XCTAssertFalse(notice.contains("连接提前中断"), notice)
    }

    /// 真有正文、只是收尾标记没来 —— **这句老话是给这种情况留的，别一起删掉**。
    /// 有些中转站不发 `data: [DONE]`，只给 `finish_reason`；反过来，流被网络掐断时
    /// 正文可能已经出了一半，这时提醒「可能不完整」是对的。
    @MainActor
    func testStreamWithTextButNoEndMarkerKeepsTheOriginalWording() {
        let notice = AIChatModel.truncationNotice(
            frameCount: 12,
            recognizedEventCount: 12,
            firstRawLine: nil,
            unrecognizedSamples: [],
            hadText: true,
            chatProtocol: .openAICompatible
        )

        XCTAssertEqual(notice, "连接提前中断，回复可能不完整。")
    }
}
