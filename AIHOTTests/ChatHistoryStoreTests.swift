import XCTest

@testable import AIHOT

/// `ChatHistoryStore` 是 @MainActor 的，用例逐个方法标 @MainActor（不标类上，
/// 免得 setUp/tearDown 变成隔离重写 —— 同 FavoritesStoreTests 的理由）。
///
/// 每个用例一份独立临时目录，`defer` 清理。这里写的是**离线磁盘 IO**，
/// 不碰网络，不碰 App 真实的 Application Support。
final class ChatHistoryStoreTests: XCTestCase {

    private func freshDirectory() throws -> (directory: URL, fileURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aihot.tests.chat.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("chat-sessions.json"))
    }

    private func message(_ role: AIChatTurn.Role, _ text: String) -> AIChatMessage {
        AIChatMessage(role: role, text: text)
    }

    /// 直接把盘上的 JSON 解出来：数量与顺序这类断言，写进文件里的形状才是权威。
    private func diskSessions(_ fileURL: URL) throws -> [ChatHistoryStore.Session] {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder.aihot.decode([ChatHistoryStore.Session].self, from: data)
    }

    // MARK: - 读写往返

    /// 跨实例往返，逐字段核对 —— 尤其是 `id`：恢复出来的消息要和原来那条
    /// 是同一个 id（气泡的 identity、以及会话内的对应关系都指着它）。
    @MainActor
    func testRoundTripAcrossInstances() throws {
        let (directory, fileURL) = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let seeded = [
            message(.user, "为什么火？"),
            message(.assistant, "因为被多人转引。"),
        ]
        ChatHistoryStore(fileURL: fileURL).save(messages: seeded, key: "story-a")

        let restored = try XCTUnwrap(ChatHistoryStore(fileURL: fileURL).load(key: "story-a"))
        XCTAssertEqual(restored, seeded, "id / role / text 全部原样回来")
        XCTAssertNil(ChatHistoryStore(fileURL: fileURL).load(key: "story-b"), "别的 key 是「没有」")
    }

    /// `JSONEncoder.aihot` 写的是不带小数秒的 ISO8601（与收藏同一个编码器），
    /// 所以 `updatedAt` 落盘后截到整秒 —— 预期行为，别"修"编码器（规则见
    /// FavoritesStoreTests 里同款测试的注释：那个编码器和榜单快照是共用的）。
    @MainActor
    func testUpdatedAtIsTruncatedToWholeSeconds() throws {
        let (directory, fileURL) = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let precise = Date(timeIntervalSince1970: 1_760_000_000.75)
        ChatHistoryStore(fileURL: fileURL).save(
            messages: [message(.user, "hi")], key: "a", at: precise
        )

        let stored = try XCTUnwrap(diskSessions(fileURL).first)
        XCTAssertEqual(stored.updatedAt.timeIntervalSince1970, 1_760_000_000, accuracy: 0.001)
        XCTAssertLessThan(abs(stored.updatedAt.timeIntervalSince1970 - precise.timeIntervalSince1970), 1)
    }

    // MARK: - 封顶与顺序

    /// 55 份存进去，剩 50 份：淘汰最旧的 5 个 key，保留的**顺序不变**。
    ///
    /// 方向是承重的：淘汰反了会静默丢掉用户刚问完的对话，而且没人会报错。
    @MainActor
    func testCapEvictsOldestByLastUpdated() throws {
        let (directory, fileURL) = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ChatHistoryStore(fileURL: fileURL)
        for index in 0..<55 {
            store.save(
                messages: [message(.user, "问 \(index)")],
                key: "key-\(index)",
                at: Date(timeIntervalSince1970: 1_760_000_000 + Double(index) * 60)
            )
        }

        let keys = try diskSessions(fileURL).map(\.key)
        XCTAssertEqual(keys.count, ChatHistoryStore.maximumSessions)
        XCTAssertEqual(keys, (5..<55).map { "key-\($0)" }, "淘汰最旧的 5 条，留下的顺序不变")
        XCTAssertNil(store.load(key: "key-0"), "最旧的被淘汰")
        XCTAssertNotNil(store.load(key: "key-54"), "最新的必须留下")
    }

    /// 同一 key 再存一次 = 删旧 + 追加到末尾：只留一份、且排到「最新」那头。
    /// 数组顺序就是「谁最久没动」的权威，不按 updatedAt 排序（同规则 8）。
    @MainActor
    func testUpsertKeepsOneEntryAndBumpsOrder() throws {
        let (directory, fileURL) = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ChatHistoryStore(fileURL: fileURL)
        store.save(messages: [message(.user, "A 的第一问")], key: "a",
                   at: Date(timeIntervalSince1970: 1_760_000_000))
        store.save(messages: [message(.user, "B 的一问")], key: "b",
                   at: Date(timeIntervalSince1970: 1_760_000_060))
        store.save(messages: [message(.user, "A 的第二问")], key: "a",
                   at: Date(timeIntervalSince1970: 1_760_000_120))

        let keys = try diskSessions(fileURL).map(\.key)
        XCTAssertEqual(keys, ["b", "a"], "同 key 再存：只留一份、排到末尾（= 最新）")
        XCTAssertEqual(store.load(key: "a")?.first?.text, "A 的第二问", "内容被更新，不是并存两条")
    }

    // MARK: - 坏数据

    /// 整文件坏了就当没有（与收藏的逐条抢救是**刻意的**差别，见类头注释）：
    /// 不崩、从空对话开始，而且还能照常写入新的（坏文件被覆盖）。
    @MainActor
    func testGarbageFileYieldsEmptyInsteadOfCrashing() throws {
        let (directory, fileURL) = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data([0x00, 0x01, 0x02]).write(to: fileURL)

        let store = ChatHistoryStore(fileURL: fileURL)
        XCTAssertNil(store.load(key: "a"))
        store.save(messages: [message(.user, "新对话")], key: "b")
        XCTAssertEqual(store.load(key: "b")?.first?.text, "新对话")
    }

    /// 编码失败必须保留旧文件 —— 绝不能把它换成空的（同收藏的规矩）。
    /// encode 是注入的缝：默认实现很难抛错，这条用一个必抛的塞进去。
    @MainActor
    func testEncodeFailureKeepsPreviousBlob() throws {
        let (directory, fileURL) = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        ChatHistoryStore(fileURL: fileURL).save(messages: [message(.user, "旧对话")], key: "a")

        struct Boom: Error {}
        let failing = ChatHistoryStore(fileURL: fileURL, encode: { _ in throw Boom() })
        failing.save(messages: [message(.user, "新对话")], key: "b")

        let restored = try XCTUnwrap(ChatHistoryStore(fileURL: fileURL).load(key: "a"))
        XCTAssertEqual(restored.first?.text, "旧对话", "旧文件要原封不动")
        XCTAssertNil(ChatHistoryStore(fileURL: fileURL).load(key: "b"), "新那次没写进去")
    }

    // MARK: - 删除

    @MainActor
    func testDeleteRemovesOnlyThatSession() throws {
        let (directory, fileURL) = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ChatHistoryStore(fileURL: fileURL)
        store.save(messages: [message(.user, "A")], key: "a")
        store.save(messages: [message(.user, "B")], key: "b")

        store.delete(key: "a")
        XCTAssertNil(store.load(key: "a"))
        XCTAssertEqual(store.load(key: "b")?.first?.text, "B")
    }

    /// 「清除对话记录」只删**这一个文件**：同目录里的其它东西（这里留一个
    /// 无关文件当代理 —— 收藏在 UserDefaults、缓存在 Caches，本来就不相交）
    /// 一个都不能碰。clear ≠ clearCache。
    @MainActor
    func testClearRemovesTheFileAndNothingElse() throws {
        let (directory, fileURL) = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sentinel = directory.appendingPathComponent("keep-me.json")
        try Data("keep".utf8).write(to: sentinel)

        let store = ChatHistoryStore(fileURL: fileURL)
        store.save(messages: [message(.user, "hi")], key: "a")
        store.clear()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "对话记录文件被删掉")
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8), "同目录的其它文件不许动")
        XCTAssertNil(store.load(key: "a"))
    }

    // MARK: - 落盘形状

    /// `isStreaming` 是一次性界面状态，**永远不落盘**：
    /// 否则中途杀 App 时那半条流式消息会以「正在流式」的状态复活，
    /// 界面上挂着一个永远转圈的气泡。
    @MainActor
    func testStoredMessagesNeverCarryIsStreaming() throws {
        let (directory, fileURL) = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        ChatHistoryStore(fileURL: fileURL).save(
            messages: [AIChatMessage(role: .assistant, text: "写到一半", isStreaming: true)],
            key: "a"
        )

        let raw = String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
        XCTAssertFalse(raw.contains("isStreaming"), "落盘的 JSON 里不该有这个字段")

        let restored = try XCTUnwrap(ChatHistoryStore(fileURL: fileURL).load(key: "a"))
        XCTAssertEqual(restored.count, 1)
        XCTAssertFalse(restored[0].isStreaming, "哪怕存的时候正在流式，恢复出来也是已完成")
    }
}
