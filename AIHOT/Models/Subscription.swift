import Foundation

/// 订阅内容的五个板块。**顺序就是展示顺序，也是平分时的优先级** ——
/// 分类器与镜像都按 `allCases` 走，不遍历字典（字典顺序不稳定）。
enum SubscriptionTopic: String, CaseIterable, Identifiable, Codable, Hashable {
    case tech
    case health
    case growth
    case career
    case peripheral

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tech: return "科技"
        case .health: return "健康"
        case .growth: return "成长"
        case .career: return "职业"
        case .peripheral: return "周边"
        }
    }
}

/// 两类信源。公众号走 Dajiala 云端接口，B 站走本机 RSSHub。
enum SubscriptionSourceKind: String, Codable, CaseIterable, Hashable {
    case wechat
    case bilibili

    var title: String {
        switch self {
        case .wechat: return "公众号"
        case .bilibili: return "B 站"
        }
    }

    /// 列表行上的来源徽章（短一点，避免挤掉标题）。
    var badge: String {
        switch self {
        case .wechat: return "微信"
        case .bilibili: return "B站"
        }
    }

    var systemImage: String {
        switch self {
        case .wechat: return "message"
        case .bilibili: return "play.rectangle"
        }
    }
}

/// 配置文件里的一条信源。
///
/// `id` 只由 `biz` / `url` / `route` 决定，**与 `name` 无关**：
/// 6 小时计费窗口按 id 记，改个显示名不能把窗口重置成「从没抓过」。
struct SubscriptionSource: Identifiable, Equatable {
    enum Request: Equatable {
        /// 公众号：`biz` 优先；没有就交给 Dajiala 用文章链接反查。
        case wechat(url: String?, biz: String?)
        /// B 站：RSSHub 路由，必须以 `/bilibili/` 开头（见配置解析的校验）。
        case bilibili(route: String)
    }

    let id: String
    let kind: SubscriptionSourceKind
    /// 可为空：取数后用接口返回的公众号名 / feed 标题回填。
    let name: String
    let request: Request
    let isEnabled: Bool

    /// 只有公众号会按次计费；B 站走自己的 RSSHub，免费。
    var isPaid: Bool { kind == .wechat }
}

/// 一份配置（从电脑上的 JSON 解析出来）。
struct SubscriptionConfig: Equatable {
    var wechat: [SubscriptionSource]
    var bilibili: [SubscriptionSource]

    var allSources: [SubscriptionSource] { wechat + bilibili }
    var enabledSources: [SubscriptionSource] { allSources.filter(\.isEnabled) }

    var isEmpty: Bool { allSources.isEmpty }
}

/// 一条订阅内容。
///
/// 板块**不落盘**：`topic` 在渲染时由 `SubscriptionClassifier` 现算，
/// 词库更新后缓存里的旧条目立刻按新词库归类。
struct SubscriptionItem: Identifiable, Codable, Hashable {
    let id: String
    let sourceID: String
    let sourceName: String
    let kind: SubscriptionSourceKind
    let title: String
    let summary: String
    /// 打开原文的地址；解析层已经拒绝空链接，这里保留 String 是为了 Codable 简单。
    let link: String
    let coverURL: String?
    let publishedAt: Date?

    var topic: SubscriptionTopic {
        SubscriptionClassifier.classify(title: title, summary: summary)
    }
}
