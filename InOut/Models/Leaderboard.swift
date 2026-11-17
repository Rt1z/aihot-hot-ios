import Foundation

/// 模型榜的五个分类（对应站点五个页面）。
///
/// 榜单没有公开 JSON 接口（开源版 4.0 起明确移除），数据从各页 SSR HTML 里解析，
/// 解析器见 `LeaderboardParser`（纯函数，镜像 17 钉住）。
enum LeaderboardCategory: String, CaseIterable, Identifiable, Codable {
    case overall
    case coding
    case reasoning
    case professional
    case knowledge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overall: return "综合"
        case .coding: return "编程"
        case .reasoning: return "科研"
        case .professional: return "专业办公"
        case .knowledge: return "知识问答"
        }
    }

    /// 页面路径：综合榜在根路径，分类榜带 `/category/<rawValue>`。
    var path: String {
        self == .overall ? "/leaderboard" : "/leaderboard/category/\(rawValue)"
    }

    /// 详情页 CAPABILITY PROFILE / BEHIND THE SCORE 里的分组名（真人盲选不在分类榜里）。
    static func from(heading: String) -> LeaderboardCategory? {
        switch heading {
        case "编程": return .coding
        case "科研": return .reasoning
        case "专业办公": return .professional
        case "知识问答": return .knowledge
        case "真人盲选": return nil
        default: return nil
        }
    }
}

/// 榜页（综合/分类同构）的一行。
///
/// 价格保留**展示原文**（"¥1.34"；「待核验」→ nil），不转数字 —— 不编造、不丢精度。
/// Hashable 是 `NavigationLink(value:)` 的硬要求（只有 Equatable 不够）。
struct LeaderboardModel: Identifiable, Equatable, Codable, Hashable {
    let rank: Int
    /// 行的 `data-slug` 属性，详情页 URL 的尾段。
    let slug: String
    let name: String
    let provider: String?
    /// 行内 ISO 上线日期原文（"2026-09-22"），展示用。
    let releasedISO: String?
    let evalCount: Int?
    let coveragePercent: Int?
    let cachePrice: String?
    let inputPrice: String?
    let outputPrice: String?
    let score: Double?

    var id: String { slug }

    var detailURL: URL? {
        URL(string: "https://aihot.news/leaderboard/\(slug)")
    }
}

/// 一个分类榜整页解析结果。
struct LeaderboardBoard: Equatable, Codable {
    let category: LeaderboardCategory
    /// 页头 "10/20 09:12"（不含「更新」二字）。
    let updatedText: String?
    /// 页头 "35 项评测 · 7 家机构"。
    let evalTotal: Int?
    let institutionCount: Int?
    let models: [LeaderboardModel]
}

/// 模型详情页解析结果。
///
/// 「展开运行配置」是懒加载的，SSR 里没有；「测过但不计入」区块同样不解析
/// —— 宁可少抽，不可抽错。
struct LeaderboardDetail: Equatable {

    /// CAPABILITY PROFILE 的四张领域卡。
    struct CategoryCard: Equatable {
        let category: LeaderboardCategory
        let score: Double?
        let rank: Int?
        let evalCount: Int?
        let coveragePercent: Int?
    }

    /// BEHIND THE SCORE 的一项公开成绩。
    struct Benchmark: Equatable {
        let name: String
        /// 机构名，可能带「旧型号作答 12%」这类后缀，保留原文。
        let source: String?
        /// 原始成绩原文（"18.5%" / "1,508.2" / "不到 1%"）。
        let scoreText: String?
        /// 折算分原文（可能是 "108.1" 或 "至多 55.1"）。
        let converted: String?
    }

    /// BEHIND THE SCORE 按领域的一组（真人盲选也会出现，此时 category 为 nil）。
    struct BenchmarkGroup: Equatable {
        let heading: String
        let category: LeaderboardCategory?
        let score: Double?
        let evalCount: Int?
        let items: [Benchmark]
    }

    let name: String
    let provider: String?
    /// "2026-09-22 发布" 原文。
    let releasedText: String?
    let updatedText: String?
    let overallScore: Double?
    let overallRank: Int?
    let coveragePercent: Int?
    /// "100万 Token" 原文。
    let contextWindowText: String?
    let inputPrice: String?
    let outputPrice: String?
    let cachePrice: String?
    /// "原价 $4 / $20" 原文。
    let originalUSDText: String?
    let cards: [CategoryCard]
    let groups: [BenchmarkGroup]
}
