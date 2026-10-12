import XCTest

@testable import AIHOT

final class StoryIDTests: XCTestCase {

    func testExtractsIdFromCurrentHost() {
        let link = "https://aihot.news/story/9ce2c8e5-8fa1-4763-b493-ddec042860cc"
        XCTAssertEqual(StoryID.publicId(fromStoryLink: link), "9ce2c8e5-8fa1-4763-b493-ddec042860cc")
    }

    func testExtractsIdFromLegacyHost() {
        // 接口现在返回的仍可能是旧域名（2026-10-31 前只做跳转），必须照样解析
        let link = "https://aihot.virxact.com/story/244f781e-a578-4493-804d-4b4cfa063ea3"
        XCTAssertEqual(StoryID.publicId(fromStoryLink: link), "244f781e-a578-4493-804d-4b4cfa063ea3")
    }

    func testIgnoresQueryAndFragment() {
        let link = "https://aihot.news/story/ba1d5ac2-160e-4d9d-ae98-63405a9bb3f3?utm=1#timeline"
        XCTAssertEqual(StoryID.publicId(fromStoryLink: link), "ba1d5ac2-160e-4d9d-ae98-63405a9bb3f3")
    }

    func testRejectsNonStoryPaths() {
        XCTAssertNil(StoryID.publicId(fromStoryLink: "https://aihot.news/hot"))
        XCTAssertNil(StoryID.publicId(fromStoryLink: "https://aihot.news/"))
        XCTAssertNil(StoryID.publicId(fromStoryLink: "https://aihot.news/story/story"))
    }

    func testRejectsMissingOrBrokenLinks() {
        XCTAssertNil(StoryID.publicId(fromStoryLink: nil))
        XCTAssertNil(StoryID.publicId(fromStoryLink: ""))
        XCTAssertNil(StoryID.publicId(fromStoryLink: "not a url"))
    }

    func testNeverTreatsHtmlPageLinkAsApi() throws {
        // 官方文档明确：links.story 是给人看的 HTML 地址，
        // 只能取末段当 publicId，不能直接请求它。这里顺手确认 www 前缀也能解析。
        let link = "https://www.aihot.news/story/0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b"
        XCTAssertEqual(StoryID.publicId(fromStoryLink: link), "0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b")
    }
}
