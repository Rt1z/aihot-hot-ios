import XCTest

@testable import InOut

/// 喂给模型的那段资料。两个性质必须守住：原文 URL 原样出现（web_fetch 靠它），
/// 以及逐字节确定性（否则每轮都打断缓存前缀）。
final class AIChatNewsContextTests: XCTestCase {

    private func fixtureItem() throws -> HotTopic {
        let data = try Fixture.data("hot-topics", ext: "json")
        let response = try JSONDecoder.aihot.decode(HotTopicsResponse.self, from: data)
        return try XCTUnwrap(response.items.first)
    }

    private func fixtureStory() throws -> Story {
        let data = try Fixture.data("story", ext: "json")
        let response = try JSONDecoder.aihot.decode(StoryResponse.self, from: data)
        return response.story
    }

    func testOriginalURLAppearsVerbatim() throws {
        let item = try fixtureItem()
        let original = try XCTUnwrap(item.links?.original)
        let context = AIChatNewsContext.make(item: item, story: nil, prefetchedDigest: nil)
        XCTAssertTrue(
            context.contains(original),
            "原文链接必须原样出现 —— Anthropic 的 web_fetch 只能抓对话里已经出现过的 URL"
        )
    }

    func testPrefersStoryTitleFallsBackToItemTitle() throws {
        let item = try fixtureItem()
        let story = try fixtureStory()

        XCTAssertTrue(AIChatNewsContext.make(item: item, story: story, prefetchedDigest: nil).contains(story.title))
        XCTAssertTrue(AIChatNewsContext.make(item: item, story: nil, prefetchedDigest: nil).contains(item.title))
    }

    func testAbsoluteTimeOnly() throws {
        let item = try fixtureItem()
        let story = try fixtureStory()
        let context = AIChatNewsContext.make(item: item, story: story, prefetchedDigest: nil)

        for relative in ["小时前", "分钟前", "天前", "刚刚"] {
            XCTAssertFalse(context.contains(relative), "相对时间每轮都在变，会打断缓存前缀")
        }
        let latest = try XCTUnwrap(item.latestAt)
        XCTAssertTrue(context.contains(RelativeTime.absoluteShort(latest)))
    }

    func testDeterministic() throws {
        let item = try fixtureItem()
        let story = try fixtureStory()
        XCTAssertEqual(
            AIChatNewsContext.make(item: item, story: story, prefetchedDigest: "预取摘要"),
            AIChatNewsContext.make(item: item, story: story, prefetchedDigest: "预取摘要")
        )
    }

    func testIncludesDigestAndTimeline() throws {
        let item = try fixtureItem()
        let story = try fixtureStory()
        let context = AIChatNewsContext.make(item: item, story: story, prefetchedDigest: nil)

        let digest = try XCTUnwrap(story.digest)
        let paragraph = try XCTUnwrap(
            digest.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
        )
        XCTAssertTrue(context.contains(paragraph))
        XCTAssertTrue(context.contains("【AI 摘要】"))

        let reportTitle = try XCTUnwrap(story.sortedReports.first?.title)
        XCTAssertTrue(context.contains(reportTitle))
    }

    func testFallsBackToPrefetchedDigest() throws {
        let item = try fixtureItem()
        let context = AIChatNewsContext.make(item: item, story: nil, prefetchedDigest: "预取来的摘要正文")
        XCTAssertTrue(context.contains("预取来的摘要正文"))
    }

    func testLongInputIsTruncatedWithAMarker() throws {
        let item = try fixtureItem()
        let huge = String(repeating: "这是一段很长的正文。", count: 2000)
        let context = AIChatNewsContext.make(item: item, story: nil, prefetchedDigest: huge)

        XCTAssertLessThanOrEqual(context.count, AIChatNewsContext.maxCharacters + 40)
        XCTAssertTrue(context.contains("已截断"))
    }

    // MARK: - 导入文章

    func testLinkContextIncludesTitleURLAndBody() {
        let link = SavedLink(url: "https://mp.weixin.qq.com/s/abc", title: "一篇文章")
        let context = AIChatNewsContext.make(link: link, articleText: "这是正文。")

        XCTAssertTrue(context.contains("一篇文章"))
        XCTAssertTrue(context.contains(link.url), "链接必须原样出现，read_url 才读得到")
        XCTAssertTrue(context.contains("这是正文。"))
        XCTAssertTrue(context.contains("公众号文章"))
    }

    func testLinkContextAdmitsMissingBody() {
        let link = SavedLink(url: "https://example.com/a", title: "示例")
        let context = AIChatNewsContext.make(link: link, articleText: nil)

        XCTAssertTrue(context.contains("正文尚未取到"))
        XCTAssertFalse(context.contains("这是正文。"))
    }

    func testLinkContextIsClamped() {
        let link = SavedLink(url: "https://example.com/a", title: "示例")
        let huge = String(repeating: "长文。", count: 10_000)
        let context = AIChatNewsContext.make(link: link, articleText: huge)

        XCTAssertLessThanOrEqual(context.count, AIChatNewsContext.maxCharacters + 40)
        XCTAssertTrue(context.contains("已截断"))
    }

    func testLinkSystemMentionsArticleAndReading() {
        XCTAssertTrue(AIChatNewsContext.linkSystem.contains("网页文章"))
        XCTAssertTrue(AIChatNewsContext.linkSystem.contains("read_url"))
    }
}
