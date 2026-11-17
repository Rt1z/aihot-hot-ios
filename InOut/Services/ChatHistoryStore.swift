import Foundation

/// 对话历史（用户数据，不是缓存）—— 按新闻（`HotTopic.id`）分会话落盘。
///
/// 存 **Application Support** 而不是 Caches：Caches 系统随时会清，
/// `SnapshotCache` / `StoryCache` 放那里是因为它们都能重新拉回来；
/// 对话是用户一句句问出来的，清掉就是丢数据（同 `FavoritesStore` 的理由）。
/// 也不进 UserDefaults：会话会涨到 MB 级，UserDefaults 不是干这个的。
///
/// **封顶 50 条会话，超出淘汰最旧**（设置页写明了这条 —— 有披露的淘汰
/// 不等于规则 6 禁止的静默丢弃）。淘汰的权威是**数组顺序**，不按 `updatedAt`
/// 排序：Swift 的 sort 不稳定，同一秒保存的两条会每次漂移（同规则 8）——
/// upsert 时删旧追加到末尾，所以头部永远是最久没动过的。
///
/// 与 `FavoritesStore` 的一处刻意差别：整文件解码失败时**直接当没有**，
/// 不做逐条抢救。收藏里包着外部接口的 `HotTopic` 快照，字段随时可能变；
/// 会话里全是这里自己定义的形状，整文件坏掉只可能是文件本身写坏了，
/// 那时候逐条也救不出什么，猜一个残缺对话出来反而更糟。
@MainActor
final class ChatHistoryStore {

    static let shared = ChatHistoryStore()

    /// 封顶。设置页 footer 写明了这个数 —— 改这里记得同步那句话（规则 6）。
    static let maximumSessions = 50

    private static let fileName = "chat-sessions.json"

    /// 落盘的一条消息。**没有 `isStreaming`**：那是一次性界面状态，
    /// 恢复出来的消息一律是已完成的。
    struct StoredMessage: Codable {
        let id: UUID
        let role: String
        let text: String
    }

    struct Session: Codable {
        let key: String
        var updatedAt: Date
        var messages: [StoredMessage]
    }

    private let fileURL: URL
    private let encode: ([Session]) throws -> Data

    /// `fileURL` / `encode` 都可注入：单测写临时目录、以及「编码失败保留旧文件」
    /// 都靠这两条缝（encode 失败时想复现，得能塞一个必抛的实现进去）。
    init(
        fileURL: URL? = nil,
        encode: @escaping ([Session]) throws -> Data = { try JSONEncoder.aihot.encode($0) }
    ) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.encode = encode
    }

    // MARK: - 读

    /// 恢复一条会话。盘上没有（或整文件坏了）返回 nil —— 调用方从空对话开始即可。
    ///
    /// 角色用 `AIChatTurn.Role(rawValue:)` 严格解码，认不出的**那一条**丢掉，
    /// 其余照常（不让一个坏字符串清空整场对话）。
    func load(key: String) -> [AIChatMessage]? {
        guard let session = loadSessions().first(where: { $0.key == key }) else { return nil }
        return session.messages.compactMap { stored in
            guard let role = AIChatTurn.Role(rawValue: stored.role) else { return nil }
            return AIChatMessage(id: stored.id, role: role, text: stored.text)
        }
    }

    // MARK: - 写

    /// 保存（或更新）一条会话。`messages` 为空时等于删除 —— 不留空壳。
    ///
    /// upsert 的形状是**删旧 + 追加到末尾**：数组顺序就是「谁最久没动」的权威
    /// （见类头注释），所以刚保存的会话总是排在最后、最后被淘汰。
    func save(messages: [AIChatMessage], key: String, at date: Date = Date()) {
        guard !messages.isEmpty else {
            delete(key: key)
            return
        }

        var sessions = loadSessions()
        sessions.removeAll { $0.key == key }
        sessions.append(
            Session(
                key: key,
                updatedAt: date,
                messages: messages.map { StoredMessage(id: $0.id, role: $0.role.rawValue, text: $0.text) }
            )
        )
        sessions = Self.trim(sessions)

        // 编码失败就什么都不写：宁可留着旧文件，也不能把它换成空的（同收藏的规矩）
        guard let data = try? encode(sessions) else { return }
        ensureDirectory()
        try? data.write(to: fileURL, options: .atomic)
    }

    func delete(key: String) {
        var sessions = loadSessions()
        let before = sessions.count
        sessions.removeAll { $0.key == key }
        // 文件本来就不存在（或没有这条）时别动盘：否则「垃圾桶」会凭空造出一个文件
        guard sessions.count != before else { return }
        guard let data = try? encode(sessions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 「设置 → 对话记录 → 清除」专用。**只删这一个文件** ——
    /// 不碰 Caches、不碰收藏、不碰同目录里的任何其它东西。
    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - 纯函数

    /// 保留最近的 `maximumSessions` 条，超出的从数组头部（最久没动的）淘汰。
    ///
    /// **绝不按 `updatedAt` 排序再截**：排序会把「并列时间」的顺序打乱，
    /// 而数组顺序才是权威（同 `FavoritesStore.load` 的理由）。
    static func trim(_ sessions: [Session]) -> [Session] {
        guard sessions.count > maximumSessions else { return sessions }
        return Array(sessions.suffix(maximumSessions))
    }

    // MARK: - 内部

    private static func defaultFileURL() -> URL {
        // Application Support 不在 Caches 里，系统清理碰不到它（取不到是理论情况）
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return directory.appendingPathComponent(fileName)
    }

    private func loadSessions() -> [Session] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL)
        else { return [] }
        return (try? JSONDecoder.aihot.decode([Session].self, from: data)) ?? []
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}
