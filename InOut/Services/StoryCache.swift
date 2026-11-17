import Foundation

/// 故事正文的磁盘缓存（key 是 publicId）。
///
/// 为什么必须存在：`/api/v1/stories/{publicId}` 会返回 304，而 ETag 存在
/// UserDefaults 里是**跨启动保留**的。如果正文只放在内存里，就会出现
/// 「本地没有任何内容可展示，却一直收到 304」：
/// - 同一条故事第二次打开 → 详情页只剩摘要，报道时间线凭空消失；
/// - 重启 App 后 → 榜单大卡的正文段落全没了（10 条 story 全 304 被丢掉）。
/// 所以 304 时必须能拿回正文，这里就是那个「正文的落盘处」。
///
/// 只在主线程（@MainActor 的 Store / ViewModel）里调用，因此内存副本无需加锁。
enum StoryCache {

    private static let fileName = "stories.json"
    private static let maximumEntries = 300

    private struct Entry: Codable {
        let story: Story
        let storedAt: Date
    }

    private static var memory: [String: Entry]?

    private static var fileURL: URL? {
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return directory.appendingPathComponent(fileName)
    }

    private static func readFromDisk() -> [String: Entry] {
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder.aihot.decode([String: Entry].self, from: data)) ?? [:]
    }

    private static func entries() -> [String: Entry] {
        if let memory = memory { return memory }
        let loaded = readFromDisk()
        memory = loaded
        return loaded
    }

    private static func persist(_ entries: [String: Entry]) {
        var trimmed = entries
        if trimmed.count > maximumEntries {
            // 超出上限时按写入时间保留最近的一批
            let recent = trimmed
                .sorted { $0.value.storedAt > $1.value.storedAt }
                .prefix(maximumEntries)
            trimmed = Dictionary(uniqueKeysWithValues: recent.map { ($0.key, $0.value) })
        }

        // 内存必须和磁盘用同一份（裁剪后的）数据，否则内存会无限增长
        memory = trimmed

        guard let url = fileURL else { return }
        guard let data = try? JSONEncoder.aihot.encode(trimmed) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func story(for publicId: String) -> Story? {
        entries()[publicId]?.story
    }

    /// 批量写入：一次编码、一次落盘。榜单刷新时会一次拿到 10 条，
    /// 逐条 `store` 会把整个缓存重复写 10 遍。
    static func store(_ stories: [Story]) {
        guard !stories.isEmpty else { return }
        var current = entries()
        let now = Date()
        for story in stories {
            current[story.publicId] = Entry(story: story, storedAt: now)
        }
        persist(current)
    }

    static func store(_ story: Story) {
        store([story])
    }

    static func clear() {
        memory = [:]
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
