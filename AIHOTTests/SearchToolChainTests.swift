import XCTest

@testable import AIHOT

/// 假 runner：记下调用次数、可脚本化成败。做成 class，链里的字典持有同一只，
/// 测试才能读到 calls。
private final class FakeRunner: AIChatToolExecuting {

    var result: (text: String, isError: Bool)
    private(set) var calls = 0

    init(result: (text: String, isError: Bool) = ("ok", false)) {
        self.result = result
    }

    func execute(call: AIChatToolCall) async -> (text: String, isError: Bool) {
        calls += 1
        return result
    }
}

final class SearchToolChainTests: XCTestCase {

    private typealias Provider = AppSettings.SearchToolProvider

    private func searchCall() -> AIChatToolCall {
        AIChatToolCall(index: 0, id: "c1", name: AIChatToolName.webSearch,
                       argumentsJSON: #"{"query":"Karpathy 后续"}"#)
    }

    private func readCall() -> AIChatToolCall {
        AIChatToolCall(index: 0, id: "c2", name: AIChatToolName.readURL,
                       argumentsJSON: #"{"url":"https://example.com/a"}"#)
    }

    // MARK: - 顺序与回退

    /// 顺序即优先级：第一家成功就返回，后面的连调都不调。
    func testOrderIsRespectedAndFirstSuccessStopsTheChain() async {
        let first = FakeRunner(result: ("第一家的结果", false))
        let second = FakeRunner(result: ("第二家的结果", false))
        let chain = SearchToolChain(
            order: [.tavily, .anySearch],
            disabled: [],
            keys: [.tavily: "k"],
            runners: [.tavily: first, .anySearch: second]
        )

        let outcome = await chain.execute(call: searchCall())
        XCTAssertFalse(outcome.isError)
        XCTAssertEqual(outcome.text, "第一家的结果")
        XCTAssertEqual(first.calls, 1)
        XCTAssertEqual(second.calls, 0, "第一家成功就不该再发第二家")
    }

    /// 首家失败（Key 无效 / 429 / 网络 / isError 都算）→ 自动换下一家。
    func testFailureFallsThroughToTheNextProvider() async {
        let first = FakeRunner(result: ("Tavily 的 Key 无效或已停用（401）", true))
        let second = FakeRunner(result: ("搜索结果", false))
        let chain = SearchToolChain(
            order: [.tavily, .anySearch],
            disabled: [],
            keys: [.tavily: "k"],
            runners: [.tavily: first, .anySearch: second]
        )

        let outcome = await chain.execute(call: searchCall())
        XCTAssertFalse(outcome.isError, "回退成功：用户看到的是结果，不是错误")
        XCTAssertEqual(outcome.text, "搜索结果")
        XCTAssertEqual(first.calls, 1)
        XCTAssertEqual(second.calls, 1)
    }

    /// 全部失败 → **回传第一家的错误**（最好排查）；后几家的错不得出现。
    func testAllFailuresReturnTheFirstProvidersError() async {
        let first = FakeRunner(result: ("第一家的错", true))
        let second = FakeRunner(result: ("第二家的错", true))
        let chain = SearchToolChain(
            order: [.tavily, .serpapi],
            disabled: [],
            keys: [.tavily: "k", .serpapi: "k2"],
            runners: [.tavily: first, .serpapi: second]
        )

        let outcome = await chain.execute(call: searchCall())
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(outcome.text.contains("第一家的错"), "实际：\(outcome.text)")
        XCTAssertFalse(outcome.text.contains("第二家的错"),
                       "全败点名第一家 —— 后几家的错不该混进来，实际：\(outcome.text)")
        XCTAssertEqual(first.calls, 1)
        XCTAssertEqual(second.calls, 1, "走完了链才放弃")
    }

    // MARK: - 能力矩阵与开关

    /// `read_url` 自动跳过不支持读网页的家（SerpAPI / Serper 能力矩阵 ✗）。
    func testReadURLSkipsProvidersWithoutExtractCapability() async {
        let anySearch = FakeRunner(result: ("页面正文", false))
        let tavily = FakeRunner()
        let serpapi = FakeRunner()
        let exa = FakeRunner()
        let serper = FakeRunner()
        let chain = SearchToolChain(
            order: Provider.allCases,
            disabled: [],
            keys: [.tavily: "k", .serpapi: "k", .exa: "k", .serper: "k"],
            runners: [
                .anySearch: anySearch, .tavily: tavily,
                .serpapi: serpapi, .exa: exa, .serper: serper,
            ]
        )

        let outcome = await chain.execute(call: readCall())
        XCTAssertFalse(outcome.isError)
        XCTAssertEqual(anySearch.calls, 1, "第一家可读的家上场")
        XCTAssertEqual(serpapi.calls, 0, "只搜索的家零参与")
        XCTAssertEqual(serper.calls, 0, "只搜索的家零参与")
        XCTAssertEqual(tavily.calls, 0)
        XCTAssertEqual(exa.calls, 0)
    }

    /// 停用的家直接跳过，哪怕它排第一。
    func testDisabledProvidersAreSkipped() async {
        let anySearch = FakeRunner(result: ("不该被调", false))
        let tavily = FakeRunner(result: ("搜索结果", false))
        let chain = SearchToolChain(
            order: [.anySearch, .tavily],
            disabled: [.anySearch],
            keys: [.tavily: "k"],
            runners: [.anySearch: anySearch, .tavily: tavily]
        )

        let outcome = await chain.execute(call: searchCall())
        XCTAssertFalse(outcome.isError)
        XCTAssertEqual(outcome.text, "搜索结果")
        XCTAssertEqual(anySearch.calls, 0, "停用了就不发网络")
        XCTAssertEqual(tavily.calls, 1)
    }

    /// 必填 Key 没填（含只填了空白）的家跳过。
    func testProviderWithoutRequiredKeyIsSkipped() async {
        let serpapi = FakeRunner(result: ("不该被调", false))
        let anySearch = FakeRunner(result: ("搜索结果", false))
        let chain = SearchToolChain(
            order: [.serpapi, .anySearch],
            disabled: [],
            keys: [.serpapi: "   "],
            runners: [.serpapi: serpapi, .anySearch: anySearch]
        )

        let outcome = await chain.execute(call: searchCall())
        XCTAssertFalse(outcome.isError)
        XCTAssertEqual(serpapi.calls, 0, "必填 Key 是空白 = 没填 = 不参与")
        XCTAssertEqual(anySearch.calls, 1)
    }

    /// AnySearch 空 Key **保留**：匿名合法，不能被「必填」过滤误杀。
    func testAnySearchWithoutKeyStillParticipates() async {
        let anySearch = FakeRunner(result: ("匿名搜索结果", false))
        let chain = SearchToolChain(
            order: [.anySearch],
            disabled: [],
            keys: [:],
            runners: [.anySearch: anySearch]
        )

        let outcome = await chain.execute(call: searchCall())
        XCTAssertFalse(outcome.isError)
        XCTAssertEqual(anySearch.calls, 1)
    }

    // MARK: - 一个可试的家都没有

    func testEmptyEligibleGivesActionableMessageForSearch() async {
        let chain = SearchToolChain(
            order: Provider.allCases,
            disabled: Set(Provider.allCases),
            keys: [:],
            runners: [:]
        )

        let outcome = await chain.execute(call: searchCall())
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(outcome.text.contains("没有可用的搜索工具"), "实际：\(outcome.text)")
        XCTAssertTrue(outcome.text.contains("设置 → AI 对话 → 搜索工具"), "要给出能照做的路径")
        XCTAssertTrue(outcome.text.contains("匿名"), "顺带给出 AnySearch 的匿名退路")
    }

    /// 只剩「只搜索」的家时，`read_url` 的提示要点名为什么读不了。
    func testEmptyEligibleGivesActionableMessageForReadURL() async {
        let serpapi = FakeRunner()
        let serper = FakeRunner()
        let chain = SearchToolChain(
            order: [.serpapi, .serper],
            disabled: [],
            keys: [.serpapi: "k", .serper: "k"],
            runners: [.serpapi: serpapi, .serper: serper]
        )

        let outcome = await chain.execute(call: readCall())
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(outcome.text.contains("没有能读网页的工具"), "实际：\(outcome.text)")
        XCTAssertTrue(outcome.text.contains("SerpAPI、Serper 只支持搜索"), "点名原因")
        XCTAssertTrue(outcome.text.contains("设置 → AI 对话 → 搜索工具"), "要给出能照做的路径")
        XCTAssertEqual(serpapi.calls, 0, "没有可试的家就不发网络")
        XCTAssertEqual(serper.calls, 0)
    }

    // MARK: - 结构短路（0 次 runner 调用）

    func testStructuralProblemsShortCircuitBeforeAnyProvider() async {
        let anySearch = FakeRunner()
        let chain = SearchToolChain(
            order: [.anySearch],
            disabled: [],
            keys: [:],
            runners: [.anySearch: anySearch]
        )

        // 缺参数
        let missing = await chain.execute(
            call: AIChatToolCall(index: 0, id: "c3", name: AIChatToolName.webSearch, argumentsJSON: "{}")
        )
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("缺少必需的参数"), "实际：\(missing.text)")

        // 未知工具
        let unknown = await chain.execute(
            call: AIChatToolCall(index: 1, id: "c4", name: "delete_everything", argumentsJSON: "{}")
        )
        XCTAssertTrue(unknown.isError)
        XCTAssertTrue(unknown.text.contains("没有这个工具"), "实际：\(unknown.text)")

        // 没给工具名（accumulator 会先丢掉，这里纯防御）
        let nameless = await chain.execute(
            call: AIChatToolCall(index: 2, id: "c5", name: nil, argumentsJSON: "{}")
        )
        XCTAssertTrue(nameless.isError)
        XCTAssertTrue(nameless.text.contains("没有给出工具名"), "实际：\(nameless.text)")

        XCTAssertEqual(anySearch.calls, 0, "结构性问题走完链零信息量，一个提供方都不该碰")
    }

    // MARK: - eligibleProviders（纯函数）

    func testEligibleProvidersFiltersAndKeepsUserOrder() {
        let eligible = SearchToolChain.eligibleProviders(
            order: Provider.allCases,
            disabled: [.serper],
            keys: [.tavily: "k", .serpapi: " ", .exa: "k", .serper: "k"],
            tool: AIChatToolName.readURL
        )
        // serpapi / serper 不支持读网页（serper 还被停用了）—— 过滤后仍保持用户顺序
        XCTAssertEqual(eligible, [.anySearch, .tavily, .exa])
    }

    // MARK: - 顺序 / 开关的规范化（纯函数，镜像 15 钉同一套规则）

    func testNormalizeOrderMigratesLegacySingleSelectFirst() {
        XCTAssertEqual(
            AppSettings.normalizeSearchToolOrder(stored: nil, legacySingleRaw: "tavily"),
            [.tavily, .anySearch, .serpapi, .exa, .serper],
            "升级首启：旧的单选值排第一，其余按声明顺序补齐"
        )
        XCTAssertEqual(AppSettings.normalizeSearchToolOrder(stored: nil, legacySingleRaw: nil),
                       Provider.allCases, "没旧值就是规范顺序")
        XCTAssertEqual(AppSettings.normalizeSearchToolOrder(stored: nil, legacySingleRaw: "bogus"),
                       Provider.allCases, "旧值非法（将来枚举变了）也退回规范顺序")
    }

    func testNormalizeOrderDropsUnknownDedupsAndAppendsMissing() {
        XCTAssertEqual(
            AppSettings.normalizeSearchToolOrder(stored: ["serper", "anySearch", "bogus", "serper"],
                                                 legacySingleRaw: "tavily"),
            [.serper, .anySearch, .tavily, .serpapi, .exa],
            "丢未知、首次出现去重、缺的追加到末尾；legacy 只在 stored 为 nil 时才看"
        )
        XCTAssertEqual(AppSettings.normalizeSearchToolOrder(stored: [], legacySingleRaw: "tavily"),
                       Provider.allCases, "空数组自愈为规范顺序，不读旧键")
    }

    func testNormalizeDisabledDropsUnknownAndDedups() {
        XCTAssertEqual(AppSettings.normalizeSearchToolDisabled(stored: nil), [], "没动过开关 = 全启用")
        XCTAssertEqual(AppSettings.normalizeSearchToolDisabled(stored: ["serpapi", "bogus", "serpapi"]),
                       [.serpapi], "丢未知、去重")
    }
}
