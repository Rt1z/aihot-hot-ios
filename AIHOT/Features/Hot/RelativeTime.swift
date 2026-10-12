import Foundation

/// 时间显示统一按北京时间和中文习惯走，和官网一致。
enum RelativeTime {

    static let locale = Locale(identifier: "zh_Hans_CN")

    private static var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }()

    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    private static let fullFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()

    /// 「刚刚 / 5 分钟前 / 3 小时前 / 2 天前 / 10月8日 / 2025年10月8日」
    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date = date else { return "" }
        let seconds = now.timeIntervalSince(date)

        if seconds < 0 { return "刚刚" }
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) 小时前" }
        if seconds < 86_400 * 30 { return "\(Int(seconds / 86_400)) 天前" }

        let nowYear = calendar.component(.year, from: now)
        let year = calendar.component(.year, from: date)
        return year == nowYear ? dayFormatter.string(from: date) : fullFormatter.string(from: date)
    }

    /// 「10月12日 10:35」
    static func absoluteShort(_ date: Date?) -> String {
        guard let date = date else { return "" }
        return absoluteFormatter.string(from: date)
    }

    /// 「yyyy年M月d日」用于详情页更正式的时间
    static func absoluteLong(_ date: Date?) -> String {
        guard let date = date else { return "" }
        return fullFormatter.string(from: date)
    }
}
