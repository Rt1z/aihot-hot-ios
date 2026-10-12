import XCTest

@testable import AIHOT

final class RelativeTimeTests: XCTestCase {

    private func date(_ iso: String) throws -> Date {
        try XCTUnwrap(AIHOTDate.parse(iso), "无法解析测试时间 \(iso)")
    }

    func testRelativeScale() throws {
        let now = try date("2026-10-12T10:00:00Z")

        XCTAssertEqual(RelativeTime.relative(now.addingTimeInterval(-5), now: now), "刚刚")
        XCTAssertEqual(RelativeTime.relative(now.addingTimeInterval(-59), now: now), "刚刚")
        XCTAssertEqual(RelativeTime.relative(now.addingTimeInterval(-300), now: now), "5 分钟前")
        XCTAssertEqual(RelativeTime.relative(now.addingTimeInterval(-3 * 3600), now: now), "3 小时前")
        XCTAssertEqual(RelativeTime.relative(now.addingTimeInterval(-2 * 86_400), now: now), "2 天前")
    }

    func testFallsBackToCalendarDates() throws {
        let now = try date("2026-10-12T10:00:00Z")

        XCTAssertEqual(RelativeTime.relative(try date("2026-08-01T04:00:00Z"), now: now), "8月1日")
        XCTAssertEqual(RelativeTime.relative(try date("2025-08-01T04:00:00Z"), now: now), "2025年8月1日")
    }

    func testHandlesFutureTimestampsGracefully() throws {
        let now = try date("2026-10-12T10:00:00Z")
        XCTAssertEqual(RelativeTime.relative(now.addingTimeInterval(120), now: now), "刚刚")
    }

    func testBeijingTimeFormatting() throws {
        // 02:35Z == 北京时间 10:35，和官网显示一致
        XCTAssertEqual(RelativeTime.absoluteShort(try date("2026-10-12T02:35:00Z")), "10月12日 10:35")
    }

    func testNilDateProducesEmptyString() {
        XCTAssertEqual(RelativeTime.relative(nil), "")
        XCTAssertEqual(RelativeTime.absoluteShort(nil), "")
    }
}
