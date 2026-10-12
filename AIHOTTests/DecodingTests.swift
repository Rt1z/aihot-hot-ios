import XCTest

@testable import AIHOT

final class DecodingTests: XCTestCase {

    func testHotTopicsFixtureDecodes() throws {
        let data = try Fixture.data("hot-topics", ext: "json")
        let response = try JSONDecoder.aihot.decode(HotTopicsResponse.self, from: data)

        XCTAssertEqual(response.count, 3)
        XCTAssertEqual(response.items.count, 3)

        let first = response.items[0]
        XCTAssertEqual(first.rank, 1)
        XCTAssertEqual(first.title, "Karpathy：LLM 能力认知鸿沟扩大为漏斗")
        XCTAssertEqual(first.sourceCount, 7)
        XCTAssertEqual(first.signalCount, 9)
        XCTAssertEqual(first.participantCount, 16)
        XCTAssertEqual(first.sourceNames?.count, 7)
        XCTAssertEqual(first.source?.name, "X：Andrej Karpathy (@karpathy)")

        // 接口给的是带毫秒的 ISO8601，内置 .iso8601 解不出来，必须走我们的容错解析
        let expected = try XCTUnwrap(AIHOTDate.parse("2026-10-12T01:40:20.000Z"))
        XCTAssertEqual(first.latestAt, expected)
    }

    func testSourceNamesBecomeStableIdentifiers() throws {
        let data = try Fixture.data("hot-topics", ext: "json")
        let response = try JSONDecoder.aihot.decode(HotTopicsResponse.self, from: data)

        // 每一条都要有 id 与 rank，列表才能稳定排序与 NavigationLink
        let ids = response.items.map { $0.id }
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(response.items.map { $0.rank }, [1, 2, 3])
    }

    func testStoryFixtureDecodes() throws {
        let data = try Fixture.data("story", ext: "json")
        let response = try JSONDecoder.aihot.decode(StoryResponse.self, from: data)
        let story = response.story

        XCTAssertEqual(story.publicId, "03d4f9c6-4714-45e7-9db8-7af5df7e940a")
        XCTAssertEqual(story.title, "亚马逊洽谈约70亿美元收购Decart")
        XCTAssertEqual(story.status, "active")
        XCTAssertEqual(story.sourceCount, 1)
        XCTAssertEqual(story.reportCount, 1)
        XCTAssertEqual(story.digestParagraphs.count, 3)
        XCTAssertEqual(story.reports?.count, 1)
        XCTAssertEqual(story.sortedReports.first?.source?.name, "IT之家·人工智能")
        XCTAssertEqual(story.sortedReports.first?.links?.original, "https://www.ithome.com/1/011/720.htm")
    }

    func testHotTopicsSnapshotRoundTrip() throws {
        let data = try Fixture.data("hot-topics", ext: "json")
        let response = try JSONDecoder.aihot.decode(HotTopicsResponse.self, from: data)

        // 本地快照要能存能读（日期策略必须对称）
        let encoded = try JSONEncoder.aihot.encode(response)
        let restored = try JSONDecoder.aihot.decode(HotTopicsResponse.self, from: encoded)

        XCTAssertEqual(restored.items.count, response.items.count)
        XCTAssertEqual(restored.items[0].latestAt, response.items[0].latestAt)
    }
}
