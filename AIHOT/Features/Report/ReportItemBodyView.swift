import SwiftUI

/// 周报/月报条目**正文**的渲染。
///
/// 解析在 `ReportItemBody`（纯函数，规则 18，镜像 20 钉住），这里只负责画：
/// 不切块、不抽字段、不猜样式。块的**顺序**就是页面的顺序（`ForEach` 用 offset
/// 而不是 `.self`：两段一模一样的文字在正文里很常见，用 `.self` 会串 identity）。
struct ReportItemBodyView: View {

    let blocks: [ReportItemBody.Block]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 行内链接走系统 openURL；详情页在外面把它改写成应用内的阅读器/网页弹窗
        .tint(Theme.accent)
    }

    @ViewBuilder
    private func blockView(_ block: ReportItemBody.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(Typography.markdownHeading(level))
                .foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let runs):
            paragraph(runs)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                            .font(.system(size: 15))
                            .foregroundColor(Theme.textSecondary)
                        paragraph(item)
                    }
                }
            }
        case .divider:
            // 原文里的分节线：留着才有「这一段结束了」的信息
            Divider()
        }
    }

    /// 一段正文。**必须**合成一个 `Text` —— 拆成「一个片段一个 View」会让每条
    /// 片段各占一行，段落被切碎、也不再折行。链接与加粗都是行内属性，
    /// 所以走 `AttributedString`（同 `MarkdownBlocksView` 的做法）。
    private func paragraph(_ runs: [ReportItemBody.Run]) -> some View {
        Text(attributed(runs))
            .font(.system(size: 15))
            .foregroundColor(Theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func attributed(_ runs: [ReportItemBody.Run]) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            if run.bold {
                piece.inlinePresentationIntent = .stronglyEmphasized
            }
            if let url = run.url {
                // Foundation 的 link 属性：`Text` 认它，于是链接能内联折行又能点
                piece.link = url
            }
            result.append(piece)
        }
        return result
    }
}
