import XCTest

@testable import AIHOT

/// 分类器的规格夹具 + 词库不变量。镜像 21 读同一份夹具。
final class SubscriptionClassifierTests: XCTestCase {

    private struct Case: Decodable {
        let title: String
        let summary: String
        let expected: SubscriptionTopic
    }

    func testFixtureCases() throws {
        let data = try Fixture.data("subscription-classify", ext: "json")
        let cases = try JSONDecoder().decode([Case].self, from: data)
        XCTAssertFalse(cases.isEmpty, "夹具不能是空的")
        for item in cases {
            XCTAssertEqual(
                SubscriptionClassifier.classify(title: item.title, summary: item.summary),
                item.expected,
                "标题「\(item.title)」/ 摘要「\(item.summary)」"
            )
        }
    }

    /// 每个关键词只能属于一个板块；空格、空串都会让镜像与 Swift 悄悄分叉。
    func testLexiconInvariants() {
        var seen = Set<String>()
        for entry in SubscriptionClassifier.lexicon {
            XCTAssertFalse(entry.keyword.isEmpty, "空关键词")
            XCTAssertEqual(
                entry.keyword,
                entry.keyword.trimmingCharacters(in: .whitespacesAndNewlines),
                "关键词两端不许有空白：\(entry.keyword)"
            )
            XCTAssertFalse(seen.contains(entry.keyword), "关键词重复：\(entry.keyword)")
            seen.insert(entry.keyword)
        }
    }

    /// 标题 3 分、摘要 1 分；平分按 allCases 顺序（科技在前）。
    func testTitleWeighsMoreThanSummaryAndTiesGoByDeclarationOrder() {
        let scores = SubscriptionClassifier.scores(title: "芯片", summary: "睡眠 营养 饮食")
        XCTAssertEqual(scores[.tech], 3, "标题一个关键词 = 3 分")
        XCTAssertEqual(scores[.health], 3, "摘要三个关键词各 1 分")
        XCTAssertEqual(
            SubscriptionClassifier.classify(title: "芯片", summary: "睡眠 营养 饮食"),
            .tech,
            "平分时保留 allCases 里更靠前的板块"
        )
    }

    /// 纯 ASCII 关键词必须按词边界匹配，否则 `ai` 会命中 said / again / email。
    func testASCIIKeywordsRequireWordBoundaries() {
        XCTAssertEqual(SubscriptionClassifier.classify(title: "AI 芯片", summary: ""), .tech)
        XCTAssertEqual(SubscriptionClassifier.classify(title: "again and again", summary: ""), .peripheral)
        XCTAssertEqual(SubscriptionClassifier.classify(title: "email marketing", summary: ""), .peripheral)
        XCTAssertEqual(SubscriptionClassifier.classify(title: "said the CEO", summary: ""), .peripheral)
        XCTAssertEqual(SubscriptionClassifier.classify(title: "OPENAI", summary: ""), .tech)
    }

    func testFallbackIsPeripheral() {
        XCTAssertEqual(SubscriptionClassifier.classify(title: "", summary: ""), .peripheral)
        XCTAssertEqual(SubscriptionClassifier.classify(title: "今天", summary: "天气不错"), .peripheral)
    }

    func testFullWidthASCIIIsFoldedBeforeMatching() {
        XCTAssertEqual(SubscriptionClassifier.classify(title: "ＡＩ 手机", summary: ""), .tech)
        XCTAssertEqual(SubscriptionClassifier.classify(title: "ＧＰＵ 算力", summary: ""), .tech)
    }

    func testRepeatedCallsAreDeterministic() {
        let title = "AI 芯片与睡眠、面试"
        let first = SubscriptionClassifier.classify(title: title, summary: "读书与咖啡")
        for _ in 0..<20 {
            XCTAssertEqual(SubscriptionClassifier.classify(title: title, summary: "读书与咖啡"), first)
        }
    }
}
