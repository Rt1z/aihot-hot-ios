import SwiftUI

/// 一条 AI 回答的 Markdown 分块渲染。
///
/// 解析在 `MarkdownBlocks`（纯函数，镜像 16 钉住），这里只负责画：
/// 块级结构自己排版，行内格式仍交给 Foundation 的 inline 解析。
///
/// **流式中也走这里**：出字是 70ms 一批（`AIChatModel.flushInterval`），
/// 不是逐字解析；分块器也没有「半截 Markdown」的失败态（没闭合的围栏算到文末）。
/// 这样代码块是逐行长出来的，不会像以前那样流式全程吐 ```、结束瞬间才换脸。
/// 总量可控是因为 LazyVStack 只会对可见的气泡跑这里的 body。
struct MarkdownBlocksView: View {

    let text: String

    var body: some View {
        let blocks = MarkdownBlocks.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inlineText(text)
        case .heading(let level, let text):
            inlineText(text)
                .font(Typography.markdownHeading(level))
        case .code(let language, let body):
            codeBlock(language: language, body: body)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listRow(item)
                }
            }
        case .quote(let text):
            inlineText(text)
                .foregroundColor(Theme.textSecondary)
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    // 竖条和文字同高：overlay 跟随被盖的视图尺寸，不靠 HStack 猜高度
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Theme.textTertiary)
                        .frame(width: 3)
                }
        case .rule:
            Divider()
                .padding(.vertical, 2)
        case .table(let header, let rows):
            table(header: header, rows: rows)
        }
    }

    /// 段落/标题/引用的正文：行内格式（**加粗** / `代码` / [链接](…)）交给 Foundation。
    /// 解析失败退回纯文本 —— 永远不该因为一条回答里有半截不合法的行内标记就整段不显示。
    private func inlineText(_ raw: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        let attributed = (try? AttributedString(markdown: raw, options: options))
            ?? AttributedString(raw)
        return Text(attributed)
            .font(Typography.body)
            .foregroundColor(Theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func codeBlock(language: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !language.isEmpty {
                Text(language)
                    .font(Typography.meta)
                    .foregroundColor(Theme.textTertiary)
                    .padding(EdgeInsets(top: 8, leading: 10, bottom: 0, trailing: 10))
            }
            Text(body)
                .font(Typography.markdownCode)
                .foregroundColor(Theme.textPrimary)
                // 长行折行显示，不嵌横向滚动：气泡里再套一个滚动方向容易和手势打架
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .textSelection(.enabled)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    private func listRow(_ item: MarkdownBlock.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(item.number.map { "\($0)." } ?? "•")
                .font(Typography.body)
                .foregroundColor(Theme.textSecondary)
                // 序号列右对齐：「9.」和「10.」不齐宽的话，正文列会跟着抖
                .frame(minWidth: 18, alignment: .trailing)
            inlineText(item.text)
        }
        .padding(.leading, CGFloat(item.level) * 16)
    }

    private func table(header: [String], rows: [[String]]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    inlineText(cell)
                        .font(Typography.body.weight(.semibold))
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        inlineText(cell)
                    }
                }
            }
        }
    }
}
