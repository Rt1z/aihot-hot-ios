import Foundation

/// 从 /hot 页面文本里抽取「公开 API 没有、但页面会显示」的几个字段：
/// 榜单更新时间、前三条的热度指数与涨跌、爆/新上榜 标记。
///
/// 设计原则：**宁可少抽，不可抽错**。只认「热度指数」这个文案锚点，
/// 抽不到就整块丢弃，界面退回 API 字段展示（见 HotTopicsStore）。
struct HotPageEnrichment: Equatable {

    enum Delta: Equatable {
        case up(Int)
        case down(Int)
        case flat

        var text: String {
            switch self {
            case .up(let percent): return "↑ \(percent)%"
            case .down(let percent): return "↓ \(percent)%"
            case .flat: return "持平"
            }
        }

        var isUp: Bool {
            if case .up = self { return true }
            return false
        }

        var isDown: Bool {
            if case .down = self { return true }
            return false
        }
    }

    struct RankInfo: Equatable {
        let rank: Int
        let heat: Int?
        let delta: Delta?
        let isBreakout: Bool
        let isNew: Bool

        var hasAnyBadge: Bool {
            delta != nil || isBreakout || isNew
        }
    }

    let updatedText: String?
    let ranks: [RankInfo]

    func info(for rank: Int) -> RankInfo? {
        ranks.first { $0.rank == rank }
    }

    var hasHeatValues: Bool {
        ranks.contains { $0.heat != nil }
    }
}

enum HotPageEnricher {

    /// 徽章只可能出现在序号所在的那一行，所以只扫第一行（并设一个长度上限）。
    /// 窗口宁小勿大：漏一个徽章无害，标错很显眼。
    private static let badgeLineLimit = 40

    /// - Parameter excludingTitles: 已知的标题列表（来自接口）。先把标题从文本里
    ///   剔除，标题里的「新」「爆」就不会被误判成徽章。
    static func parse(text: String, excludingTitles titles: [String] = []) -> HotPageEnrichment? {
        var body = text
        for title in titles where title.count >= 6 {
            body = body.replacingOccurrences(of: title, with: "\n")
        }

        let updated = parseUpdatedText(body)
        let ranks = parseRankInfos(body)

        if updated == nil && ranks.isEmpty {
            return nil
        }
        return HotPageEnrichment(updatedText: updated, ranks: ranks)
    }

    // MARK: - 更新时间

    /// 页面头部：「10月12日 10:35 更新」
    static func parseUpdatedText(_ text: String) -> String? {
        let pattern = "([0-9]{1,2}月[0-9]{1,2}日\\s*[0-9]{1,2}:[0-9]{2})\\s*更新"
        guard let match = RegexUtil.firstMatch(pattern, in: text) else { return nil }
        return RegexUtil.group(match, at: 1, in: text)?.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 前三条的热度与徽章

    static func parseRankInfos(_ text: String) -> [HotPageEnrichment.RankInfo] {
        // 抓两位数字：如果页面把第 10 名也写成 NO.10，不能被读成 NO.01。
        // 所有序号都参与「分块边界」，但只有 1–3 名会产出热度/徽章。
        let markerPattern = "NO\\.?\\s*0?([0-9]{1,2})(?![0-9])"
        let markers = RegexUtil.matches(markerPattern, in: text)
        guard !markers.isEmpty else { return [] }

        let nsText = text as NSString
        var infos: [HotPageEnrichment.RankInfo] = []

        for (index, marker) in markers.enumerated() {
            guard let rankText = RegexUtil.group(marker, at: 1, in: text),
                  let rank = Int(rankText),
                  (1...3).contains(rank) else { continue }

            let blockStart = marker.range.location + marker.range.length
            let blockEnd: Int = {
                if index + 1 < markers.count {
                    return markers[index + 1].range.location
                }
                return min(nsText.length, blockStart + 4000)
            }()
            guard blockEnd > blockStart else { continue }

            let block = nsText.substring(with: NSRange(location: blockStart, length: blockEnd - blockStart))

            let heat = parseHeat(in: block)
            let (delta, isBreakout, isNew) = parseBadges(in: block)

            infos.append(
                HotPageEnrichment.RankInfo(
                    rank: rank,
                    heat: heat,
                    delta: delta,
                    isBreakout: isBreakout,
                    isNew: isNew
                )
            )
        }

        // 同一个序号出现多次时只保留信息量最大的那条
        var best: [Int: HotPageEnrichment.RankInfo] = [:]
        for info in infos {
            if let existing = best[info.rank] {
                let existingScore = (existing.heat != nil ? 1 : 0) + (existing.delta != nil ? 1 : 0)
                let newScore = (info.heat != nil ? 1 : 0) + (info.delta != nil ? 1 : 0)
                if newScore > existingScore { best[info.rank] = info }
            } else {
                best[info.rank] = info
            }
        }

        return best.values.sorted { $0.rank < $1.rank }
    }

    private static func parseHeat(in block: String) -> Int? {
        // 热度数字排在卡片最后（标题 → 正文 digest → 来源行 → 数字 → 热度指数），
        // 离序号可能有几百字，所以**不设距离窗口**：块的边界由下一个序号界定，
        // 块内取**最后一处**匹配，避免正文里万一提到「热度指数」时抢在前面。
        let pattern = "([0-9][0-9,]{0,6})\\s*[\\r\\n\\s]*热度指数"
        guard let match = RegexUtil.matches(pattern, in: block).last else { return nil }
        guard let raw = RegexUtil.group(match, at: 1, in: block) else { return nil }
        return Int(raw.replacingOccurrences(of: ",", with: ""))
    }

    private static func parseBadges(in block: String)
        -> (HotPageEnrichment.Delta?, Bool, Bool) {

        // 只取序号之后的第一行非空文字：徽章和序号在同一行，
        // 标题通常在下一行，这样标题里的「新」「爆」不会误判。
        let firstLine = block
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let head = String(firstLine.prefix(badgeLineLimit))
        guard !head.isEmpty else { return (nil, false, false) }

        var delta: HotPageEnrichment.Delta?
        var deltaLocation = Int.max

        if let match = RegexUtil.firstMatch("↑\\s*([0-9]{1,4})\\s*%", in: head),
           let raw = RegexUtil.group(match, at: 1, in: head),
           let percent = Int(raw) {
            delta = .up(percent)
            deltaLocation = match.range.location
        }
        if let match = RegexUtil.firstMatch("↓\\s*([0-9]{1,4})\\s*%", in: head),
           let raw = RegexUtil.group(match, at: 1, in: head),
           let percent = Int(raw),
           match.range.location < deltaLocation {
            delta = .down(percent)
            deltaLocation = match.range.location
        }
        if let match = RegexUtil.firstMatch("持平", in: head),
           match.range.location < deltaLocation {
            delta = .flat
            deltaLocation = match.range.location
        }

        let isBreakout = RegexUtil.firstMatch("爆", in: head) != nil
        let isNew = RegexUtil.firstMatch("新上榜", in: head) != nil
            || RegexUtil.firstMatch("(^|[^最])新($|[^上])", in: head) != nil

        return (delta, isBreakout, isNew)
    }
}
