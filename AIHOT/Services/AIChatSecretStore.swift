import Foundation
import Security

/// 密钥的存放后端。抽成协议是为了让单测用一个假后端，不去碰真钥匙串。
protocol AIChatSecretBackend {
    func read(account: String) -> String?
    /// 返回 false 表示「写不进去」——调用方据此降级。
    func write(_ value: String, account: String) -> Bool
    func delete(account: String)
}

/// API Key 的存放处。三份：两条对话协议各一份，AnySearch 一份（那份可选）。
///
/// 默认走 Keychain（`Security` 框架，**不需要 entitlement**）。但侧载签名
/// （AltStore + 免费 Apple ID）在个别配置下会让 Keychain 直接返回
/// `errSecMissingEntitlement (-34018)` —— 那种环境我没法预演，所以写入真失败时
/// 退回 UserDefaults，**并且让界面能说明「已降级」**。静默降级密钥存储是不能接受的。
///
/// 两个必须分清的错误码：
/// - `errSecItemNotFound (-25300)`：只是「还没存过」，**不是**失败。
///   判错的话每次首次启动都会往 UserDefaults 里写一份空的。
/// - 其它（如 -34018）：才算失败，走兜底。
final class AIChatSecretStore {

    static let shared = AIChatSecretStore()

    private let backend: AIChatSecretBackend
    private let defaults: UserDefaults

    init(backend: AIChatSecretBackend = KeychainSecretBackend(), defaults: UserDefaults = .standard) {
        self.backend = backend
        self.defaults = defaults
    }

    // MARK: - 对话协议

    func key(for chatProtocol: AIChatProtocol) -> String {
        read(account: Self.account(for: chatProtocol))
    }

    /// 返回 true 表示写进了 Keychain；false 表示降级到了 UserDefaults（界面要说明）。
    @discardableResult
    func setKey(_ value: String, for chatProtocol: AIChatProtocol) -> Bool {
        write(value, account: Self.account(for: chatProtocol))
    }

    func isUsingFallback(for chatProtocol: AIChatProtocol) -> Bool {
        usedFallback(account: Self.account(for: chatProtocol))
    }

    // MARK: - AnySearch（可选）

    func anySearchKey() -> String {
        read(account: Self.anySearchAccount)
    }

    @discardableResult
    func setAnySearchKey(_ value: String) -> Bool {
        write(value, account: Self.anySearchAccount)
    }

    func isUsingAnySearchFallback() -> Bool {
        usedFallback(account: Self.anySearchAccount)
    }

    func clear() {
        for chatProtocol in AIChatProtocol.allCases {
            clearAccount(Self.account(for: chatProtocol))
        }
        clearAccount(Self.anySearchAccount)
    }

    // MARK: - 内部

    private func read(account: String) -> String {
        if let stored = backend.read(account: account), !stored.isEmpty {
            return stored
        }
        // 之前降级时可能存在兜底里
        return defaults.string(forKey: Self.fallbackKey(account)) ?? ""
    }

    @discardableResult
    private func write(_ value: String, account: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            clearAccount(account)
            return true
        }

        if backend.write(trimmed, account: account) {
            // 写成功就把兜底那份清掉，避免两处不一致
            defaults.removeObject(forKey: Self.fallbackKey(account))
            return true
        }

        defaults.set(trimmed, forKey: Self.fallbackKey(account))
        return false
    }

    private func usedFallback(account: String) -> Bool {
        guard let stored = defaults.string(forKey: Self.fallbackKey(account)) else { return false }
        return !stored.isEmpty
    }

    private func clearAccount(_ account: String) {
        backend.delete(account: account)
        defaults.removeObject(forKey: Self.fallbackKey(account))
    }

    private static let anySearchAccount = "aihot.anysearch"

    private static func account(for chatProtocol: AIChatProtocol) -> String {
        switch chatProtocol {
        case .anthropicMessages: return "aihot.aichat.anthropic"
        case .openAICompatible: return "aihot.aichat.openai"
        }
    }

    private static func fallbackKey(_ account: String) -> String {
        AppSettings.aiChatFallbackSecretPrefix + account
    }
}

/// 真钥匙串实现。
struct KeychainSecretBackend: AIChatSecretBackend {

    private let service = "dev.local.aihot.hot.aichat"

    func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        // -25300（还没存过）与真失败在这里都是「没有值」，返回 nil 即可；
        // 真正需要区分失败的是写入（见下面）。
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func write(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // 只在本机、解锁过一次之后可读，且不进备份
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        // 先试更新：条目已存在时 SecItemAdd 会返回 -25299（duplicate），
        // 那样第二次保存就会静默失败。
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus != errSecItemNotFound { return false }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
