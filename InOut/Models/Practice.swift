import Foundation

/// 练习用的写作形式。
///
/// 两种模式各自保留一份内容：切换模式时只在**目标模式还是空的**的情况下搬运，
/// 否则两边的文字都会留着（详见 `PracticeText.transferring`）。
enum PracticeMode: String, Codable, CaseIterable, Identifiable {
    case free
    case structured

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: return "自由写"
        case .structured: return "三段式"
        }
    }
}

/// 练习时保存的文章快照。
///
/// **为什么存快照而不是只存 id**：热点榜每天刷新、周报会换期，只留 id 的话
/// 历史记录迟早会变成一排点不开的空壳。标题、来源、导读都在练习那一刻定住。
/// 全文不落盘（可能上万字符），AI 点评时现取；取不到就按「导读」为基准。
struct PracticeArticle: Codable, Hashable {

    enum Kind: String, Codable {
        /// 热点榜的一条（有导读，没有全文）。
        case hot
        /// 周报/月报的一个条目（有完整正文）。
        case reportItem
        /// 从外部导入的网页（正文由内嵌阅读器抓取）。
        case savedLink
    }

    let kind: Kind
    let articleID: String
    let title: String
    let sourceName: String?
    let originalURL: String?
    let aihotURL: String?
    let digest: String?

    /// 草稿按「来源 + 文章 id」区分：热点与周报的 id 是两个空间。
    var draftKey: String { "\(kind.rawValue)|\(articleID)" }
}

/// 一次 AI 点评的快照。
///
/// 存下来而不是每次重算：点评是要花钱的，历史回看时也不该再打一次网络；
/// 同时「当时模型怎么说的」本身值得保留。
struct PracticeReviewSnapshot: Codable, Hashable {
    let text: String
    let createdAt: Date
    let model: String
    /// 「全文」或「导读」—— 点评是基于什么材料做的，必须能说清。
    let basis: String
}

/// 一条练习记录（用户数据）。
struct PracticeEntry: Codable, Hashable, Identifiable {

    let id: UUID
    let article: PracticeArticle
    let createdAt: Date
    var mode: PracticeMode

    /// 三段式
    var mainIdea: String?
    var points: [String]
    var takeaway: String?

    /// 自由写
    var freeText: String?

    /// 对照页的自评：「我漏了什么 / 现在想补充什么」。
    var selfNote: String?

    var review: PracticeReviewSnapshot?

    /// 练习时喂给 AI 的原文（导入文章才有；热点是导读、周报条目是正文）。
    /// 存下来是为了回看时能「再练一次」同一篇文章，也让点评有据可查。
    var bodyText: String?

    init(
        id: UUID = UUID(),
        article: PracticeArticle,
        createdAt: Date = Date(),
        mode: PracticeMode,
        mainIdea: String? = nil,
        points: [String] = [],
        takeaway: String? = nil,
        freeText: String? = nil,
        selfNote: String? = nil,
        review: PracticeReviewSnapshot? = nil,
        bodyText: String? = nil
    ) {
        self.id = id
        self.article = article
        self.createdAt = createdAt
        self.mode = mode
        self.mainIdea = mainIdea
        self.points = points
        self.takeaway = takeaway
        self.freeText = freeText
        self.selfNote = selfNote
        self.review = review
        self.bodyText = bodyText
    }

    /// 回看/列表里显示的那份文字。
    var displayText: String { PracticeText.displayText(for: self) }

    /// 非空白字符数（中文按字算）。
    var wordCount: Int { PracticeText.wordCount(displayText) }
}

/// 未保存的草稿。**按文章分开存**：写到一半退出去，回来还在。
///
/// 与练习记录分开落盘：草稿不是「练过一篇」的证据，不该出现在练习本列表里。
struct PracticeDraft: Codable, Identifiable {
    let article: PracticeArticle
    var mode: PracticeMode
    var mainIdea: String
    var points: [String]
    var takeaway: String
    var freeText: String
    var updatedAt: Date

    var id: String { article.draftKey }
}
