import CryptoKit
import Foundation

/// 腾讯云 API 3.0 签名（TC3-HMAC-SHA256）。
///
/// 元宝搜索没有「API Key」这种简单鉴权：必须用腾讯云的 SecretId + SecretKey
/// 对每个请求做签名。这里只做签名，发请求与解析在 `TencentWSAAPI`。
///
/// 纯函数（除了取当前时间），便于单测与镜像 25 对照。实现严格按腾讯云文档：
/// - 规范请求串里 `CanonicalHeaders` 本身以 `\n` 结尾，拼接时**再多一个 `\n`**
///   （官方示例的 `7019a55…` 哈希就是按这个形状算出来的；少一个换行会静默签错）。
/// - `Date` 必须取 **UTC+0** 的日期；用本地时区会在凌晨稳定失败。
/// - 参与签名的头部取 `content-type;host;x-tc-action`（与官方示例一致）。
enum TencentWSASignature {

    static let algorithm = "TC3-HMAC-SHA256"
    static let service = "wsa"
    static let host = "wsa.tencentcloudapi.com"
    static let action = "SearchPro"
    static let version = "2025-05-08"

    static let contentType = "application/json; charset=utf-8"
    static let signedHeaders = "content-type;host;x-tc-action"

    struct Signed: Equatable {
        let authorization: String
        let timestamp: Int
    }

    /// 给一次请求算好 `X-TC-Timestamp` 与 `Authorization`。
    static func sign(
        secretId: String,
        secretKey: String,
        body: Data,
        timestamp: Date = Date()
    ) -> Signed {
        let id = secretId.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let seconds = Int(timestamp.timeIntervalSince1970)
        let date = dateString(from: timestamp)

        let payloadHash = sha256Hex(body)
        let canonical = canonicalRequest(
            method: "POST",
            uri: "/",
            query: "",
            canonicalHeaders: canonicalHeaders(),
            signedHeaders: signedHeaders,
            payloadHash: payloadHash
        )
        let credentialScope = "\(date)/\(service)/tc3_request"
        let toSign = stringToSign(
            timestamp: seconds,
            credentialScope: credentialScope,
            canonicalRequest: canonical
        )
        let signature = signature(
            secretKey: key,
            date: date,
            service: service,
            stringToSign: toSign
        )

        let authorization = "\(algorithm) Credential=\(id)/\(credentialScope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"
        return Signed(authorization: authorization, timestamp: seconds)
    }

    // MARK: - 分步（测试与镜像逐段钉住）

    /// 参与签名的头部（值统一小写；按 key 的 ASCII 升序；**以 `\n` 结尾**）。
    static func canonicalHeaders() -> String {
        "content-type:\(contentType)\nhost:\(host)\nx-tc-action:\(action.lowercased())\n"
    }

    static func canonicalRequest(
        method: String,
        uri: String,
        query: String,
        canonicalHeaders: String,
        signedHeaders: String,
        payloadHash: String
    ) -> String {
        // 注意 canonicalHeaders 自带结尾换行，这里再拼一个 `\n` —— 官方示例的形状
        method + "\n"
            + uri + "\n"
            + query + "\n"
            + canonicalHeaders + "\n"
            + signedHeaders + "\n"
            + payloadHash
    }

    static func stringToSign(
        timestamp: Int,
        credentialScope: String,
        canonicalRequest: String
    ) -> String {
        algorithm + "\n"
            + String(timestamp) + "\n"
            + credentialScope + "\n"
            + sha256Hex(Data(canonicalRequest.utf8))
    }

    static func signature(
        secretKey: String,
        date: String,
        service: String,
        stringToSign: String
    ) -> String {
        let secretDate = hmacSHA256(key: Data(("TC3" + secretKey).utf8), message: Data(date.utf8))
        let secretService = hmacSHA256(key: secretDate, message: Data(service.utf8))
        let secretSigning = hmacSHA256(key: secretService, message: Data("tc3_request".utf8))
        return hex(hmacSHA256(key: secretSigning, message: Data(stringToSign.utf8)))
    }

    // MARK: - 基础

    static func sha256Hex(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    static func hmacSHA256(key: Data, message: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: symmetricKey))
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func dateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
