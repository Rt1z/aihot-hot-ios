import Foundation

/// Dajiala `post_history` 的响应解析。
///
/// **响应结构没有可引用的完整样例**（公开文档只写了请求参数与 `data` / `total_page`），
/// 所以这里用防御式读取：字段名支持几种常见别名、单条坏数据只跳过、认不出结构时
/// 抛出带「顶层字段名」的错误 —— 侧载设备挂不上调试器，这行字就是现场。
/// 真实抓包回来后，应按夹具收紧这段别名表（规则 13 的教训：不要拿猜的 payload 钉绿色）。
enum DajialaParser {

    static func parse(data: Data, source: SubscriptionSource) throws -> [SubscriptionItem] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SubscriptionError(kind: .decoding, message: "Dajiala 返回的不是 JSON")
        }

        let root: [String: Any]?
        if let dict = object as? [String: Any] {
            root = dict
        } else if object is [Any] {
            root = nil
        } else {
            throw SubscriptionError(kind: .decoding, message: "Dajiala 返回的 JSON 既不是对象也不是数组")
        }

        if let root = root {
            try checkTopLevelError(root)
        }

        let rows = itemArray(from: object, root: root)
        guard let rows = rows else {
            let keys = root?.keys.sorted().joined(separator: ", ") ?? "数组"
            throw SubscriptionError(
                kind: .decoding,
                message: "Dajiala 返回了内容但认不出格式（顶层字段：\(keys)）"
            )
        }

        var seen = Set<String>()
        var items: [SubscriptionItem] = []
        for row in rows {
            guard let dict = row as? [String: Any] else { continue }
            guard let item = makeItem(dict, source: source, seen: &seen) else { continue }
            items.append(item)
        }

        if !rows.isEmpty && items.isEmpty {
            throw SubscriptionError(
                kind: .decoding,
                message: "Dajiala 返回了 \(rows.count) 条，但都没有标题或链接"
            )
        }
        return items
    }

    // MARK: - 顶层错误

    private static func checkTopLevelError(_ root: [String: Any]) throws {
        let code = intValue(root["code"]) ?? intValue(root["status"]) ?? 0
        let message = stringValue(root["msg"])
            ?? stringValue(root["message"])
            ?? stringValue(root["error"])
            ?? ""

        switch code {
        case 0, 200:
            return
        case -1:
            throw SubscriptionError(
                kind: .rateLimited,
                message: "请求太快（Dajiala 限速 3 次/秒），稍后再试",
                retryAfter: 1
            )
        case 10002:
            throw SubscriptionError(
                kind: .badKey,
                message: "Dajiala Key 无效或已停用 —— 到 设置 → 订阅 换一个 Key"
            )
        case 20001:
            throw SubscriptionError(
                kind: .insufficientBalance,
                message: "Dajiala 余额不足，公众号内容暂时取不到"
            )
        case 20003:
            throw SubscriptionError(
                kind: .invalidConfig,
                message: "公众号链接里有未编码的 &，请改配置文件"
            )
        default:
            if let success = root["success"] as? Bool, success { return }
            let detail = message.isEmpty ? "" : "：\(message)"
            throw SubscriptionError(
                kind: .server,
                message: "Dajiala 返回 \(code)\(detail)"
            )
        }
    }

    // MARK: - 取条目数组

    private static func itemArray(from object: Any, root: [String: Any]?) -> [Any]? {
        if let array = object as? [Any] { return array }
        guard let root = root else { return nil }

        if let data = root["data"] {
            if let array = data as? [Any] { return array }
            if let dict = data as? [String: Any] {
                for key in ["list", "articles", "posts", "items", "rows"] {
                    if let array = dict[key] as? [Any] { return array }
                }
            }
        }
        for key in ["list", "articles", "posts", "items", "rows"] {
            if let array = root[key] as? [Any] { return array }
        }
        return nil
    }

    // MARK: - 单条

    private static func makeItem(
        _ dict: [String: Any],
        source: SubscriptionSource,
        seen: inout Set<String>
    ) -> SubscriptionItem? {
        let title = SubscriptionHTML.cleanTitle(
            stringValue(dict["title"]) ?? stringValue(dict["name"]) ?? ""
        )
        let link = (stringValue(dict["url"])
            ?? stringValue(dict["link"])
            ?? stringValue(dict["content_url"])
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !link.isEmpty else { return nil }

        let summaryRaw = stringValue(dict["digest"])
            ?? stringValue(dict["summary"])
            ?? stringValue(dict["desc"])
            ?? stringValue(dict["description"])
            ?? ""
        let summary = summaryRaw.contains("<")
            ? SubscriptionHTML.summary(from: summaryRaw)
            : SubscriptionText.clamp(SubscriptionHTML.collapseWhitespace(
                HTMLTextExtractor.decodeEntities(summaryRaw)
            ))

        let timeRaw = stringValue(dict["public_time"])
            ?? stringValue(dict["publish_time"])
            ?? stringValue(dict["publishTime"])
            ?? stringValue(dict["post_time"])
            ?? stringValue(dict["update_time"])
            ?? stringValue(dict["create_time"])
            ?? ""
        let publishedAt = SubscriptionDate.parseWeChat(timeRaw)

        let author = stringValue(dict["wx_name"])
            ?? stringValue(dict["author"])
            ?? stringValue(dict["nickname"])
            ?? ""
        let sourceName = source.name.isEmpty
            ? (author.isEmpty ? "公众号" : author)
            : source.name

        let rawID = stringValue(dict["hashid"])
            ?? stringValue(dict["appmsgid"])
            ?? stringValue(dict["id"])
            ?? stringValue(dict["aid"])
            ?? stringValue(dict["sn"])

        let id = SubscriptionItemID.make(
            kind: .wechat,
            sourceID: source.id,
            rawID: rawID,
            link: link,
            title: title,
            publishedAt: publishedAt
        )
        guard !seen.contains(id) else { return nil }
        seen.insert(id)

        let coverRaw = stringValue(dict["cover"])
            ?? stringValue(dict["cover_url"])
            ?? stringValue(dict["image"])
            ?? stringValue(dict["img"])
        let cover = coverRaw.flatMap {
            SubscriptionHTML.normalizeCoverURL($0, baseURL: link)
        }

        return SubscriptionItem(
            id: id,
            sourceID: source.id,
            sourceName: sourceName,
            kind: .wechat,
            title: title,
            summary: summary,
            link: link,
            coverURL: cover,
            publishedAt: publishedAt
        )
    }

    // MARK: - 小工具

    private static func stringValue(_ raw: Any?) -> String? {
        if let value = raw as? String { return value }
        if let value = raw as? NSNumber { return value.stringValue }
        return nil
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? String { return Int(value) }
        return nil
    }
}
