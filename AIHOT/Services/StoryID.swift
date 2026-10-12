import Foundation

/// 把 `links.story` 这个「给人看的 HTML 地址」的末段取出来当 publicId。
///
/// 官方文档要求：`links.story` 是 HTML 页面地址，只能取末段 id，
/// 再拿这个 id 去请求 `/api/v1/stories/{publicId}`；**绝不能**直接把
/// `links.story` 当接口请求。注意返回的域名可能仍是旧域名
/// `aihot.virxact.com`（2026-10-31 前只做跳转），所以只解析路径、不看域名。
enum StoryID {

    /// 至少这么长才认为是合法 id（现在的 id 是 36 位 UUID）。
    private static let minimumLength = 8

    static func publicId(fromStoryLink link: String?) -> String? {
        guard let link = link, !link.isEmpty else { return nil }
        guard let url = URL(string: link) else { return nil }

        // query / fragment 由 URL 自动剥离
        let segments = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard let last = segments.last else { return nil }

        let candidate = last.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.count >= minimumLength else { return nil }
        guard candidate.lowercased() != "story" else { return nil }

        // 只允许 id 里常见的字符，避免把奇怪的路径段当 id 发请求
        let allowed = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_.")
        guard candidate.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }

        return candidate
    }
}
