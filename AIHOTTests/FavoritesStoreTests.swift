import XCTest

@testable import AIHOT

/// `FavoritesStore` 是 @MainActor 的，所以用例也必须跑在主 actor 上，
/// 否则调用它连编译都过不去（不是警告）。这里逐个方法标 @MainActor，
/// 而不是把整个类标上：那样会连带把 setUp/tearDown 变成主 actor 隔离的
/// 覆写，而父类那两个是非隔离的。
final class FavoritesStoreTests: XCTestCase {

    /// 每个用例一份独立 suite：不碰 App 真实的 UserDefaults，用例之间也不互相串。
    private func freshDefaults() -> (name: String, defaults: UserDefaults) {
        let name = "aihot.tests.favorites.\(UUID().uuidString)"
        return (name, UserDefaults(suiteName: name) ?? .standard)
    }

    private func makeTopic(id: String, rank: Int) -> HotTopic {
        HotTopic(
            rank: rank,
            id: id,
            title: "标题 \(id)",
            source: Source(name: "IT之家·人工智能", firstParty: false),
            links: Links(
                aihot: "https://aihot.news/story/\(id)",
                original: "https://www.ithome.com/\(id).htm",
                story: "https://aihot.news/story/\(id)"
            ),
            sourceCount: 7,
            signalCount: 9,
            participantCount: 16,
            sourceNames: ["邵猛", "Oran Ge"],
            latestAt: Date(timeIntervalSince1970: 1_760_000_000)
        )
    }

    // MARK: - 基本行为

    @MainActor
    func testStartsEmpty() throws {
        let (name, defaults) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = FavoritesStore(defaults: defaults)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(store.contains(id: "a"))
        XCTAssertFalse(store.contains(makeTopic(id: "a", rank: 1)))
    }

    @MainActor
    func testToggleAddsThenRemoves() throws {
        let (name, defaults) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = FavoritesStore(defaults: defaults)
        let topic = makeTopic(id: "a", rank: 1)

        store.toggle(topic)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertTrue(store.contains(topic))

        store.toggle(topic)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(store.contains(topic))
    }

