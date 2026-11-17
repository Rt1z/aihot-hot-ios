import Foundation

/// 练习记录与草稿（**用户数据，不是缓存**）。
///
/// 存 Application Support，与 `ChatHistoryStore` 同一个理由：Caches 系统随时会清，
/// 练习是用户一篇篇写出来的，清掉就是丢数据；也不进 UserDefaults（记录会越攒越多）。
/// 因此「设置 → 清除本地缓存」**绝不碰它**。
///
/// **不设上限**：每条约 1 KB，用户亲手写的东西不该被自动淘汰（与收藏同一条纪律，
/// 和对话记录 50 条封顶的取舍不同 —— 那里封顶是因为会话能涨到 MB 级且写在设置页）。
///
/// 顺序的权威是**数组本身**：新记录插到头部，加载时原样读回，绝不按 `createdAt`
/// 排序（Swift 的 sort 不稳定，同一秒保存的两条每次启动都会漂移，同规则 8）。
@MainActor
final class PracticeStore: ObservableObject {

    @Published private(set) var entries: [PracticeEntry] = []
    @Published private(set) var drafts: [PracticeDraft] = []

    private let entriesURL: URL
    private let draftsURL: URL

    /// 编码器可注入：单测要复现「编码失败时保留旧文件」，得能塞一个必抛的实现。
    private let encodeEntries: ([PracticeEntry]) throws -> Data
    private let encodeDrafts: ([PracticeDraft]) throws -> Data

    init(
        entriesURL: URL? = nil,
        draftsURL: URL? = nil,
        encodeEntries: @escaping ([PracticeEntry]) throws -> Data = { try JSONEncoder.aihot.encode($0) },
        encodeDrafts: @escaping ([PracticeDraft]) throws -> Data = { try JSONEncoder.aihot.encode($0) }
    ) {
        let directory = Self.defaultDirectory()
        self.entriesURL = entriesURL ?? directory.appendingPathComponent("practice-entries.json")
        self.draftsURL = draftsURL ?? directory.appendingPathComponent("practice-drafts.json")
        self.encodeEntries = encodeEntries
        self.encodeDrafts = encodeDrafts
        self.entries = Self.load([PracticeEntry].self, from: self.entriesURL) ?? []
        self.drafts = Self.load([PracticeDraft].self, from: self.draftsURL) ?? []
    }

    // MARK: - 记录

    /// 新建或更新一条。新记录插到头部（最近练的在最前），更新则原位替换、
    /// 不改变它在列表里的位置 —— 顺序由插入位置决定，不由时间重排。
    func save(_ entry: PracticeEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.insert(entry, at: 0)
        }
        persistEntries()
    }

    func attachReview(_ review: PracticeReviewSnapshot, to id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].review = review
        persistEntries()
    }

    func delete(id: UUID) {
        let before = entries.count
        entries.removeAll { $0.id == id }
        guard entries.count != before else { return }
        persistEntries()
    }

    func stats(now: Date = Date()) -> PracticeStats {
        PracticeStatsCalculator.make(entries: entries, now: now)
    }

    // MARK: - 草稿

    func draft(for article: PracticeArticle) -> PracticeDraft? {
        drafts.first { $0.article.draftKey == article.draftKey }
    }

    func saveDraft(_ draft: PracticeDraft) {
        if let index = drafts.firstIndex(where: { $0.article.draftKey == draft.article.draftKey }) {
            drafts[index] = draft
        } else {
            drafts.insert(draft, at: 0)
        }
        persistDrafts()
    }

    /// 保存成正式记录、或用户主动放弃时调用。
    func deleteDraft(for article: PracticeArticle) {
        let before = drafts.count
        drafts.removeAll { $0.article.draftKey == article.draftKey }
        guard drafts.count != before else { return }
        persistDrafts()
    }

    // MARK: - 落盘

    /// 编码失败就什么都不写：宁可留着旧文件，也不能把它换成空的（同收藏的规矩）。
    private func persistEntries() {
        guard let data = try? encodeEntries(entries) else { return }
        Self.write(data, to: entriesURL)
    }

    private func persistDrafts() {
        guard let data = try? encodeDrafts(drafts) else { return }
        Self.write(data, to: draftsURL)
    }

    private static func write(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    /// 整文件解不出来就当没有（同 `ChatHistoryStore` 的取舍）：这里存的是我们自己
    /// 定义的字形，坏掉只可能是文件本身写坏了，逐条抢救救不出什么。
    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder.aihot.decode(type, from: data)
    }

    private static func defaultDirectory() -> URL {
        // Application Support 不在 Caches 里，系统清理碰不到它（取不到是理论情况）
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }
}
