import XCTest

@testable import AIHOT

/// Tab 角标的纯判断（镜像 19 的 Swift 侧权威）：
/// 只看期号；任一侧缺失都不算未读（新装用户不挂角标）。
final class ReportUnreadTests: XCTestCase {

    func testMissingEitherSideIsNeverUnread() {
        XCTAssertFalse(ReportUnread.isUnread(latest: nil, lastSeen: nil))
        XCTAssertFalse(ReportUnread.isUnread(latest: "2026-W42", lastSeen: nil), "还没有基线")
        XCTAssertFalse(ReportUnread.isUnread(latest: nil, lastSeen: "2026-W41"), "还没有最新一期")
    }

    func testSamePeriodIsRead() {
        XCTAssertFalse(ReportUnread.isUnread(latest: "2026-W42", lastSeen: "2026-W42"))
    }

    func testDifferentPeriodIsUnread() {
        XCTAssertTrue(ReportUnread.isUnread(latest: "2026-W42", lastSeen: "2026-W41"))
        XCTAssertTrue(ReportUnread.isUnread(latest: "2026-W41", lastSeen: "2026-W42"), "只看是否相同")
    }
}
