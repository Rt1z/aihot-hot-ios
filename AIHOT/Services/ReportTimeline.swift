import Foundation

/// 「报道节奏」：把 `Story.reports` 按北京时间切成时间桶，供详情页画成柱状图。
///
/// 纯函数，**不读 `Date()`**：时间窗口完全由数据自己决定（最早那条到最新那条），
/// 所以同一条 story 永远得到同样的图 —— 可以被夹具钉住，也能被 Python 镜像复现。
/// （`tools/logic_tests.py` 的「镜像 9」是这份逻辑的镜像，改这里就要改那里。）
///
/// 三个必须守住的性质：
///
/// 1. **空桶要留着**（`count == 0`）。中间那段没人报道的时间本身就是「已经凉了」的信号，
///    把空桶删掉等于把结论删掉。
/// 2. **桶数 ≤ `maximumBuckets`**。x 轴是**按标签分类**的轴，标签重名会被合并成一根柱子；
///    而「桶数 ≤ 24」正好保证了这一档的标签不可能重复（同名的钟点要跨 24 小时才出现一次）。
///    这不是为了好看，是轴正确性的前提。
/// 3. **对齐到北京时间的桶边界**（`Asia/Shanghai`），与 `RelativeTime` 同一个口径 ——
///    否则「哪一天」会按 UTC 切，图上的一天和用户理解的一天不是同一天。
enum ReportTimeline {

    /// 时间桶上限，见上面第 2 条。
    static let maximumBuckets = 24
    /// x 轴最多显示几个刻度（首尾一定在里面）。
    static let maximumAxisLabels = 5

    /// 桶的粒度，按 `allCases` 的顺序从细到粗试。
    enum Interval: CaseIterable {
        case fifteenMinutes
        case hour
        case day
    }

    struct Bucket: Equatable {
        /// 桶起点（已按北京时间对齐）
        let start: Date
        /// 轴上显示的文字：「14:00」或「10月12日」
        let label: String
        let count: Int
        let isPeak: Bool
        let isNewest: Bool
    }

    struct Summary: Equatable {
        let buckets: [Bucket]
        /// 报道最多的一桶；并列取**最早**的那个
        let peak: Bucket
        /// 图上真正用到的报道数（没有 `publishedAt` 的已经被剔除）
        let totalTimestamped: Int
        /// 距最新一条 24 小时内（含边界）的条数
        let last24HourCount: Int
        /// x 轴刻度，最多 5 个，首尾一定在内
        let axisLabels: [String]
        /// 接口说一共有更多报道（`reportCount` > 图上用的条数）。
        /// 为真时界面要说清「这张图只统计了其中能定时的那些」，**不编造数字**。
        let truncated: Bool
    }

    /// 桶数不足 2 个时返回 `nil`：一根柱子的图没有可比性，界面直接不画这一节。
    static func make(story: Story) -> Summary? {
        // 没有时间的报道留在文字时间线里，但不进图（图上放不下「不知道什么时候」）
        let dated = (story.reports ?? []).compactMap { $0.publishedAt }.sorted()
        guard dated.count >= 2, let first = dated.first, let last = dated.last else { return nil }

        // 从最细的一档开始试，取第一个装得下的；都装不下就用最粗的（每天），
        // 这时柱子可能超过 24 根 —— 真实数据到不了，轴刻度会自动稀疏。
        var interval = Interval.day
        var starts: [Date] = []
        for candidate in Interval.allCases {
            interval = candidate
            starts = bucketStarts(from: first, to: last, interval: candidate)
            if starts.count <= maximumBuckets { break }
        }
        guard starts.count >= 2 else { return nil }

        // starts 是升序的网格，所以「最后一个 ≤ 该时间的桶起点」就是它落在的桶。
        // 用 `<=` 而不是 `<`：正好踩在边界上的报道算进它右边那一桶。
        var counts = [Int](repeating: 0, count: starts.count)
        for date in dated {
            guard let index = starts.lastIndex(where: { $0 <= date }) else { continue }
            counts[index] += 1
        }

        let maximum = counts.max() ?? 0
        let peakIndex = counts.firstIndex(of: maximum) ?? 0

        let buckets = starts.indices.map { index in
            Bucket(
                start: starts[index],
                label: label(for: starts[index], interval: interval),
                count: counts[index],
                isPeak: index == peakIndex,
                isNewest: index == counts.count - 1
            )
        }

        let cutoff = last.addingTimeInterval(-86_400)
        let labels = buckets.map { $0.label }

        return Summary(
            buckets: buckets,
            peak: buckets[peakIndex],
            totalTimestamped: dated.count,
            last24HourCount: dated.filter { $0 >= cutoff }.count,
            axisLabels: axisLabels(from: labels),
            truncated: (story.reportCount ?? 0) > dated.count
        )
    }

    // MARK: - 时间桶

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_Hans_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }()

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    /// 把时间对齐到所属桶的起点。
    ///
    /// 用「取北京时间的分量、抹掉低位、再构造回来」而不是 `dateInterval(of:for:)`：
    /// 15 分钟这一档没有对应的 `Calendar.Component`，手工抹分是唯一统一的写法，
    /// 也正是 Python 镜像那边 `replace(minute=...)` 做的事。
    private static func floor(_ date: Date, interval: Interval) -> Date {
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        switch interval {
        case .fifteenMinutes: parts.minute = (parts.minute ?? 0) / 15 * 15
        case .hour: parts.minute = 0
        case .day:
            parts.hour = 0
            parts.minute = 0
        }
        parts.second = 0
        parts.nanosecond = 0
        return calendar.date(from: parts) ?? date
    }

    private static func advance(_ date: Date, by interval: Interval) -> Date? {
        switch interval {
        case .fifteenMinutes: return calendar.date(byAdding: .minute, value: 15, to: date)
        case .hour: return calendar.date(byAdding: .hour, value: 1, to: date)
        case .day: return calendar.date(byAdding: .day, value: 1, to: date)
        }
    }

    private static func bucketStarts(from first: Date, to last: Date, interval: Interval) -> [Date] {
        let end = floor(last, interval: interval)
        var starts: [Date] = []
        var cursor = floor(first, interval: interval)
        // 上限只是防呆：正常数据里桶数由 `maximumBuckets` 和真实跨度决定
        while cursor <= end, starts.count < 400 {
            starts.append(cursor)
            guard let next = advance(cursor, by: interval) else { break }
            cursor = next
        }
        return starts
    }

    private static func label(for start: Date, interval: Interval) -> String {
        switch interval {
        case .fifteenMinutes, .hour: return clockFormatter.string(from: start)
        case .day: return dayFormatter.string(from: start)
        }
    }

    /// 桶数多于 5 个时挑 5 个刻度：下标 `i * (n - 1) / 4`。
    ///
    /// **只用整数除法，绝不能用 `round()`**：Python 的 `round()` 是银行家舍入
    /// （`round(12.5) == 12`）、Swift 的 `rounded()` 是四舍五入（`12.5 -> 13`），
    /// 一旦引入浮点舍入，`n = 25` 时两边会挑出不同的刻度，而这是镜像测试里
    /// 最难看出原因的一类分叉。整数除法两边行为完全一致（都是向下取整）。
    private static func axisLabels(from labels: [String]) -> [String] {
        let count = labels.count
        guard count > maximumAxisLabels else { return labels }

        var indices: [Int] = []
        for step in 0..<maximumAxisLabels {
            let index = step * (count - 1) / (maximumAxisLabels - 1)
            if indices.last != index { indices.append(index) }
        }
        return indices.map { labels[$0] }
    }
}
