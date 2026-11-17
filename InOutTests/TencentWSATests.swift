import XCTest

@testable import InOut

/// 腾讯云元宝搜索：TC3 签名与响应解析。
///
/// 签名部分用腾讯云官方文档里的示例中间值钉住（规范请求串哈希
/// `7019a55…`、请求体哈希 `35e9c5…`）；最终签名另用固定测试密钥
/// （Python hmac 算出的期望值）钉住，避免只测「形状」。
///
/// 响应夹具 `tencent-wsa-search.json` **不是个人抓取**：它按官方 API 文档的
/// 示例响应改写（我们没有可用的 SecretId/SecretKey，无法真实调用），
/// 测试注释里写明了这一点。
final class TencentWSATests: XCTestCase {

    // MARK: - 签名

    /// 官方示例（CVM DescribeInstances）的请求体，注意保留**字面量** `\u` 转义
    /// （官方哈希 `35e9c5…` 是对转义后的字节算的，不是对 UTF-8 中文）。
    private let docsBody = "{\"Limit\": 1, \"Filters\": [{\"Values\": [\"\\u672a\\u547d\\u540d\"], \"Name\": \"instance-name\"}]}"

    private var docsCanonicalRequest: String {
        let headers = "content-type:application/json; charset=utf-8\n"
            + "host:cvm.tencentcloudapi.com\n"
            + "x-tc-action:describeinstances\n"
        return TencentWSASignature.canonicalRequest(
            method: "POST",
            uri: "/",
            query: "",
            canonicalHeaders: headers,
            signedHeaders: "content-type;host;x-tc-action",
            payloadHash: TencentWSASignature.sha256Hex(Data(docsBody.utf8))
        )
    }

    func testCanonicalRequestMatchesOfficialExample() {
        XCTAssertEqual(
            TencentWSASignature.sha256Hex(Data(docsBody.utf8)),
            "35e9c5b0e3ae67532d3c9f17ead6c90222632e5b1ff7f6e89887f1398934f064",
            "请求体哈希与官方示例不一致"
        )
        XCTAssertEqual(
            TencentWSASignature.sha256Hex(Data(docsCanonicalRequest.utf8)),
            "7019a55be8395899b900fb5564e4200d984910f34794a27cb3fb7d10ff6a1e84",
            "规范请求串哈希与官方示例不一致（注意 CanonicalHeaders 后要再多一个换行）"
        )
    }

    func testStringToSignMatchesOfficialExample() {
        let value = TencentWSASignature.stringToSign(
            timestamp: 1551113065,
            credentialScope: "2019-02-25/cvm/tc3_request",
            canonicalRequest: docsCanonicalRequest
        )
        XCTAssertEqual(
            value,
            "TC3-HMAC-SHA256\n1551113065\n2019-02-25/cvm/tc3_request\n"
                + "7019a55be8395899b900fb5564e4200d984910f34794a27cb3fb7d10ff6a1e84"
        )
    }

    /// 官方示例的 SecretKey 是打码的，最终签名无法复现；这里用固定测试密钥，
    /// 期望值由 Python hmac 同算法算出 —— 两边算法不一致时立刻红。
    func testSignatureMatchesReferenceVector() {
        let toSign = TencentWSASignature.stringToSign(
            timestamp: 1551113065,
            credentialScope: "2019-02-25/cvm/tc3_request",
            canonicalRequest: docsCanonicalRequest
        )
        XCTAssertEqual(
            TencentWSASignature.signature(
                secretKey: "test-secret-key",
                date: "2019-02-25",
                service: "cvm",
                stringToSign: toSign
            ),
            "99f8790e445f249f002afeffee9d8517ca11199c00cc10167fa4a443ba2c1d5b"
        )
    }

