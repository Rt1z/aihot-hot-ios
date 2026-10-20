import XCTest

@testable import AIHOT

/// 「复制运行诊断」的两件事：地址脱敏（安全边界）与正文里该有的现场。
/// 地址规则同时由 `tools/logic_tests.py` 的镜像 19 钉住。
final class DiagnosticReportTests: XCTestCase {

    // MARK: - hostOnly

    func testHostOnlyDropsPathQueryAndFragment() {
        XCTAssertEqual(
            DiagnosticReport.hostOnly("https://api.anthropic.com/v1/messages?api_key=SECRET#x"),
            "https://api.anthropic.com"
        )
        XCTAssertEqual(
            DiagnosticReport.hostOnly("https://serpapi.com/search?engine=google&q=ping"),
            "https://serpapi.com"
        )
    }

    func testHostOnlyDropsCredentialsButKeepsPort() {
        XCTAssertEqual(
            DiagnosticReport.hostOnly("https://user:pass@relay.example.com:8443/v1"),
            "https://relay.example.com:8443"
        )
    }

    func testHostOnlyLowercasesSchemeOnly() {
        XCTAssertEqual(DiagnosticReport.hostOnly("HTTP://Example.com/x"), "http://Example.com")
    }

    func testHostOnlyTrimsSurroundingWhitespace() {
        XCTAssertEqual(
            DiagnosticReport.hostOnly("  https://relay.example.com/v1 \n"),
            "https://relay.example.com"
        )
    }

    func testHostOnlyKeepsIPv6Literal() {
        XCTAssertEqual(DiagnosticReport.hostOnly("https://[::1]:8080/x"), "https://[::1]:8080")
    }

    func testHostOnlyRejectsUnparseableInput() {
        XCTAssertEqual(DiagnosticReport.hostOnly(""), "（无法解析）")
        XCTAssertEqual(DiagnosticReport.hostOnly("   "), "（无法解析）")
        XCTAssertEqual(DiagnosticReport.hostOnly("api.anthropic.com"), "（无法解析）", "缺协议")
        XCTAssertEqual(DiagnosticReport.hostOnly("https://"), "（无法解析）", "缺主机")
        XCTAssertEqual(DiagnosticReport.hostOnly("ftp://host/x"), "（无法解析）", "只认 http(s)")
        XCTAssertEqual(DiagnosticReport.hostOnly("https://user@/x"), "（无法解析）", "@ 后面没有主机")
    }

    // MARK: - make

    func testMakeNeverEchoesTheURLEvenWhenItCarriesASecret() {
        var input = DiagnosticReport.Input()
        input.chatBaseURL = "https://serpapi.com/search?api_key=SECRET"
        let text = DiagnosticReport.make(input)
        XCTAssertFalse(text.contains("SECRET"), "诊断里绝不能出现 Key")
        XCTAssertFalse(text.contains("api_key="), "查询串必须整段丢掉")
        XCTAssertTrue(text.contains("https://serpapi.com（仅主机名）"))
    }

    func testMakeCarriesTheFieldsNeededToDiagnose() {
        var input = DiagnosticReport.Input()
        input.appVersion = "1.0"
        input.build = "42"
        input.systemVersion = "16.4"
        input.device = "iPhone15,2"
        input.hotCount = 10
        input.hotUpdated = "2026-10-20 15:30"
        input.favoritesCount = 3
        input.reportLines = ["周报：最新 2026-W42 · 往期 11 条 · 更新 2026-10-19 10:00 · 提示 无"]
        input.chatProtocol = "Anthropic Messages"
        input.chatModel = "claude-sonnet-5-5"
        input.keyStorage = "对话密钥在钥匙串；搜索密钥无降级"
        input.searchOrder = "AnySearch → Tavily"
        input.searchDisabled = "Serper"
        input.searchKeys = "AnySearch 已填 · Tavily 未填"

        let text = DiagnosticReport.make(input)
        for expected in [
            "版本：1.0 (42)",
            "系统：iOS 16.4",
            "设备：iPhone15,2",
            "条数：10",
            "2026-10-20 15:30",
            "条数：3",
            "2026-W42",
            "Anthropic Messages",
            "claude-sonnet-5-5",
            "对话密钥在钥匙串",
            "AnySearch → Tavily",
            "Serper",
            "搜索密钥：AnySearch 已填 · Tavily 未填",
        ] {
            XCTAssertTrue(text.contains(expected), "缺了「\(expected)」")
        }
    }

    func testMakeSaysWhenThereIsNoReportDataYet() {
        let text = DiagnosticReport.make(DiagnosticReport.Input())
        XCTAssertTrue(text.contains("暂无数据"))
    }
}
