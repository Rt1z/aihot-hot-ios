import Foundation

struct ParsedSubscriptionConfig: Equatable {
    let config: SubscriptionConfig
    /// 被跳过的条目说明。文案里只出现「第几条、哪个字段」，不把整段配置倒出来。
    let warnings: [String]
}

enum SubscriptionConfigError: LocalizedError, Equatable {
    case notJSONObject

    var errorDescription: String? {
        switch self {
        case .notJSONObject:
            return "订阅配置不是 JSON 对象"
        }
    }
}

/// 把电脑上的 `subscriptions.json` 解析成信源清单。
///
/// **逐条 salvage，不整份失败**：配置文件是手写的，把一条 `uid` 写错不该让整页订阅消失。
/// 未知字段忽略（前向兼容）；数组缺失只给警告；总数封顶 50，防止手滑写出一个「计费炸弹」。
enum SubscriptionConfigParser {

    /// 最多 50 条信源。公众号按次计费，配置写错时这个上限是最后一道闸。
    static let maximumSources = 50

    static func parse(data: Data) throws -> ParsedSubscriptionConfig {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SubscriptionConfigError.notJSONObject
        }
        guard let root = object as? [String: Any] else {
            throw SubscriptionConfigError.notJSONObject
        }

        var warnings: [String] = []
        let version = intValue(root["version"]) ?? intValue(root["schemaVersion"]) ?? 1
        if version > 1 {
            warnings.append("配置版本是 \(version)，比 App 认识的新；没认出的字段会被忽略")
        }

        var seenIDs = Set<String>()
        var wechat: [SubscriptionSource] = []
        var bilibili: [SubscriptionSource] = []

        let rawWechat = root["wechat"]
        if let rawWechat = rawWechat, !(rawWechat is NSNull) {
            if let entries = rawWechat as? [Any] {
                for (index, entry) in entries.enumerated() {
                    guard let dict = entry as? [String: Any] else {
                        warnings.append("wechat 第 \(index + 1) 条不是对象，已跳过")
                        continue
                    }
                    guard let source = parseWeChat(dict, index: index, warnings: &warnings) else {
                        continue
                    }
                    guard !seenIDs.contains(source.id) else {
                        warnings.append("wechat 第 \(index + 1) 条与前面的信源重复，已跳过")
                        continue
                    }
                    seenIDs.insert(source.id)
                    wechat.append(source)
                }
            } else {
                warnings.append("wechat 不是数组，整段已忽略")
            }
        }

        let rawBilibili = root["bilibili"]
        if let rawBilibili = rawBilibili, !(rawBilibili is NSNull) {
            if let entries = rawBilibili as? [Any] {
                for (index, entry) in entries.enumerated() {
                    guard let dict = entry as? [String: Any] else {
                        warnings.append("bilibili 第 \(index + 1) 条不是对象，已跳过")
                        continue
                    }
                    guard let source = parseBilibili(dict, index: index, warnings: &warnings) else {
                        continue
                    }
                    guard !seenIDs.contains(source.id) else {
                        warnings.append("bilibili 第 \(index + 1) 条与前面的信源重复，已跳过")
                        continue
                    }
                    seenIDs.insert(source.id)
                    bilibili.append(source)
                }
            } else {
                warnings.append("bilibili 不是数组，整段已忽略")
            }
        }

        let total = wechat.count + bilibili.count
        if total > maximumSources {
            warnings.append("信源超过 \(maximumSources) 条，只保留前 \(maximumSources) 条")
            let keepWeChat = min(wechat.count, maximumSources)
            wechat = Array(wechat.prefix(keepWeChat))
            let remaining = maximumSources - wechat.count
            bilibili = Array(bilibili.prefix(max(remaining, 0)))
        }

