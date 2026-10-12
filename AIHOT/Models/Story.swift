import Foundation

// MARK: - 故事详情模型（/api/v1/stories/{publicId}）

struct StoryResponse: Codable {
    let schemaVersion: Int?
    let story: Story
}

struct Story: Codable, Hashable {
    let publicId: String
    let title: String
    let status: String?
    let sourceCount: Int?
    let reportCount: Int?
    let firstReportAt: Date?
    let latestAt: Date?
    let latest: String?
    let digest: String?
    let digestUpdatedAt: Date?
    let links: Links?
    let reports: [Report]?

    /// 摘要按空行拆段，跳过空段。
    var digestParagraphs: [String] {
        guard let digest = digest, !digest.isEmpty else { return [] }
        return digest
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 报道按时间倒序（接口本身就是这个顺序，这里做一次保险）。
    var sortedReports: [Report] {
        (reports ?? []).sorted { lhs, rhs in
            (lhs.publishedAt ?? .distantPast) > (rhs.publishedAt ?? .distantPast)
        }
    }
}

struct Report: Codable, Hashable, Identifiable {
    let id: String
    let title: String?
    let summary: String?
    let source: Source?
    let publishedAt: Date?
    let links: Links?
}
