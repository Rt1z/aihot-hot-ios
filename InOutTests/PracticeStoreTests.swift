import XCTest

@testable import InOut

/// `PracticeStore` 是 @MainActor 的，用例逐个方法标 `@MainActor`
/// （不标整个类：那会连带把 setUp/tearDown 变成主 actor 隔离的覆写）。
final class PracticeStoreTests: XCTestCase {

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aihot-practice-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func entry(
        id: UUID = UUID(),
        title: String = "标题",
        articleID: String = "a",
        createdAt: Date = Date(timeIntervalSince1970: 1_760_000_000),
        mainIdea: String = "主旨"
    ) -> PracticeEntry {
        PracticeEntry(
            id: id,
            article: PracticeArticle(
                kind: .hot,
                articleID: articleID,
                title: title,
                sourceName: "示例来源",
                originalURL: "https://example.com/a",
                aihotURL: "https://aihot.news/story/a",
                digest: "导读"
            ),
            createdAt: createdAt,
            mode: .structured,
            mainIdea: mainIdea,
            points: ["要点"]
        )
    }

    @MainActor
    private func makeStore(in directory: URL) -> PracticeStore {
        PracticeStore(
            entriesURL: directory.appendingPathComponent("practice-entries.json"),
            draftsURL: directory.appendingPathComponent("practice-drafts.json")
        )
    }

    // MARK: - 记录

    @MainActor
    func testStartsEmpty() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = makeStore(in: directory)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.drafts.isEmpty)
    }

    @MainActor
    func testNewEntriesGoToTheFrontAndSurviveReload() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = makeStore(in: directory)
        let first = entry(title: "第一条", articleID: "a")
        let second = entry(title: "第二条", articleID: "b")
        store.save(first)
        store.save(second)

        XCTAssertEqual(store.entries.map(\.article.title), ["第二条", "第一条"])

        // 顺序的权威是数组，不是 createdAt（两条时间相同也照样稳定）
        let reloaded = makeStore(in: directory)
        XCTAssertEqual(reloaded.entries.map(\.article.title), ["第二条", "第一条"])
    }

    @MainActor
    func testUpdatingKeepsPosition() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = makeStore(in: directory)
        let first = entry(title: "第一条", articleID: "a")
        let second = entry(title: "第二条", articleID: "b")
        store.save(first)
        store.save(second)

        var updated = first
        updated.mainIdea = "改过的"
        store.save(updated)

        XCTAssertEqual(store.entries.map(\.article.title), ["第二条", "第一条"])
        XCTAssertEqual(store.entries.last?.mainIdea, "改过的")
    }

    @MainActor
    func testAttachReviewAndDelete() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = makeStore(in: directory)
        let record = entry()
        store.save(record)

        store.attachReview(
            PracticeReviewSnapshot(
                text: "点评正文",
                createdAt: Date(timeIntervalSince1970: 1_760_000_100),
                model: "test-model",
                basis: "导读"
            ),
            to: record.id
        )
        XCTAssertEqual(store.entries.first?.review?.text, "点评正文")

        store.delete(id: record.id)
        XCTAssertTrue(store.entries.isEmpty)
    }

    @MainActor
    func testDateRoundTripsAtSecondPrecision() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = makeStore(in: directory)
        store.save(entry(createdAt: Date(timeIntervalSince1970: 1_760_000_000.75)))

        let reloaded = makeStore(in: directory)
        XCTAssertEqual(reloaded.entries.first?.createdAt.timeIntervalSince1970, 1_760_000_000)
    }

    @MainActor
    func testCorruptFileStartsEmptyAndIsReplacedOnNextSave() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let entriesURL = directory.appendingPathComponent("practice-entries.json")
        try Data("不是 JSON".utf8).write(to: entriesURL)

        let store = makeStore(in: directory)
        XCTAssertTrue(store.entries.isEmpty)

        store.save(entry())
        let reloaded = makeStore(in: directory)
        XCTAssertEqual(reloaded.entries.count, 1)
    }

    @MainActor
    func testEncodingFailureLeavesTheOldFileUntouched() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let entriesURL = directory.appendingPathComponent("practice-entries.json")
        let draftsURL = directory.appendingPathComponent("practice-drafts.json")

        let stored = entry(title: "旧记录")
        try JSONEncoder.aihot.encode([stored]).write(to: entriesURL)

        struct EncodingFailure: Error {}
        let store = PracticeStore(
            entriesURL: entriesURL,
            draftsURL: draftsURL,
            encodeEntries: { _ in throw EncodingFailure() }
        )
        XCTAssertEqual(store.entries.count, 1)

        store.save(entry(title: "新记录"))

        let data = try Data(contentsOf: entriesURL)
        let reloaded = try JSONDecoder.aihot.decode([PracticeEntry].self, from: data)
        XCTAssertEqual(reloaded.map(\.article.title), ["旧记录"])
    }

    // MARK: - 草稿

    @MainActor
    func testDraftsAreScopedByArticleAndRemovable() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = makeStore(in: directory)
        let article = entry(articleID: "a").article
        let otherArticle = entry(articleID: "b").article

        XCTAssertNil(store.draft(for: article))

        store.saveDraft(
            PracticeDraft(
                article: article,
                mode: .free,
                mainIdea: "",
                points: ["", "", ""],
                takeaway: "",
                freeText: "写了一半",
                updatedAt: Date(timeIntervalSince1970: 1_760_000_000)
            )
        )

        XCTAssertEqual(store.draft(for: article)?.freeText, "写了一半")
        XCTAssertNil(store.draft(for: otherArticle))

        // 重启后草稿还在
        let reloaded = makeStore(in: directory)
        XCTAssertEqual(reloaded.draft(for: article)?.freeText, "写了一半")

        store.deleteDraft(for: article)
        XCTAssertNil(store.draft(for: article))
    }

    @MainActor
    func testDraftUpsertDoesNotDuplicate() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = makeStore(in: directory)
        let article = entry().article

        for text in ["一", "二"] {
            store.saveDraft(
                PracticeDraft(
                    article: article,
                    mode: .free,
                    mainIdea: "",
                    points: ["", "", ""],
                    takeaway: "",
                    freeText: text,
                    updatedAt: Date(timeIntervalSince1970: 1_760_000_000)
                )
            )
        }

        XCTAssertEqual(store.drafts.count, 1)
        XCTAssertEqual(store.drafts.first?.freeText, "二")
    }
}
