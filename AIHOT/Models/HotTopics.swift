import Foundation

// MARK: - 时间解析
//
// 接口返回的是 ISO8601 带毫秒（2026-10-12T01:40:20.000Z），
// JSONDecoder 内置的 .iso8601 **不接受**小数秒，必须自己来。
// 同时兼容不带毫秒与带 +08:00 偏移的写法。

enum AIHOTDate {

    private static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let encoder: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ string: String) -> Date? {
        withFractionalSeconds.date(from: string) ?? plain.date(from: string)
    }

    static func string(from date: Date) -> String {
        encoder.string(from: date)
    }
}

extension JSONDecoder {

    /// 本项目统一的解码器：ISO8601 + 小数秒容错。
    static var aihot: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = AIHOTDate.parse(raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "无法解析时间字符串：\(raw)"
            )
        }
        return decoder
    }
}

extension JSONEncoder {

    /// 与解码器对称，用于本地快照落盘。
    static var aihot: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(AIHOTDate.string(from: date))
        }
        return encoder
    }
}

// MARK: - 内容接口模型（/api/v1/hot-topics）

struct HotTopicsResponse: Codable {
    let schemaVersion: Int?
    let count: Int?
    let items: [HotTopic]
}

struct HotTopic: Codable, Identifiable, Hashable {
    let rank: Int
    let id: String
    let title: String
    let source: Source?
    let links: Links?
    let sourceCount: Int?
    let signalCount: Int?
    let participantCount: Int?
    let sourceNames: [String]?
    let latestAt: Date?
}

struct Source: Codable, Hashable {
    /// 用可选值而不是必填：schema 级是否 required 无法证实，
    /// 万一某条只有 firstParty 没有 name，也不该让整张榜单一解码就白屏。
    let name: String?
    let firstParty: Bool?
}

struct Links: Codable, Hashable {
    let aihot: String?
    let original: String?
    let story: String?
}
