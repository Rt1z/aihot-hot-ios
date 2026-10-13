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

    /// clear() 必须把**四份**密钥全清掉：两条协议 + AnySearch + Tavily。
    func testClearRemovesEverything() {
        let (name, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let backend = FakeSecretBackend()
        let store = AIChatSecretStore(backend: backend, defaults: defaults)
        store.setKey("a", for: .anthropicMessages)
        store.setKey("b", for: .openAICompatible)
        store.setAnySearchKey("c")
        store.setTavilyKey("d")

        store.clear()
        XCTAssertEqual(store.key(for: .anthropicMessages), "")
        XCTAssertEqual(store.key(for: .openAICompatible), "")
        XCTAssertEqual(store.anySearchKey(), "")
        XCTAssertEqual(store.tavilyKey(), "")
        XCTAssertTrue(backend.storage.isEmpty)
    }

    /// Tavily 的 Key 是独立的一份，且**必填**（没有匿名模式）——
    /// 与 AnySearch 那份互不相干，也不随协议切换串味。
    func testTavilyKeyIsSeparateAndRequired() {
        let (name, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let backend = FakeSecretBackend()
        let store = AIChatSecretStore(backend: backend, defaults: defaults)

        store.setKey("sk-llm", for: .anthropicMessages)
        store.setAnySearchKey("as-search")
        store.setTavilyKey("tvly-key")

        XCTAssertEqual(store.tavilyKey(), "tvly-key")
        XCTAssertEqual(store.anySearchKey(), "as-search")
        XCTAssertEqual(store.key(for: .anthropicMessages), "sk-llm", "三份互不相干")
        XCTAssertFalse(store.isUsingTavilyFallback())

        store.setTavilyKey("")
        XCTAssertEqual(store.tavilyKey(), "", "清空就是「没填」，让工具直接回错而不是发一个会 401 的请求")

        store.clear()
        XCTAssertEqual(store.tavilyKey(), "")
        XCTAssertTrue(backend.storage.isEmpty)
    }

    /// AnySearch 的 Key 是独立的一份，而且**可选**：清空之后搜索照样能用（匿名）。
    func testAnySearchKeyIsSeparateAndOptional() {
        let (name, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let backend = FakeSecretBackend()
        let store = AIChatSecretStore(backend: backend, defaults: defaults)

        store.setKey("sk-llm", for: .anthropicMessages)
        store.setAnySearchKey("as-search")
        XCTAssertEqual(store.key(for: .anthropicMessages), "sk-llm")
        XCTAssertEqual(store.anySearchKey(), "as-search")

        store.setAnySearchKey("")
        XCTAssertEqual(store.anySearchKey(), "", "留空就是匿名，不是错误")

        store.clear()
        XCTAssertEqual(store.key(for: .anthropicMessages), "")
        XCTAssertEqual(store.anySearchKey(), "")
    }
}
