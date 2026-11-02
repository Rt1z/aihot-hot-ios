import XCTest

@testable import AIHOT

/// 排序 / 去重 / 截断 / 刷新门槛 / 稳定 id / 快照。镜像 22 钉住同样的规则。
final class SubscriptionLogicTests: XCTestCase {

    private func item(
        id: String,
        sourceID: String = "s1",
        title: String = "标题",
        date: Date? = nil
    ) -> SubscriptionItem {
        SubscriptionItem(
            id: id,
            sourceID: sourceID,
            sourceName: "来源",
            kind: .bilibili,
            title: title,
            summary: "",
            link: "https://example.com/\(id)",
            coverURL: nil,
            publishedAt: date
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    // MARK: - id

    func testFNV1aMatchesTheMirroredImplementation() {
        XCTAssertEqual(SubscriptionItemID.fnv1a64Hex("hello"), "a430d84680aabd0b")
        XCTAssertEqual(SubscriptionItemID.fnv1a64Hex(""), "cbf29ce484222325")
    }

    func testRawIDIsPreferredAndPrefixed() {
        XCTAssertEqual(
            SubscriptionItemID.make(
                kind: .wechat,
                sourceID: "wechat:x",
                rawID: "hash-1",
                link: "https://mp.weixin.qq.com/s/x",
                title: "t",
                publishedAt: nil
            ),
            "wechat:hash-1"
        )
    }

    func testFallbackIDIsStableAndSourceScoped() {
        let first = SubscriptionItemID.make(
            kind: .bilibili,
            sourceID: "bilibili:a",
            rawID: nil,
            link: "https://b23.tv/1",
            title: "标题",
            publishedAt: date(1000)
        )
        let second = SubscriptionItemID.make(
            kind: .bilibili,
            sourceID: "bilibili:a",
            rawID: nil,
            link: "https://b23.tv/1",
            title: "标题",
            publishedAt: date(1000)
        )
        let otherSource = SubscriptionItemID.make(
            kind: .bilibili,
            sourceID: "bilibili:b",
            rawID: nil,
            link: "https://b23.tv/1",
            title: "标题",
            publishedAt: date(1000)
        )
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, otherSource)
        XCTAssertTrue(first.hasPrefix("bilibili:hash:"))
        XCTAssertEqual(first.count, "bilibili:hash:".count + 16)
    }

    // MARK: - 合并 / 排序 / 去重 / 截断

    func testMergeReplacesOnlyTheGivenSource() {
        let oldA = item(id: "a1", sourceID: "a")
        let oldB = item(id: "b1", sourceID: "b")
        let newA = item(id: "a2", sourceID: "a")
        let merged = SubscriptionLogic.merge(existing: [oldA, oldB], incoming: [newA], sourceID: "a")
        XCTAssertEqual(Set(merged.map(\.id)), ["a2", "b1"])
    }

    func testNormalizeSortsByDateThenTitleThenID() {
        let old = item(id: "old", title: "z", date: date(1))
        let newest = item(id: "newest", title: "y", date: date(3))
        let tieB = item(id: "tie-b", title: "b", date: date(2))
        let tieA = item(id: "tie-a", title: "a", date: date(2))
        let undated = item(id: "undated", title: "a", date: nil)

        let result = SubscriptionLogic.normalize([old, tieB, newest, undated, tieA])
        XCTAssertEqual(result.map(\.id), ["newest", "tie-a", "tie-b", "old", "undated"])
    }

    func testNormalizeDeduplicatesKeepingTheNewest() {
        let newest = item(id: "same", title: "new", date: date(3))
        let older = item(id: "same", title: "old", date: date(1))
        let result = SubscriptionLogic.normalize([older, newest])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.title, "new")
    }

