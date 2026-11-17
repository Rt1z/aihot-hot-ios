import Charts
import SwiftUI

/// 报道节奏柱状图：一眼看出这条是**正在爆发**还是**已经凉了**。
///
/// 这一层刻意做得很薄：分桶、标签、轴刻度全在 `ReportTimeline` 那个纯函数里
/// （那份逻辑有 Swift 单测和 Python 镜像钉着），这里只把结果画出来。
/// 所以：
///
/// - x 轴用纯函数给的**字符串标签**（分类轴），不用 `BarMark(x:unit:)` 的日期分桶 ——
///   分桶语义只能有一个来源，否则图和被测的逻辑会各说各话。
/// - 轴刻度也由纯函数给出，不用 `.automatic(desiredCount:)`。
/// - 颜色按 `bucket.isNewest` 取，不用 `Array(enumerated())` 的元组解构。
///
/// 「一根柱子」和「没有带时间的报道」这两种情形在 `ReportTimeline.make` 里就返回 nil 了，
/// 调用处会整节不显示，这里不必再判。
struct ReportTimelineChart: View {

    let summary: ReportTimeline.Summary
    var height: CGFloat = 104

    var body: some View {
        Chart(summary.buckets, id: \.label) { bucket in
            BarMark(
                x: .value("时间", bucket.label),
                y: .value("报道数", bucket.count)
            )
            // 最新那一桶画实，其余的淡一点：柱子高不高、最后一根有没有抬头，
            // 就是「还在涨 / 已经凉了」的全部信息。
            .foregroundStyle(bucket.isNewest ? Theme.accent : Theme.accent.opacity(0.45))
        }
        .chartXAxis {
            AxisMarks(values: summary.axisLabels) { _ in
                AxisValueLabel()
            }
        }
        // 纵轴不画：一根柱子几个像素的事，写数字反而更花；峰值靠下面那行说明讲清楚
        .chartYAxis(.hidden)
        .frame(height: height)
        .accessibilityLabel(
            "报道节奏：共 \(summary.totalTimestamped) 条报道，峰值 \(summary.peak.label) 的 \(summary.peak.count) 条"
        )
    }
}
