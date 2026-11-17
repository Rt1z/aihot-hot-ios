import Foundation

/// 外部链接的校验与规范化（纯函数）。
///
/// 这里是「用户可以把什么东西放进收藏」的**安全边界**，和订阅功能里
/// 那个 B 站路由校验同一类问题：只接受公开的 http/https 网页，
/// 拒绝 `localhost`、`.local`、私有网段与裸主机名 —— 否则这个功能就变成了
/// 「让 App 去访问局域网任意地址」的入口。也拒绝带用户名的 URL。
///
/// 单测与 `tools/logic_tests.py` 的镜像 24 两边钉住。
enum SharedLinkURL {

    static let maximumLength = 2048
    static let maximumTitleLength = 200

    /// 去掉首尾空白、补/小写化 scheme 与 host、剥掉 fragment；不合法返回 nil。
    static func normalized(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength else { return nil }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty,
              isPublicHost(host)
        else { return nil }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // 带用户名/密码的链接：既没有合理用途，也不该让它进收藏
        guard components.user == nil, components.password == nil else { return nil }
        components.scheme = scheme
        components.host = host.lowercased()
        components.fragment = nil
        return components.url
    }

    /// 从「一段文字」里找第一个 http(s) 链接。
    ///
    /// 微信「复制链接」通常只复制 URL，但有些来源会把标题和链接一起复制，
    /// 所以剪贴板导入要能从一段话里把链接捞出来。
    static func firstURL(in text: String) -> String? {
        guard let match = RegexUtil.firstMatch(
            #"https?://[^\s<>"'）】」』？！，。；、]+"#,
            in: text,
            options: [.caseInsensitive]
        ), let raw = RegexUtil.group(match, at: 0, in: text) else { return nil }

        var token = raw
        let trailing = CharacterSet(charactersIn: ".,;:!?)]}>\"'")
        while let last = token.last, trailing.contains(last.unicodeScalars.first!) {
            token.removeLast()
        }
        return normalized(token)?.absoluteString
    }

    static func isWeChatHost(_ host: String) -> Bool {
        let value = host.lowercased()
        return value == "mp.weixin.qq.com"
            || value == "weixin.qq.com"
            || value.hasSuffix(".weixin.qq.com")
    }

    /// 公开主机：拒绝 localhost / `.local` / 私有与保留 IPv4 / 链路本地 IPv6 / 裸主机名。
    static func isPublicHost(_ host: String) -> Bool {
        let value = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !value.isEmpty else { return false }
        if value == "localhost" || value.hasSuffix(".local") || value.hasSuffix(".localhost") {
            return false
        }
        if let octets = ipv4(value) {
            return !isPrivateIPv4(octets)
        }
        if value.contains(":") {
            return isPublicIPv6(value)
        }
        // 裸主机名（如 intranet）不允许：它可能被搜索域解析到局域网
        return value.contains(".")
    }

    /// 标题清洗：解码实体交给调用方之前不做；这里只折叠空白、限长。
    static func cleanedTitle(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        let collapsed = RegexUtil.replace(#"\s+"#, in: raw, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maximumTitleLength))
    }

    /// 没有标题时的兜底：公众号给「微信公众号文章」，其它给域名。
    static func defaultTitle(for urlString: String) -> String {
        guard let host = URL(string: urlString)?.host?.lowercased(), !host.isEmpty else {
            return "链接"
        }
        return isWeChatHost(host) ? "微信公众号文章" : host
    }

    // MARK: - IP 判断

    private static func ipv4(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var values: [Int] = []
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isNumber }),
                  let value = Int(part),
                  (0...255).contains(value)
            else { return nil }
            values.append(value)
        }
        return values
    }

    private static func isPrivateIPv4(_ octets: [Int]) -> Bool {
        switch octets[0] {
        case 0, 10, 127:
            return true
        case 169:
            return octets[1] == 254
        case 172:
            return (16...31).contains(octets[1])
        case 192:
            return octets[1] == 168 || (octets[1] == 0 && octets[2] == 0)
        case 100:
            // 100.64.0.0/10 —— 运营商级 NAT
            return (64...127).contains(octets[1])
        case 198:
            // 198.18.0.0/15 —— 基准测试保留段
            return octets[1] == 18 || octets[1] == 19
        default:
            return octets[0] >= 224
        }
    }

    private static func isPublicIPv6(_ host: String) -> Bool {
        let value = host.lowercased()
        if value == "::" || value == "::1" { return false }
        // fe80::/10 链路本地、fc00::/7 唯一本地地址
        if value.hasPrefix("fe8") || value.hasPrefix("fe9")
            || value.hasPrefix("fea") || value.hasPrefix("feb") {
            return false
        }
        if value.hasPrefix("fc") || value.hasPrefix("fd") { return false }
        return true
    }
}
