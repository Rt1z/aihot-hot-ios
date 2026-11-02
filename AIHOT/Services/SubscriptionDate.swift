import Foundation

/// 订阅源的两种时间格式。
///
/// 全部是纯函数：同一段输入永远得到同一个 `Date`，镜像 22 用同一批夹具断言。
enum SubscriptionDate {

    /// RSSHub / RSS 2.0 的 `pubDate`：RFC 1123（`Tue, 21 Oct 2026 10:00:00 GMT`）。
    static func parseRSS(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // 少数 feed 直接给 ISO8601；先试项目里已有的解析器。
        if let date = AIHOTDate.parse(text) { return date }

        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss zzz",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss Z"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// 公众号接口的时间：
    /// - Unix 秒/毫秒（纯数字，10 或 13 位）；
    /// - `yyyy-MM-dd HH:mm:ss` / `yyyy-MM-dd HH:mm` / `yyyy-MM-dd`，按北京时间。
    static func parseWeChat(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // 有些接口直接给 ISO8601（带 Z 或 +08:00）。
        if let date = AIHOTDate.parse(text) { return date }

        if text.allSatisfy({ $0.isNumber }) {
            if let value = Double(text) {
                if text.count >= 13 { return Date(timeIntervalSince1970: value / 1000) }
                if text.count >= 9 { return Date(timeIntervalSince1970: value) }
            }
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss.SSS",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy/MM/dd HH:mm",
            "yyyy/MM/dd"
        ]
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