    func testWSAAuthorizationUsesItsOwnHostActionAndVersion() {
        let body = Data(#"{"Query":"tencent"}"#.utf8)
        let signed = TencentWSASignature.sign(
            secretId: "AKID-test",
            secretKey: "secret-test",
            body: body,
            timestamp: Date(timeIntervalSince1970: 1_551_113_065)
        )

        XCTAssertEqual(signed.timestamp, 1_551_113_065)
        XCTAssertEqual(
            signed.authorization,
            "TC3-HMAC-SHA256 Credential=AKID-test/2019-02-25/wsa/tc3_request, "
                + "SignedHeaders=content-type;host;x-tc-action, "
                + "Signature=21c3875fdf63e3730e7634a27ab6638bbbd36514a2cd1d8063f7a714692779b1"
        )
    }

    func testDateUsesUTCNotLocalTime() {
        // 东八区 2019-02-26 00:44:25 = UTC 2019-02-25 16:44:25
        let date = Date(timeIntervalSince1970: 1_551_113_065)
        XCTAssertEqual(TencentWSASignature.dateString(from: date), "2019-02-25")
    }

    // MARK: - 响应解析

    func testParsesSearchFixture() throws {
        let data = try Fixture.data("tencent-wsa-search", ext: "json")
        guard case .success(let text) = TencentWSAResponseParser.parse(data: data, httpStatus: 200) else {
            return XCTFail("应该解析成功")
        }

        XCTAssertTrue(text.contains("标准版"))
        XCTAssertTrue(text.contains("人工智能创新加速我国产业转型升级"))
        XCTAssertTrue(text.contains("https://www.cac.gov.cn/2025-02/26/c_1742272852299173.htm"))
        XCTAssertTrue(text.contains("中国网信网"))
        XCTAssertTrue(text.contains("相关性 0.85"))
        XCTAssertTrue(text.contains("第二条摘要"))
    }

    func testAuthErrorIsActionable() throws {
        let data = try Fixture.data("tencent-wsa-error", ext: "json")
        guard case .failure(let message) = TencentWSAResponseParser.parse(data: data, httpStatus: 401) else {
            return XCTFail("鉴权错误必须失败")
        }
        XCTAssertTrue(message.contains("鉴权失败"))
        XCTAssertTrue(message.contains("SecretId / SecretKey"))
        XCTAssertTrue(message.contains("ed93f3cb-f35e-473f-b9f3-0d451b8b79c6"))
    }

    func testEmptyPagesUsesServerMessage() {
        let data = Data(#"{"Response":{"Pages":[],"Version":"lite","Msg":"hit black query","RequestId":"r"}}"#.utf8)
        guard case .success(let text) = TencentWSAResponseParser.parse(data: data, httpStatus: 200) else {
            return XCTFail("空结果不是错误")
        }
        XCTAssertTrue(text.contains("极速版"))
        XCTAssertTrue(text.contains("hit black query"))
    }

    func testBadPageElementIsSkippedNotFatal() throws {
        let valid = #"{"title":"好的一条","url":"https://example.com/ok","passage":"摘要"}"#
        let envelope: [String: Any] = [
            "Response": [
                "Pages": ["not-json", valid],
                "Version": "standard",
                "RequestId": "r",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)

        guard case .success(let text) = TencentWSAResponseParser.parse(data: data, httpStatus: 200) else {
            return XCTFail("一条坏数据不该让整次搜索失败")
        }
        XCTAssertTrue(text.contains("好的一条"))
        XCTAssertFalse(text.contains("not-json"))
    }

    func testMalformedResponseIsFriendly() {
        guard case .failure(let message) = TencentWSAResponseParser.parse(data: Data("oops".utf8), httpStatus: 200) else {
            return XCTFail("无法解析必须失败")
        }
        XCTAssertTrue(message.contains("无法解析"))
    }

    func testConfigNeedsBothKeys() {
        XCTAssertFalse(TencentWSAConfig(secretId: "id", secretKey: "").isConfigured)
        XCTAssertFalse(TencentWSAConfig(secretId: "", secretKey: "key").isConfigured)
        XCTAssertTrue(TencentWSAConfig(secretId: "id", secretKey: "key").isConfigured)
    }
}
