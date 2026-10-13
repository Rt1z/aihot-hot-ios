import XCTest

@testable import AIHOT

/// 假后端：单测绝不碰真钥匙串。
private final class FakeSecretBackend: AIChatSecretBackend {

    var storage: [String: String] = [:]
    /// 模拟侧载签名下钥匙串写入失败（例如 `errSecMissingEntitlement`）。
    var failWrites = false

    func read(account: String) -> String? {
        storage[account]
    }

    func write(_ value: String, account: String) -> Bool {
        if failWrites { return false }
        storage[account] = value
        return true
    }

    func delete(account: String) {
        storage.removeValue(forKey: account)
    }
}

final class AIChatSecretStoreTests: XCTestCase {

    private func makeSuite() -> (name: String, defaults: UserDefaults) {
        let name = "aihot.tests.aichat.\(UUID().uuidString)"
        return (name, UserDefaults(suiteName: name) ?? .standard)
    }

    func testStoresEachProtocolSeparately() {
        let (name, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = AIChatSecretStore(backend: FakeSecretBackend(), defaults: defaults)
        XCTAssertTrue(store.setKey("sk-ant", for: .anthropicMessages))
        XCTAssertTrue(store.setKey("sk-openai", for: .openAICompatible))

        XCTAssertEqual(store.key(for: .anthropicMessages), "sk-ant")
        XCTAssertEqual(store.key(for: .openAICompatible), "sk-openai", "切协议不能串 Key")
    }

    /// 钥匙串写不进去时必须还能用：退到 UserDefaults，并且**让界面知道已降级**。
    /// 静默降级密钥存储是不能接受的。
    func testFallsBackWhenKeychainWriteFails() {
        let (name, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let backend = FakeSecretBackend()
        backend.failWrites = true
        let store = AIChatSecretStore(backend: backend, defaults: defaults)

        XCTAssertFalse(store.setKey("sk-fallback", for: .anthropicMessages))
        XCTAssertEqual(store.key(for: .anthropicMessages), "sk-fallback", "降级后必须读得回来")
        XCTAssertTrue(store.isUsingFallback(for: .anthropicMessages))
        XCTAssertFalse(store.isUsingFallback(for: .openAICompatible))
    }

    /// 后来钥匙串能写了，就不该再留着兜底那份（两处不一致最难查）。
    func testSuccessfulWriteClearsFallbackCopy() {
        let (name, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let backend = FakeSecretBackend()
        backend.failWrites = true
        let store = AIChatSecretStore(backend: backend, defaults: defaults)
        XCTAssertFalse(store.setKey("sk-1", for: .anthropicMessages))
        XCTAssertTrue(store.isUsingFallback(for: .anthropicMessages))

        backend.failWrites = false
        XCTAssertTrue(store.setKey("sk-2", for: .anthropicMessages))
        XCTAssertFalse(store.isUsingFallback(for: .anthropicMessages))
        XCTAssertEqual(store.key(for: .anthropicMessages), "sk-2")
    }

    func testEmptyValueClearsBothStores() {
        let (name, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let backend = FakeSecretBackend()
        let store = AIChatSecretStore(backend: backend, defaults: defaults)
        store.setKey("sk-x", for: .openAICompatible)
        XCTAssertEqual(store.key(for: .openAICompatible), "sk-x")

        store.setKey("", for: .openAICompatible)
        XCTAssertEqual(store.key(for: .openAICompatible), "")
        XCTAssertTrue(backend.storage.isEmpty)
        XCTAssertFalse(store.isUsingFallback(for: .openAICompatible))
    }

    func testTrimsWhitespaceAndNewlines() {
        let (name, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = AIChatSecretStore(backend: FakeSecretBackend(), defaults: defaults)
        store.setKey("  sk-trim\n", for: .anthropicMessages)
        XCTAssertEqual(store.key(for: .anthropicMessages), "sk-trim", "粘贴密钥时最容易带上换行")
    }

    /// 七槽互不相干：两条对话协议 + 五家搜索，键控 API 各存各的。
    func testStoresAllSevenSlotsSeparately() {
        let (name, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let backend = FakeSecretBackend()
        let store = AIChatSecretStore(backend: backend, defaults: defaults)

        store.setKey("sk-llm", for: .anthropicMessages)
        store.setKey("sk-oai", for: .openAICompatible)
        for (index, provider) in AppSettings.SearchToolProvider.allCases.enumerated() {
            store.setSearchKey("key-\(index)", for: provider)
        }

        XCTAssertEqual(store.key(for: .anthropicMessages), "sk-llm")
        XCTAssertEqual(store.key(for: .openAICompatible), "sk-oai")
        for (index, provider) in AppSettings.SearchToolProvider.allCases.enumerated() {
            XCTAssertEqual(store.searchKey(for: provider), "key-\(index)",
                           "\(provider.title) 的槽位不许串")
        }
        XCTAssertEqual(backend.storage.count, 7, "七份各占一个 account")
    }

    /// clear() 必须把**七份**密钥全清掉：两条协议 + 五家搜索。
    func testClearRemovesAllSevenSlots() {
        let (name, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let backend = FakeSecretBackend()
        let store = AIChatSecretStore(backend: backend, defaults: defaults)
        store.setKey("a", for: .anthropicMessages)
        store.setKey("b", for: .openAICompatible)
        for (index, provider) in AppSettings.SearchToolProvider.allCases.enumerated() {
            store.setSearchKey("key-\(index)", for: provider)
        }

        store.clear()
        XCTAssertEqual(store.key(for: .anthropicMessages), "")
        XCTAssertEqual(store.key(for: .openAICompatible), "")
        for provider in AppSettings.SearchToolProvider.allCases {
            XCTAssertEqual(store.searchKey(for: provider), "", "\(provider.title) 也要清掉")
        }
        XCTAssertTrue(backend.storage.isEmpty)
    }

    /// 每家的降级标记各自独立：一家降级不该让别家也显示「已降级」。
    func testEachSearchProviderHasItsOwnFallbackFlag() {
        let (name, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let backend = FakeSecretBackend()
        backend.failWrites = true
        let store = AIChatSecretStore(backend: backend, defaults: defaults)

        XCTAssertFalse(store.setSearchKey("tavily-key", for: .tavily))
        XCTAssertFalse(store.setSearchKey("serpapi-key", for: .serpapi))
        XCTAssertTrue(store.isUsingSearchFallback(for: .tavily))
        XCTAssertTrue(store.isUsingSearchFallback(for: .serpapi))
        XCTAssertFalse(store.isUsingSearchFallback(for: .exa), "没写过的家不该显示降级")
        XCTAssertEqual(store.searchKey(for: .tavily), "tavily-key", "降级后必须读得回来")

        // 后来钥匙串能写了：重写的那家退出降级，另一家不动
        backend.failWrites = false
        XCTAssertTrue(store.setSearchKey("tavily-key-2", for: .tavily))
        XCTAssertFalse(store.isUsingSearchFallback(for: .tavily))
        XCTAssertTrue(store.isUsingSearchFallback(for: .serpapi), "没动过的家保持原状")
    }

    /// 必填与可选之分不在存储层：清空就是「没填」。AnySearch 清空后照样参与（匿名），
    /// Tavily 清空后由链直接跳过 —— 存储只负责「存哪、怎么清」。
    func testClearingAKeyJustMeansNotFilled() {
        let (name, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let backend = FakeSecretBackend()
        let store = AIChatSecretStore(backend: backend, defaults: defaults)

        store.setSearchKey("as-search", for: .anySearch)
        store.setSearchKey("tvly-key", for: .tavily)
        XCTAssertEqual(store.searchKey(for: .anySearch), "as-search")
        XCTAssertEqual(store.searchKey(for: .tavily), "tvly-key")

        store.setSearchKey("", for: .tavily)
        XCTAssertEqual(store.searchKey(for: .tavily), "", "清空就是「没填」，不是错误")
        XCTAssertFalse(store.isUsingSearchFallback(for: .tavily))
        XCTAssertEqual(store.searchKey(for: .anySearch), "as-search", "别家不受影响")

        store.setSearchKey("", for: .anySearch)
        XCTAssertEqual(store.searchKey(for: .anySearch), "", "留空就是匿名，不是错误")
        XCTAssertTrue(backend.storage.isEmpty, "空值两处都清干净")
    }
}
