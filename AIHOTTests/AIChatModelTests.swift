import XCTest

@testable import AIHOT

/// `AIChatModel` 里唯一能离线验证的东西：**攒历史**（`history(from:)`）。
///
/// 发送路径整个挂在网络上，流式循环要 `URLSession.AsyncBytes`，都只有真机能跑。
/// 但「多轮会话对不对」的承重点恰好是纯的 —— 一轮问答结束后，下一问到底把什么
/// 当成了历史。它错了不会崩，只会让模型失忆或收到一条空消息，所以必须钉住。
///
/// `AIChatModel` 是 @MainActor 的（它的 static 成员也是），所以用例也得跑在主 actor 上，
/// 否则连编译都过不去。逐个方法标 @MainActor，**不要**标在类上 —— 那会连
/// setUp/tearDown 一起变成非隔离父类方法的隔离重写。
final class AIChatModelTests: XCTestCase {

    private func message(_ role: AIChatTurn.Role, _ text: String) -> AIChatMessage {
        AIChatMessage(role: role, text: text)
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
}
