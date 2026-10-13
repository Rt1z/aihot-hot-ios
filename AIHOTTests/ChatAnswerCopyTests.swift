import XCTest

@testable import AIHOT

/// 复制到剪贴板的文本拼装：回答 + 新闻标题 + 出处链接。
/// 出处是条款要求 —— 复制出去的文本落到哪都认得出来自哪条新闻、哪篇原文。
final class ChatAnswerCopyTests: XCTestCase {

    func testAnswerIsFollowedByTitleAndOriginalLink() {
        let text = ChatAnswerCopy.text(
            answer: "因为模型共识变了。",
            title: "Karpathy 说 LLM 共识变了",
            link: "https://example.com/post"
        )
        XCTAssertEqual(
            text,
            "因为模型共识变了。\n\n——《Karpathy 说 LLM 共识变了》\nhttps://example.com/post"
        )
    }

    /// 链接缺了（或只有空白）就只留标题 —— 标题是热榜条目的必有字段。
    func testMissingOrBlankLinkKeepsOnlyTheTitle() {
        let noLink = ChatAnswerCopy.text(answer: "答", title: "题", link: nil)
        XCTAssertEqual(noLink, "答\n\n——《题》")
        let blankLink = ChatAnswerCopy.text(answer: "答", title: "题", link: "   ")
        XCTAssertEqual(blankLink, "答\n\n——《题》")
    }
}
