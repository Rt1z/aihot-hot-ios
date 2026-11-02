import Foundation

/// 订阅取数/解析的统一错误。
///
/// 比 `APIError` 多两个「要用户动手」的类别（Key 无效、余额不足），
/// 这样设置页和订阅页都能给出同一句可行动的中文，而不是把接口原文丢给用户。
struct SubscriptionError: Error, Equatable {

    enum Kind: String, Equatable {
        case offline
        case rateLimited
        case invalidConfig
        case invalidFeed
        case badKey
        case insufficientBalance
        case server
        case decoding
    }

    let kind: Kind
    let message: String
    let retryAfter: Int?

    init(kind: Kind, message: String, retryAfter: Int? = nil) {
        self.kind = kind
        self.message = message
        self.retryAfter = retryAfter
    }

    var noticeKind: HotTopicsStore.Notice.Kind {
        switch kind {
        case .offline:
            return .offline
        case .rateLimited:
            return .rateLimited
        default:
            return .failed
        }
    }

    /// 多个源同时失败时，优先展示「能让用户动手」的那条。
    var priority: Int {
        switch kind {
        case .badKey: return 6
        case .insufficientBalance: return 5
        case .invalidConfig: return 4
        case .rateLimited: return 3
        case .offline: return 2
        case .invalidFeed, .decoding: return 1
        case .server: return 0
        }
    }
}
