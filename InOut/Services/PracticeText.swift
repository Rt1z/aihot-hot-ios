import Foundation

/// 写作面板里正在编辑的内容（尚未落盘）。
struct PracticeContent: Equatable {
    var mode: PracticeMode
    var mainIdea: String
    /// 固定 3 格；空的那几格保存时会被过滤掉。
    var points: [String]
    var takeaway: String
    var freeText: String

    static func empty(mode: PracticeMode = .structured) -> PracticeContent {
        PracticeContent(mode: mode, mainIdea: "", points: ["", "", ""], takeaway: "", freeText: "")
    }

    static func make(from entry: PracticeEntry) -> PracticeContent {
        var points = entry.points
        while points.count < 3 { points.append("") }
        return PracticeContent(
            mode: entry.mode,
            mainIdea: entry.mainIdea ?? "",
            points: Array(points.prefix(3)),
            takeaway: entry.takeaway ?? "",
            freeText: entry.freeText ?? ""
        )
    }
}

/// 练习里那些「不碰界面也不碰网络」的文字规则。
///
/// 纯函数：不读 `Date()`、不读设置，同一份输入永远得到同一份输出 ——
/// 单测与 `tools/logic_tests.py` 的镜像 23 两边钉住。
enum PracticeText {

    /// 去掉首尾空白；全是空白就当作没写。
    static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// 非空白字符数。用 Character 而不是 UTF-8 字节：中文一个字算一个字。
    static func wordCount(_ text: String) -> Int {
        text.reduce(0) { count, character in
            character.isWhitespace ? count : count + 1
        }
    }

    /// 保存用的要点：去空、去首尾空白、最多 3 条。
    static func normalizedPoints(_ points: [String]) -> [String] {
        points.compactMap(clean).prefix(3).map { $0 }
    }

    /// 三段式拼成一段可读文字（要点前带「·」）。
    static func joinedStructured(mainIdea: String?, points: [String], takeaway: String?) -> String {
        var parts: [String] = []
        if let idea = clean(mainIdea) { parts.append(idea) }
        let items = normalizedPoints(points)
        if !items.isEmpty {
            parts.append(items.map { "· \($0)" }.joined(separator: "\n"))
        }
        if let judge = clean(takeaway) { parts.append(judge) }
        return parts.joined(separator: "\n\n")
    }

    /// 这条记录对外显示的文字：按它自己的模式渲染。
    static func displayText(for entry: PracticeEntry) -> String {
        switch entry.mode {
        case .structured:
            return joinedStructured(mainIdea: entry.mainIdea, points: entry.points, takeaway: entry.takeaway)
        case .free:
            return clean(entry.freeText) ?? ""
        }
    }

    /// 切换模式时**只在目标模式为空的情况下**搬运内容。
    ///
    /// 刻意不「切一次就清空另一边」：那样来回切两次，先写的要点就没了。
    /// 两边都有内容时以当前正在编辑的模式为准 —— 保存时按 `mode` 取对应的那份。
    /// 也刻意**不自动拆分**：机械拆出来的结构不是用户的结构。
    static func transferring(_ content: PracticeContent, to target: PracticeMode) -> PracticeContent {
        guard target != content.mode else { return content }

        var result = content
        switch target {
        case .structured:
            let hasStructured = clean(content.mainIdea) != nil
                || !normalizedPoints(content.points).isEmpty
                || clean(content.takeaway) != nil
            if !hasStructured, let free = clean(content.freeText) {
                result.mainIdea = free
            }
        case .free:
            if clean(content.freeText) == nil {
                result.freeText = joinedStructured(
                    mainIdea: content.mainIdea,
                    points: content.points,
                    takeaway: content.takeaway
                )
            }
        }
        result.mode = target
        return result
    }

    /// 有没有写够到可以保存的地步。
    /// 三段式：至少主旨；自由写：至少一句话。
    static func canSave(_ content: PracticeContent) -> Bool {
        switch content.mode {
        case .structured:
            return clean(content.mainIdea) != nil
        case .free:
            return clean(content.freeText) != nil
        }
    }

    /// 草稿里有没有值得留下的内容（全空就不该造草稿文件）。
    static func isBlank(_ content: PracticeContent) -> Bool {
        clean(content.mainIdea) == nil
            && normalizedPoints(content.points).isEmpty
            && clean(content.takeaway) == nil
            && clean(content.freeText) == nil
    }

    /// 保存后的这条记录与界面上的内容是否一致 —— 用来判断「返回修改」后
    /// 内容真的变了没有（变了就要把旧的 AI 点评作废）。
    static func matches(entry: PracticeEntry, content: PracticeContent) -> Bool {
        guard entry.mode == content.mode else { return false }
        switch content.mode {
        case .structured:
            return clean(entry.mainIdea) == clean(content.mainIdea)
                && normalizedPoints(entry.points) == normalizedPoints(content.points)
                && clean(entry.takeaway) == clean(content.takeaway)
        case .free:
            return clean(entry.freeText) == clean(content.freeText)
        }
    }
}