    @MainActor
    func testAddIsIdempotent() throws {
        let (name, defaults) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = FavoritesStore(defaults: defaults)
        store.add(makeTopic(id: "a", rank: 1))
        store.add(makeTopic(id: "a", rank: 1))
        XCTAssertEqual(store.items.count, 1, "连点两次不该出现两条")

        // 同一条 id 再次 add 是 no-op：快照不会被后来的覆盖（要先取消收藏再收）
        store.add(makeTopic(id: "a", rank: 7))
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.topic.rank, 1)
    }

    // MARK: - 顺序

    @MainActor
    func testNewestFirst() throws {
        let (name, defaults) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = FavoritesStore(defaults: defaults)
        store.add(makeTopic(id: "a", rank: 1), at: Date(timeIntervalSince1970: 1_760_000_000))
        store.add(makeTopic(id: "b", rank: 2), at: Date(timeIntervalSince1970: 1_760_000_060))

        XCTAssertEqual(store.items.map(\.id), ["b", "a"])
    }

    /// 同一秒收藏的两条，重启后顺序不能变。
    ///
    /// 这条专门用来钉住「顺序 = 数组顺序、不按时间排序」这个决定：
    /// 如果哪天有人图省事改成 `sorted(by: favoritedAt)`，Swift 的 sort 不稳定，
    /// 同一秒的两条就会每次重启随机换位。
    @MainActor
    func testOrderSurvivesReloadWhenTimestampsTie() throws {
        let (name, defaults) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let sameInstant = Date(timeIntervalSince1970: 1_760_000_000)
        let first = FavoritesStore(defaults: defaults)
        first.add(makeTopic(id: "a", rank: 1), at: sameInstant)
        first.add(makeTopic(id: "b", rank: 2), at: sameInstant)
        XCTAssertEqual(first.items.map(\.id), ["b", "a"])

        let reloaded = FavoritesStore(defaults: defaults)
        XCTAssertEqual(reloaded.items.map(\.id), ["b", "a"], "时间戳相同也不能换位")
    }

    // MARK: - 落盘

    /// 跨实例往返，逐字段核对（含 HotTopic 里的日期与可选值）。
    /// 时间用整秒：见下面那条截断测试。
    @MainActor
    func testPersistsAcrossInstances() throws {
        let (name, defaults) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let whole = Date(timeIntervalSince1970: 1_760_000_000)
        let later = whole.addingTimeInterval(60)
        let a = makeTopic(id: "a", rank: 1)
        let b = makeTopic(id: "b", rank: 2)

        let first = FavoritesStore(defaults: defaults)
        first.add(a, at: whole)
        first.add(b, at: later)

        let second = FavoritesStore(defaults: defaults)
        XCTAssertEqual(second.items.map(\.id), ["b", "a"])

        let restored = try XCTUnwrap(second.items.first)
        XCTAssertEqual(restored.favoritedAt, later)
        XCTAssertEqual(restored.topic, b, "整条快照（含 sourceNames/links/latestAt）都要原样回来")
        XCTAssertTrue(second.contains(b))
    }

    /// `JSONEncoder.aihot` 写的是不带小数秒的 ISO8601（见 HotTopics.swift 的
    /// AIHOTDate），所以收藏时间落盘后会截到整秒。
    ///
    /// 这是**预期行为**，界面上只显示到分钟。写这条是为了两件事：
    /// 一是别让后来的人用 `XCTAssertEqual` 直接比 `Date()` 而误以为实现有 bug；
    /// 二是拦住「给编码器补上 .withFractionalSeconds」这种"修法" ——
    /// 那个编码器和榜单快照是共用的，改了会顺带改掉快照格式。
    @MainActor
    func testFavoritedAtIsTruncatedToWholeSeconds() throws {
        let (name, defaults) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let precise = Date(timeIntervalSince1970: 1_760_000_000.75)
        FavoritesStore(defaults: defaults).add(makeTopic(id: "a", rank: 1), at: precise)

        let restored = try XCTUnwrap(FavoritesStore(defaults: defaults).items.first)
        XCTAssertEqual(restored.favoritedAt.timeIntervalSince1970, 1_760_000_000, accuracy: 0.001)
        XCTAssertLessThan(abs(restored.favoritedAt.timeIntervalSince1970 - precise.timeIntervalSince1970), 1)
    }

    @MainActor
    func testClearPersistsAcrossInstances() throws {
        let (name, defaults) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = FavoritesStore(defaults: defaults)
        store.add(makeTopic(id: "a", rank: 1))
        store.add(makeTopic(id: "b", rank: 2))
        store.clear()

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(FavoritesStore(defaults: defaults).items.isEmpty, "清空也要落盘")
    }

    // MARK: - 坏数据不能让收藏整份消失

    @MainActor
    func testGarbageBlobYieldsEmptyInsteadOfCrashing() throws {
        let (name, defaults) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(Data([0x00, 0x01, 0x02]), forKey: AppSettings.favoritesKey)
        XCTAssertTrue(FavoritesStore(defaults: defaults).items.isEmpty)
    }

    /// 一条解不动，其余照常读回来 —— 收藏项里包着整条 HotTopic，
    /// 接口哪天改字段时不该连累用户攒的其它收藏。
    @MainActor
    func testOneBadElementDoesNotDiscardTheRest() throws {
        let (name, defaults) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let json = #"[{"topic": 5, "favoritedAt": "2026-10-12T02:35:00Z"}, {"topic": {"rank": 2, "id": "b", "title": "标题 b"}, "favoritedAt": "2026-10-12T02:36:00Z"}]"#
        defaults.set(Data(json.utf8), forKey: AppSettings.favoritesKey)

        let store = FavoritesStore(defaults: defaults)
        XCTAssertEqual(store.items.map(\.id), ["b"])
    }
}
