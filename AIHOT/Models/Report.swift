import Foundation

/// 周报 / 月报两种期次（对应 `/api/v1/weeklies` 与 `/api/v1/monthlies`）。
///
/// 与模型榜相反，这两个栏目**有公开 JSON 接口**（带 ETag、`s-maxage=300`），
/// 走 `AIHOTAPI.getJSON`，见 `ReportStore` 与 CLAUDE.md 规则 19。
enum ReportKind: String, CaseIterable, Identifiable, Codable {
    case weekly
    case monthly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weekly: return "周报"
        case .monthly: return "月报"
        }
    }

    /// 接口根路径（latest / 索引 / 单期都挂在它下面）。
    var path: String {
        switch self {
        case .weekly: return "/api/v1/weeklies"
        case .monthly: return "/api/v1/monthlies"
        }
    }

    /// 官网对应的栏目页（「网页版」的兜底回链）。
    var webPath: String {
        switch self {
        case .weekly: return "/weekly"
        case .monthly: return "/monthly"
        }
    }
}

/// `GET /…/latest` 与 `GET /…/{week|month}` 的信封：`{schemaVersion, report}`。
struct ReportResponse: Decodable {
    let schemaVersion: Int?
    let report: PeriodReport
}

/// `GET /api/v1/weeklies`、`/api/v1/monthlies` 的信封：`{schemaVersion, count, items}`。
/// 索引是**全量**的（实测 12 期周报、5 期月报，无分页）。
struct ReportIndexResponse: Decodable {
    let schemaVersion: Int?
    let count: Int?
    let items: [ReportEntry]
}

/// 完整一期。周报与月报字段同构，只差 `week` / `month` 一个键。
///
/// 除 `Item.title` 外全部可选：老期次（实测 2026-W30、2026-09）的 `overview`、
/// `sections[].summary` 真的是 `null`，一条坏记录也不该让整期解不出来。
/// `periodStart`/`periodEnd` 是 `yyyy-MM-dd` 的**展示原文**，不转 Date ——
/// 「几月几日」的换算交给纯函数 `ReportPeriod`（镜像 18）。
struct PeriodReport: Codable, Equatable, Hashable {

    /// 期的回链（`links.aihot` → `/weekly/2026-W42`）。
    struct ReportLink: Codable, Equatable, Hashable {
        let aihot: String?
    }

    /// 条目链接：`original` 是原文（点开走阅读器），`aihot` 是站内条目页。
    struct ReportItemLinks: Codable, Equatable, Hashable {
        let aihot: String?
        let original: String?
    }

    struct ReportAttribution: Codable, Equatable, Hashable {
        let name: String?
        let url: String?
    }

    /// 一条条目。`title` 必填（schema 里就是 required），其余从宽。
    struct Item: Codable, Equatable, Hashable {
        struct Source: Codable, Equatable, Hashable {
            let name: String?
        }

        let title: String
        let summary: String?
        let source: Source?
        let links: ReportItemLinks?
        /// 带毫秒的 ISO8601 → `JSONDecoder.aihot`（内置 .iso8601 解不开）。
        let publishedAt: Date?
    }

    /// 一个分栏。`label` 原样渲染：新期次是分类名（模型发布/更新），
    /// 老期次是主题句（开源模型性能逼近前沿…）—— 不归一化。
    struct Section: Codable, Equatable, Hashable {
        let label: String
        let summary: String?
        let items: [Item]
    }

    let week: String?        // "2026-W42"
    let month: String?       // "2026-09"
    let periodStart: String?
    let periodEnd: String?
    let generatedAt: Date?
    let links: ReportLink?
    let attribution: ReportAttribution?
    let headline: String?
    let overview: String?
    let sections: [Section]

    /// 期号主键："2026-W42" 或 "2026-09"；两个都没有则 nil（宁可无键，不可错键）。
    var periodKey: String? { week ?? month }
}

/// 索引里的一期（没有 sections，只有期号/标题/时间），供「往期」列表与跳转。
///
/// `id` 用期号做稳定键 —— `NavigationLink(value:)` 与 `navigationDestination`
/// 都要求 Hashable，合成实现靠存储属性就够。
struct ReportEntry: Codable, Equatable, Hashable, Identifiable {
    let week: String?
    let month: String?
    let periodStart: String?
    let periodEnd: String?
    let generatedAt: Date?
    let headline: String?
    let links: PeriodReport.ReportLink?
    let attribution: PeriodReport.ReportAttribution?

    var id: String { week ?? month ?? "" }
    var periodKey: String? { week ?? month }
}
