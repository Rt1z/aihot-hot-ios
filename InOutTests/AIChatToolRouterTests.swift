import XCTest

@testable import InOut

/// 工具路由的结构性行为：未知工具、缺参数、没配密钥时都不该发网络。
final class AIChatToolRouterTests: XCTestCase {

    private func router() -> AIChatToolRouter {
        AIChatToolRouter(
            search: TencentWSARunner(
                config: TencentWSAConfig(secretId: "", secretKey: "")
            ),
            reader: WebPageReader()
        )
    }

    private func call(_ name: String, _ arguments: String) -> AIChatToolCall {
        AIChatToolCall(
            index: 0,
            id: "test",
            name: name,
            argumentsJSON: arguments
        )
    }

    func testUnknownToolIsRejectedWithoutNetwork() async {
        let result = await router().execute(call: call("nope", "{}"))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("没有这个工具"))
    }

    func testSearchWithoutQueryIsAMissingArgument() async {
        let result = await router().execute(call: call(AIChatToolName.webSearch, "{}"))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("缺少必需的参数"))
    }

    func testReadURLWithoutURLIsAMissingArgument() async {
        let result = await router().execute(call: call(AIChatToolName.readURL, "{}"))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("缺少必需的参数"))
    }

    /// 有 query 但没配腾讯云密钥：在发请求之前就返回可执行的配置提示。
    func testSearchWithoutCredentialsExplainsWhereToConfigure() async {
        let result = await router().execute(
            call: call(AIChatToolName.webSearch, #"{"query":"腾讯云"}"#)
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("还没配置腾讯云元宝搜索"))
        XCTAssertTrue(result.text.contains("SecretId"))
        XCTAssertTrue(result.text.contains("SecretKey"))
    }
}
