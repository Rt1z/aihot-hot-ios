import Foundation

/// 订阅页的分组。板块顺序 = `SubscriptionTopic.allCases`，空板块不出现。
struct SubscriptionSection: Identifiable, Equatable {
    let topic: SubscriptionTopic
    let items: [SubscriptionItem]
    var id: String { topic.rawValue }
}

/// 订阅条目的稳定 id。
///
/// 单测/镜像钉住的是「同样的输入永远得到同样的十六进制」，所以这里用 FNV-1a，
/// **不能用 Swift 的 `Hasher`**：它每次启动的种子都不同，缓存里的 id 会全变。
enum SubscriptionItemID {

    /// 优先用接口给的稳定 id（hashid / guid / 链接）；
    /// 都没有时用来源 + 标题 + 时间 + 链接算一个稳定哈希，并把来源算进去避免撞车。
    static func make(
        kind: SubscriptionSourceKind,
        sourceID: String,
        rawID: String?,
        link: String,
        title: String,
        publishedAt: Date?
    ) -> String {
        let trimmed = (rawID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return kind.rawValue + ":" + trimmed
        }
        // 毫秒整数，不用 String(format:) —— 后者会跟系统 locale 的十进制分隔符走，
        // 同一台设备换个区域就会得到不同的 id（镜像也没法复现）。
        let timestamp = publishedAt.map { String(Int64($0.timeIntervalSince1970 * 1000)) } ?? ""
        let seed = [
            kind.rawValue,
            sourceID,
            title,
            timestamp,
            link
        ].joined(separator: "|")
        return kind.rawValue + ":hash:" + fnv1a64Hex(seed)
    }

    /// FNV-1a 64 位，输出 16 位小写十六进制。逐 UTF-8 字节，Swift/Python 输入一致。
    static func fnv1a64Hex(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }
}

/// 订阅内容的合并 / 去重 / 排序 / 截断。
///
/// 排序规则必须能被镜像逐条复现：
/// - `publishedAt` 倒序；没有时间的排在最后（用 `-greatestFiniteMagnitude`，不要用 `Date()` 补）；
/// - 同一时间按标题的 **UTF-8 字节**升序（Swift 的 `String` 比较与 Python 的码点顺序在极端字符上
///   不完全一致，比字节最稳）；
/// - 再按 id 升序。
///
/// 去重保留排序后的第一条（即最新的那条）；总数封顶 600。
enum SubscriptionLogic {

    static let maximumItems = 600

    /// 某个源刷新成功后，整体替换它的旧条目。失败时不动旧条目。
    static func merge(
        existing: [SubscriptionItem],
        incoming: [SubscriptionItem],
        sourceID: String
    ) -> [SubscriptionItem] {
        existing.filter { $0.sourceID != sourceID } + incoming
    }

    /// 剪枝：只保留当前配置里**启用**的信源。`validSourceIDs == nil` 时不做剪枝
    /// （配置取不到时保留旧内容，避免一断网就清空订阅）。
    static func normalize(
        _ items: [SubscriptionItem],
        validSourceIDs: Set<String>? = nil,
        limit: Int = maximumItems
    ) -> [SubscriptionItem] {
        let filtered: [SubscriptionItem]
        if let valid = validSourceIDs {
            filtered = items.filter { valid.contains($0.sourceID) }
        } else {
            filtered = items
        }

        let sorted = filtered.sorted { lhs, rhs in
            let leftTime = lhs.publishedAt?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude
            let rightTime = rhs.publishedAt?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude
            if leftTime != rightTime { return leftTime > rightTime }
            let titleOrder = compareUTF8(lhs.title, rhs.title)
            if titleOrder != 0 { return titleOrder < 0 }
            return lhs.id < rhs.id
        }

        var seen = Set<String>()
        var result: [SubscriptionItem] = []
        result.reserveCapacity(min(sorted.count, limit))
        for item in sorted {
            guard !seen.contains(item.id) else { continue }
            seen.insert(item.id)
            result.append(item)
            if result.count >= limit { break }
        }
        return result
    }

    static func compareUTF8(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        let count = min(left.count, right.count)
        var index = 0
        while index < count {
            if left[index] != right[index] {
                return left[index] < right[index] ? -1 : 1
            }
            index += 1
        }
        if left.count == right.count { return 0 }
        return left.count < right.count ? -1 : 1
    }
}

enum SubscriptionGrouping {
    /// 输入必须已经过 `SubscriptionLogic.normalize`（顺序即页面顺序）。
    static func sections(items: [SubscriptionItem]) -> [SubscriptionSection] {
        var buckets: [SubscriptionTopic: [SubscriptionItem]] = [:]
        for item in items {
            buckets[item.topic, default: []].append(item)
        }
        var sections: [SubscriptionSection] = []
        for topic in SubscriptionTopic.allCases {
            guard let group = buckets[topic], !group.isEmpty else { continue }
            sections.append(SubscriptionSection(topic: topic, items: group))
        }
        return sections
    }
}

/// 刷新门槛。全部是纯函数，镜像 22 钉住。
enum SubscriptionRefreshPolicy {

    /// 公众号自动刷新：每个源 6 小时一次。
    static let weChatAutomaticInterval: TimeInterval = 6 * 60 * 60
    /// B 站免费，10 分钟一次。
    static let bilibiliAutomaticInterval: TimeInterval = 10 * 60
    /// 手动下拉的防连点地板（公众号仍然会花钱，不能一划就再花）。
    static let manualFloor: TimeInterval = 60
    /// Dajiala 限速 3 次/秒；留足余量，串行调用之间至少隔 0.5 秒。
    static let dajialaMinimumSpacing: TimeInterval = 0.5

    static func isDue(last: Date?, now: Date, floor: TimeInterval) -> Bool {
        guard let last = last else { return true }
        return now.timeIntervalSince(last) >= floor
    }

    static func shouldRefreshWeChat(lastAttemptAt: Date?, now: Date, manual: Bool) -> Bool {
        isDue(last: lastAttemptAt, now: now, floor: manual ? manualFloor : weChatAutomaticInterval)
    }

    static func shouldRefreshBilibili(lastAttemptAt: Date?, now: Date, manual: Bool) -> Bool {
        isDue(last: lastAttemptAt, now: now, floor: manual ? manualFloor : bilibiliAutomaticInterval)
    }

    static func nextDajialaDelay(lastCallAt: Date?, now: Date) -> TimeInterval {
        guard let last = lastCallAt else { return 0 }
        let elapsed = now.timeIntervalSince(last)
        return max(0, dajialaMinimumSpacing - elapsed)
    }
}

enum SubscriptionText {
    /// 摘要上限。Swift 按 Character 截断，Python 镜像按码点截断 ——
    /// 只在 emoji 组合字符这种极端输入上会有差异，正文不会因此丢字。
    static func clamp(_ text: String, limit: Int = 2000) -> String {
        if text.count <= limit { return text }
        return String(text.prefix(limit))
    }
}
