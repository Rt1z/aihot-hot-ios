import SwiftUI

/// 一条练习记录的正文展示（对照页与回看页共用）。
///
/// 按记录自己的模式渲染：三段式分块显示，自由写原样显示 ——
/// 两种模式各自是一份完整的表达，不强行合并成一种版式。
struct PracticeSummaryView: View {

    let entry: PracticeEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch entry.mode {
            case .free:
                Text(PracticeText.clean(entry.freeText) ?? "（没有留下文字）")
                    .font(Typography.body)
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

            case .structured:
                if let idea = PracticeText.clean(entry.mainIdea) {
                    Text(idea)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                let points = PracticeText.normalizedPoints(entry.points)
                if !points.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(Theme.accent)
                                    .frame(width: 16, alignment: .leading)
                                Text(point)
                                    .font(Typography.body)
                                    .foregroundColor(Theme.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                if let takeaway = PracticeText.clean(entry.takeaway) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("我的判断")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.accent)
                        Text(takeaway)
                            .font(Typography.body)
                            .foregroundColor(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