    func testNormalizeCapsAtTheLimit() {
        let items = (0..<10).map { item(id: "i\($0)", date: date(Double($0))) }
        let result = SubscriptionLogic.normalize(items, limit: 3)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.map(\.id), ["i9", "i8", "i7"])
    }

    func testNormalizePrunesUnknownSourcesOnlyWhenGivenAValidSet() {
        let keep = item(id: "keep", sourceID: "a")
        let drop = item(id: "drop", sourceID: "b")
        XCTAssertEqual(
            SubscriptionLogic.normalize([keep, drop], validSourceIDs: ["a"]).map(\.id),
            ["keep"]
        )
        XCTAssertEqual(SubscriptionLogic.normalize([keep, drop]).count, 2)
    }

    // MARK: - 分组

    func testGroupingUsesFixedTopicOrderAndHidesEmptySections() {
        let tech = SubscriptionItem(
            id: "tech", sourceID: "s1", sourceName: "来源", kind: .wechat,
            title: "AI 算法", summary: "", link: "https://x", coverURL: nil, publishedAt: nil
        )
        let tech2 = SubscriptionItem(
            id: "tech2", sourceID: "s1", sourceName: "来源", kind: .wechat,
            title: "AI 芯片", summary: "", link: "https://x", coverURL: nil, publishedAt: nil
        )
        let health = SubscriptionItem(
            id: "health", sourceID: "s1", sourceName: "来源", kind: .wechat,
            title: "睡眠与营养", summary: "", link: "https://x", coverURL: nil, publishedAt: nil
        )
        let sections = SubscriptionGrouping.sections(items: [health, tech, tech2])
        XCTAssertEqual(sections.map(\.topic), [.tech, .health])
        XCTAssertEqual(sections[0].items.count, 2)
        XCTAssertEqual(sections[1].items.count, 1)
        XCTAssertFalse(sections.contains { $0.topic == .peripheral })
    }

    // MARK: - 刷新门槛

    func testWeChatSixHourWindow() {
        let now = date(1_000_000)
        XCTAssertTrue(SubscriptionRefreshPolicy.shouldRefreshWeChat(lastAttemptAt: nil, now: now, manual: false))
        XCTAssertFalse(
            SubscriptionRefreshPolicy.shouldRefreshWeChat(
                lastAttemptAt: now.addingTimeInterval(-6 * 3600 + 1),
                now: now,
                manual: false
            )
        )
        XCTAssertTrue(
            SubscriptionRefreshPolicy.shouldRefreshWeChat(
                lastAttemptAt: now.addingTimeInterval(-6 * 3600),
                now: now,
                manual: false
            )
        )
        XCTAssertTrue(
            SubscriptionRefreshPolicy.shouldRefreshWeChat(
                lastAttemptAt: now.addingTimeInterval(-61),
                now: now,
                manual: true
            ),
            "手动跳过 6 小时门槛"
        )
        XCTAssertFalse(
            SubscriptionRefreshPolicy.shouldRefreshWeChat(
                lastAttemptAt: now.addingTimeInterval(-59),
                now: now,
                manual: true
            ),
            "手动仍有 60 秒防连点地板"
        )
    }

    func testFutureTimestampIsNotDue() {
        let now = date(1000)
        XCTAssertFalse(
            SubscriptionRefreshPolicy.shouldRefreshBilibili(
                lastAttemptAt: now.addingTimeInterval(60),
                now: now,
                manual: true
            )
        )
    }

    func testDajialaSpacing() {
        let now = date(1000)
        XCTAssertEqual(SubscriptionRefreshPolicy.nextDajialaDelay(lastCallAt: nil, now: now), 0)
        XCTAssertEqual(
            SubscriptionRefreshPolicy.nextDajialaDelay(
                lastCallAt: now.addingTimeInterval(-0.2),
                now: now
            ),
            0.3,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            SubscriptionRefreshPolicy.nextDajialaDelay(
                lastCallAt: now.addingTimeInterval(-1),
                now: now
            ),
            0
        )
    }

    // MARK: - 快照

    func testSnapshotRoundTripAndClear() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("subscriptions-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let cache = SubscriptionSnapshotCache(fileURL: url)
        let savedAt = date(1_700_000_000)
        let items = [
            item(id: "a", date: date(1_600_000_000)),
            item(id: "b", date: nil)
        ]
        cache.save(items: items, at: savedAt)

        let loaded = try XCTUnwrap(cache.load())
        XCTAssertEqual(loaded.items, items, "JSONEncoder.aihot 截到整秒，夹具时间本身就是整秒")
        XCTAssertEqual(loaded.savedAt, savedAt)

        cache.clear()
        XCTAssertNil(cache.load())
    }

    /// 「清除本地缓存」不得动公众号计费时间戳 —— 否则下一次启动会立刻再花一轮钱。
    @MainActor
    func testClearCacheKeepsPaidTimestamps() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("subscriptions-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let key = "wechat:test-\(UUID().uuidString)"
        var attempts = AppSettings.subscriptionWeChatLastAttempt
        attempts[key] = 1_700_000_000
        AppSettings.subscriptionWeChatLastAttempt = attempts
        defer {
            var cleanup = AppSettings.subscriptionWeChatLastAttempt
            cleanup.removeValue(forKey: key)
            AppSettings.subscriptionWeChatLastAttempt = cleanup
        }

        let cache = SubscriptionSnapshotCache(fileURL: url)
        cache.save(items: [item(id: "a")], at: date(1_700_000_000))
        let store = SubscriptionStore(snapshotCache: cache)
        store.clearCache()

        XCTAssertNil(cache.load(), "磁盘快照要清掉")
        XCTAssertEqual(
            AppSettings.subscriptionWeChatLastAttempt[key],
            1_700_000_000,
            "计费闸门必须保留"
        )
    }

    func testTextClamp() {
        XCTAssertEqual(SubscriptionText.clamp("abc", limit: 3), "abc")
        XCTAssertEqual(SubscriptionText.clamp("abcd", limit: 3), "abc")
    }
}
