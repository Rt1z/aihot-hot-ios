import Foundation

/// 周报/月报期号与日期区间 → 展示文案，以及往期按月分组。
///
/// 纯函数：不读 `Date()`、不碰网络/磁盘，所以同一批数据永远得到同样的结果，
/// 能被夹具钉住（镜像 18，`tools/logic_tests.py`）。
///
/// 日期只做 `yyyy-MM-dd` 的**字符串**切分，不构造 `Date` ——
/// 与「价格留展示原文」同一信条：不引入日历/时区依赖，也就没有日历 bug 可言。
enum ReportPeriod {

    struct MonthGroup: Equatable {
        let title: String
        let entries: [ReportEntry]
    }

    /// `"2026-W42"` → `"2026 年第 42 周"`；`"2026-09"` → `"2026 年 9 月"`。
    /// 认不出的格式返回 nil，由界面退回期号原文（宁可显示 `2026-W42`，不可显示错的中文）。
    static func title(periodKey: String) -> String? {
        if let match = RegexUtil.firstMatch(#"^(\d{4})-W(\d{1,2})$"#, in: periodKey),
           let year = RegexUtil.group(match, at: 1, in: periodKey),
           let weekText = RegexUtil.group(match, at: 2, in: periodKey),
           let week = Int(weekText), (1...53).contains(week) {
            return "\(year) 年第 \(week) 周"
        }
        if let match = RegexUtil.firstMatch(#"^(\d{4})-(\d{2})$"#, in: periodKey),
           let year = RegexUtil.group(match, at: 1, in: periodKey),
           let monthText = RegexUtil.group(match, at: 2, in: periodKey),
           let month = Int(monthText), (1...12).contains(month) {
            return "\(year) 年 \(month) 月"
        }
        return nil
    }

    /// `periodStart`/`periodEnd` → `"10.12 – 10.18"`；跨年补年份
    /// `"2025.12.29 – 2026.01.04"`。任一端缺失/格式不对 → nil：
    /// 区间缺一半没有信息量，宁可不显示（不编造数字）。
    static func rangeText(start: String?, end: String?) -> String? {
        guard let start = start, let end = end,
              let s = dateParts(start), let e = dateParts(end) else { return nil }
        if s.year == e.year {
            return "\(s.monthDay) – \(e.monthDay)"
        }
        return "\(s.full) – \(e.full)"
    }

    /// 往期按 `periodStart` 的年月分组：`"2026-10"` → 「2026 年 10 月」。
    ///
    /// **保持接口给的顺序**（索引本身就是新→旧，实测无乱序）——
    /// 不排序就不会有「同秒两条互换」的不稳定问题（同规则 8 的道理）。
    /// `periodStart` 缺失的条目归到末尾「其它」组。
    static func groupByMonth(_ entries: [ReportEntry]) -> [MonthGroup] {
        var order: [String] = []
        var buckets: [String: [ReportEntry]] = [:]
        var leftovers: [ReportEntry] = []

        for entry in entries {
            guard let start = entry.periodStart, dateParts(start) != nil else {
                leftovers.append(entry)
                continue
            }
            let key = String(start.prefix(7))   // "2026-10"
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key, default: []].append(entry)
        }

        var groups = order.map { key -> MonthGroup in
            let parts = key.split(separator: "-")
            let year = parts.count == 2 ? String(parts[0]) : ""
            let month = parts.count == 2 ? Int(parts[1]) : nil
            let title = (year.isEmpty || month == nil) ? "其它" : "\(year) 年 \(month!) 月"
            return MonthGroup(title: title, entries: buckets[key] ?? [])
        }
        if !leftovers.isEmpty {
            groups.append(MonthGroup(title: "其它", entries: leftovers))
        }
        return groups
    }

    // MARK: - 私有

    private struct DateParts {
        /// `"2026-10-12"` → `"2026.10.12"`（跨年文案用点分，与同年的 MM.dd 同一口径）
        let full: String
        /// `"2026-10-12"` → `"10.12"`
        let monthDay: String
        let year: String
    }

    /// 严格按 `yyyy-MM-dd` 校验后切分；认不出返回 nil。
    private static func dateParts(_ text: String) -> DateParts? {
        guard let match = RegexUtil.firstMatch(#"^(\d{4})-(\d{2})-(\d{2})$"#, in: text),
              let year = RegexUtil.group(match, at: 1, in: text),
              let month = RegexUtil.group(match, at: 2, in: text),
              let day = RegexUtil.group(match, at: 3, in: text),
              let monthValue = Int(month), (1...12).contains(monthValue),
              let dayValue = Int(day), (1...31).contains(dayValue)
        else { return nil }
        return DateParts(full: "\(year).\(month).\(day)", monthDay: "\(month).\(day)", year: year)
    }
}
