import Foundation

/// 把一条 AI 回答整理成可粘贴的纯文本：正文 + 新闻标题 + 出处链接。
///
/// 出处不是装饰 —— 内容版权归 AIHOT 与各原始来源（个人使用条款），
/// 复制出去的文本要自带标题与链接，落到微信/备忘录里也认得出出处。
/// 纯函数、可被单测钉住（`ChatAnswerCopyTests`）。
enum ChatAnswerCopy {

    static func text(answer: String, title: String, link: String?) -> String {
        var attribution = "——《\(title)》"
        let trimmedLink = (link ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLink.isEmpty {
            attribution += "\n" + trimmedLink
        }
        return answer + "\n\n" + attribution
    }
}
