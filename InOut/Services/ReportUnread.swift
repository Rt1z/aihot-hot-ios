import Foundation

/// Tab 角标的纯判断：「有没有还没看过的期」。
///
/// 只看期号，不看内容 —— 已发布的期次不可变（规则 19），期号变了就是新一期。
/// **任一侧缺失都不算未读**：本地还没有基线（新装用户）时不该挂角标，
/// 基线由 `ReportStore.observeLatest` 在第一次看到某一期时补上。
enum ReportUnread {

    static func isUnread(latest: String?, lastSeen: String?) -> Bool {
        guard let latest = latest, let lastSeen = lastSeen else { return false }
        return latest != lastSeen
    }
}