        return ParsedSubscriptionConfig(
            config: SubscriptionConfig(wechat: wechat, bilibili: bilibili),
            warnings: warnings
        )
    }

    // MARK: - 公众号

    private static func parseWeChat(
        _ dict: [String: Any],
        index: Int,
        warnings: inout [String]
    ) -> SubscriptionSource? {
        let name = stringValue(dict["name"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawURL = stringValue(dict["url"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawBiz = stringValue(dict["biz"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let biz = (rawBiz?.isEmpty == false) ? rawBiz : nil

        // 非 http(s) 的链接永远不发给 Dajiala：有 biz 时它只是展示兜底，
        // 没有 biz 时就必须是合法地址，否则整条跳过。
        let url: String?
        if let rawURL = rawURL, !rawURL.isEmpty {
            if isHTTPURL(rawURL) {
                url = rawURL
            } else if biz != nil {
                url = nil
            } else {
                warnings.append("wechat 第 \(index + 1) 条的 url 不是 http(s) 地址，已跳过")
                return nil
            }
        } else {
            url = nil
        }

        guard biz != nil || url != nil else {
            warnings.append("wechat 第 \(index + 1) 条既没有 biz 也没有 url，已跳过")
            return nil
        }

        // 从示例文章链接里顺手把 __biz 提出来：请求体优先用 biz（比链接稳），
        // id 也用它，换一篇示例文章不会重置 6 小时计费窗口。
        let resolvedBiz = biz ?? extractWeChatBiz(from: url ?? "")
        let identity = resolvedBiz ?? url ?? ""
        guard !identity.isEmpty else {
            warnings.append("wechat 第 \(index + 1) 条取不出稳定的 id，已跳过")
            return nil
        }

        return SubscriptionSource(
            id: "wechat:" + identity,
            kind: .wechat,
            name: name,
            request: .wechat(url: url, biz: resolvedBiz),
            isEnabled: enabledValue(dict["enabled"])
        )
    }

    /// 从 `mp.weixin.qq.com` 文章链接的查询串里取 `__biz`。
    /// 用它而不是整条 URL 做 id，换一篇示例文章也不会把 6 小时计费窗口重置。
    static func extractWeChatBiz(from raw: String) -> String? {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              host == "mp.weixin.qq.com" || host.hasSuffix(".mp.weixin.qq.com"),
              let items = components.queryItems
        else { return nil }
        for item in items where item.name == "__biz" {
            let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: - B 站

    private static func parseBilibili(
        _ dict: [String: Any],
        index: Int,
        warnings: inout [String]
    ) -> SubscriptionSource? {
        let name = stringValue(dict["name"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawRoute = stringValue(dict["route"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawUID = stringValue(dict["uid"])?.trimmingCharacters(in: .whitespacesAndNewlines)

        let route: String
        if let rawRoute = rawRoute, !rawRoute.isEmpty {
            guard let normalized = normalizedBilibiliRoute(rawRoute) else {
                warnings.append("bilibili 第 \(index + 1) 条的 route 不合法（必须是 /bilibili/ 开头的站内路由），已跳过")
                return nil
            }
            route = normalized
        } else if let rawUID = rawUID, !rawUID.isEmpty {
            guard isValidUID(rawUID) else {
                warnings.append("bilibili 第 \(index + 1) 条的 uid 含非法字符，已跳过")
                return nil
            }
            route = "/bilibili/user/video/" + rawUID
        } else {
            warnings.append("bilibili 第 \(index + 1) 条既没有 route 也没有 uid，已跳过")
            return nil
        }

        return SubscriptionSource(
            id: "bilibili:" + route,
            kind: .bilibili,
            name: name,
            request: .bilibili(route: route),
            isEnabled: enabledValue(dict["enabled"])
        )
    }

    /// 只接受 RSSHub 站内路由。拒绝 scheme、host、`..` 与 `#`，
    /// 否则配置文件就成了一个「让 App 去局域网任意地址取东西」的 SSRF 入口。
    static func normalizedBilibiliRoute(_ raw: String) -> String? {
        var route = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !route.isEmpty else { return nil }
        guard route.hasPrefix("/bilibili/") else { return nil }
        guard !route.contains("://") else { return nil }
        guard !route.hasPrefix("//") else { return nil }
        guard !route.contains("..") else { return nil }
        guard !route.contains("#") else { return nil }
        // 查询串允许（RSSHub 有些路由带参数），但只保留第一个 `?` 之后的部分。
        if let question = route.firstIndex(of: "?") {
            let path = String(route[route.startIndex..<question])
            guard path.hasPrefix("/bilibili/") else { return nil }
        }
        while route.count > 1 && route.hasSuffix("/") { route.removeLast() }
        return route
    }

    private static func isValidUID(_ uid: String) -> Bool {
        guard !uid.isEmpty else { return false }
        for scalar in uid.unicodeScalars {
            let value = scalar.value
            let letter = (value >= 0x41 && value <= 0x5A) || (value >= 0x61 && value <= 0x7A)
            let digit = value >= 0x30 && value <= 0x39
            if letter || digit || value == 0x5F || value == 0x2D { continue }
            return false
        }
        return true
    }

    // MARK: - 小工具

    private static func enabledValue(_ raw: Any?) -> Bool {
        // 只有字面量 false 才算停用；缺失/类型写错都按启用处理（老配置无感）。
        (raw as? Bool) ?? true
    }

    private static func stringValue(_ raw: Any?) -> String? {
        raw as? String
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? String { return Int(value) }
        return nil
    }

    private static func isHTTPURL(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty
        else { return false }
        return true
    }
}
