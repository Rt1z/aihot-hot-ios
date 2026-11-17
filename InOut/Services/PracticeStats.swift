import Foundation

/// 练习本顶部的三个数字。
struct PracticeStats: Equatable {
    let total: Int
    let thisWeek: Int
    let streakDays: Int

    static let empty = PracticeStats(total: 0, thisWeek: 0, streakDays: 0)
}

/// 纯函数：给一组练习记录和「此刻」，算出总篇数 / 本周篇数 / 连续天数。
///
/// 全部按**北京时间**切天，与 `RelativeTime` 同一口径 —— 否则「哪一天」会按设备时区
/// 或 UTC 切，出国或改时区就会看到断签。不读 `Date()`，`now` 由调用方传入，
/// 所以同一份记录永远得到同一组数字（镜像 23 两边钉住）。
enum PracticeStatsCalculator {

    /// 北京时间的公历。一周从周一开始（与中文习惯一致，也让「本周」可预期）。
    static func beijingCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_Hans_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        calendar.firstWeekday = 2
        return calendar
    }

    static func make(entries: [PracticeEntry], now: Date = Date()) -> PracticeStats {
        let calendar = beijingCalendar()

        let thisWeek: Int
        if let week = calendar.dateInterval(of: .weekOfYear, for: now) {
            thisWeek = entries.reduce(0) { count, entry in
                week.contains(entry.createdAt) ? count + 1 : count
            }
        } else {
            thisWeek = 0
        }

        let days = Set(entries.map { calendar.startOfDay(for: $0.createdAt) })
        return PracticeStats(
            total: entries.count,
            thisWeek: thisWeek,
            streakDays: streak(days: days, now: now, calendar: calendar)
        )
    }

    /// 连续天数：从今天往回数；今天还没写就从昨天起算（否则白天会显示断签）。
    /// 昨天也没有就是 0。
    static func streak(days: Set<Date>, now: Date, calendar: Calendar) -> Int {
        guard !days.isEmpty else { return 0 }

        let today = calendar.startOfDay(for: now)
        var cursor: Date
        if days.contains(today) {
            cursor = today
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
                  days.contains(yesterday) {
            cursor = yesterday
        } else {
            return 0
        }

        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }
}
