import Foundation

/// 腾讯云元宝搜索的凭据。
struct TencentWSAConfig: Equatable {
    let secretId: String
    let secretKey: String

    var isConfigured: Bool {
        !secretId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum WSASearchOutcome: Equatable {
    case success(text: String)
    case failure(String)
}

/// 腾讯云「元宝搜索」的唯一接口：`SearchPro`。
///
/// 注意：这个产品**没有**独立的「读网页」接口，所以 App 的 `read_url` 由
/// `WebPageReader` 直接抓取，不经过腾讯云。搜索请求需要 TC3 签名（见
/// `TencentWSASignature`），因此设置里要填 SecretId + SecretKey，而不是
/// 一个简单的 API Key。
final class TencentWSAAPI: @unchecked Sendable {

    static let shared = TencentWSAAPI()

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session = session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    func search(config: TencentWSAConfig, query: String) async -> WSASearchOutcome {
        guard config.isConfigured else {
            return .failure("还没配置腾讯云元宝搜索：到「设置 → AI 对话 → 联网搜索」填 SecretId 和 SecretKey。")
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure("搜索词是空的。")
        }

        guard let body = try? JSONSerialization.data(withJSONObject: ["Query": trimmed]) else {
            return .failure("请求构造失败。")
        }
        guard let url = URL(string: "https://\(TencentWSASignature.host)/") else {
            return .failure("接口地址不可用。")
        }

        let signed = TencentWSASignature.sign(
            secretId: config.secretId,
            secretKey: config.secretKey,
            body: body
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(TencentWSASignature.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(TencentWSASignature.action, forHTTPHeaderField: "X-TC-Action")
        request.setValue(TencentWSASignature.version, forHTTPHeaderField: "X-TC-Version")
        request.setValue(String(signed.timestamp), forHTTPHeaderField: "X-TC-Timestamp")
        request.setValue(signed.authorization, forHTTPHeaderField: "Authorization")
        request.setValue(
            "InOut-iOS (personal use; +https://aihot.news)",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return TencentWSAResponseParser.parse(data: data, httpStatus: status)
        } catch let error as URLError where error.code == .cancelled {
            return .failure("请求已取消。")
        } catch let error as URLError where error.code == .notConnectedToInternet {
            return .failure("网络不可用，稍后再试。")
        } catch {
            return .failure("网络错误：\(error.localizedDescription)")
        }
    }
}

/// 响应解析与格式化（纯函数，单测用）。
///
/// 元宝搜索的 `Pages` 是 **JSON 字符串数组**，不是一个对象数组 —— 每个元素
/// 还要再解一次。解析单条失败只跳过那一条，不让整次搜索失败。
enum TencentWSAResponseParser {

    struct Envelope: Decodable {
        let response: Response

        enum CodingKeys: String, CodingKey {
            case response = "Response"
        }

        struct Response: Decodable {
            let pages: [String]?
            let version: String?
            let msg: String?
            let requestId: String?
            let error: Failure?

            enum CodingKeys: String, CodingKey {
                case pages = "Pages"
                case version = "Version"
                case msg = "Msg"
                case requestId = "RequestId"
                case error = "Error"
            }

            struct Failure: Decodable {
                let code: String?
                let message: String?

                enum CodingKeys: String, CodingKey {
                    case code = "Code"
                    case message = "Message"
                }
            }
        }
    }

    struct Page: Decodable {
        let title: String?
        let url: String?
        let date: String?
        let passage: String?
        let content: String?
        let site: String?
        let score: Double?
    }

    static func parse(data: Data, httpStatus: Int) -> WSASearchOutcome {
        guard !data.isEmpty else {
            return .failure("腾讯云元宝搜索没有返回内容（HTTP \(httpStatus)）。")
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return .failure("腾讯云元宝搜索返回了无法解析的内容（HTTP \(httpStatus)）。")
        }

        let response = envelope.response
        if let error = response.error {
            return .failure(friendlyError(
                code: error.code,
                message: error.message,
                requestId: response.requestId
            ))
        }

        guard (200...299).contains(httpStatus) else {
            return .failure("腾讯云元宝搜索请求失败（HTTP \(httpStatus)）。")
        }

        let pages = (response.pages ?? []).compactMap { raw -> Page? in
            guard let data = raw.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(Page.self, from: data)
        }

        return .success(text: format(pages: pages, version: response.version, msg: response.msg))
    }

    static func format(pages: [Page], version: String?, msg: String?) -> String {
        var lines: [String] = []
        lines.append("腾讯云元宝搜索（\(versionLabel(version))）：")

        var index = 0
        for page in pages {
            guard let title = cleaned(page.title), let url = cleaned(page.url) else { continue }
            index += 1
            lines.append("\(index). \(title)")
            lines.append("   \(url)")

            var meta: [String] = []
            if let site = cleaned(page.site) { meta.append(site) }
            if let date = cleaned(page.date) { meta.append(date) }
            if let score = page.score {
                meta.append(String(format: "相关性 %.2f", score))
            }
            if !meta.isEmpty {
                lines.append("   " + meta.joined(separator: " · "))
            }

            let passage = cleaned(page.passage)
            if let passage {
                lines.append("   " + passage)
            }
            if let content = cleaned(page.content), content != passage {
                lines.append("   " + content)
            }
            lines.append("")
        }

        if index == 0 {
            if let msg = cleaned(msg) {
                lines.append(msg)
            } else {
                lines.append("没有返回结果。")
            }
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 错误码 → 能照着做的中文。服务器的原文附在后面，不吞掉。
    static func friendlyError(code: String?, message: String?, requestId: String?) -> String {
        let value = code ?? "UnknownError"
        let detail = cleaned(message) ?? "（服务端没有给出说明）"
        let suffix = cleaned(requestId).map { "（RequestId: \($0)）" } ?? ""

        let text: String
        switch value {
        case "AuthFailure.InvalidSecretId",
             "AuthFailure.SecretIdNotFound",
             "AuthFailure.SignatureFailure",
             "AuthFailure.SignatureExpire",
             "AuthFailure.InvalidAuthorization",
             "AuthFailure.TokenFailure":
            text = "鉴权失败：到「设置 → AI 对话 → 联网搜索」核对 SecretId / SecretKey，"
                + "并确认密钥属于已开通元宝搜索的账号。服务端：\(detail)"
        case "UnauthorizedOperation", "AuthFailure.UnauthorizedOperation":
            text = "账号没有元宝搜索权限：先在腾讯云控制台开通产品，并确认子账号已授权。服务端：\(detail)"
        case "RequestLimitExceeded", "LimitExceeded":
            text = "腾讯云元宝搜索请求过于频繁或超出配额，稍后再试。服务端：\(detail)"
        case "ServiceUnavailable", "InternalError":
            text = "腾讯云元宝搜索暂时不可用，稍后再试。服务端：\(detail)"
        case "InvalidParameter", "InvalidParameterValue", "MissingParameter":
            text = "请求参数有问题：\(detail)"
        default:
            text = "\(value)：\(detail)"
        }
        return text + suffix
    }

    private static func versionLabel(_ version: String?) -> String {
        switch version?.lowercased() {
        case "lite": return "极速版"
        case "standard": return "标准版"
        case "flagship": return "旗舰版"
        case .some(let raw): return raw
        case nil: return "标准版"
        }
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        let value = RegexUtil.replace(#"\s+"#, in: raw, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
