import XCTest
@testable import IslaKit

/// One renderer for a timecode, and it survives a podcast.
///
/// It used to be two identical copies, neither of which rolled into hours, so a
/// two-hour episode drew "120:45" into a 32pt gutter and came out as "120:…".
final class FormatTimeTests: XCTestCase {

    func testUnderAnHourIsMinutesAndSeconds() {
        XCTAssertEqual(formatTime(0), "0:00")
        XCTAssertEqual(formatTime(9), "0:09")
        XCTAssertEqual(formatTime(605), "10:05")
        XCTAssertEqual(formatTime(3599), "59:59")
    }

    func testAnHourAndOverRollsIntoHours() {
        XCTAssertEqual(formatTime(3600), "1:00:00")
        XCTAssertEqual(formatTime(7245), "2:00:45")
        XCTAssertEqual(formatTime(36000), "10:00:00")
    }

    func testNonsenseIsRefusedRatherThanDrawn() {
        XCTAssertEqual(formatTime(-1), "--:--")
        XCTAssertEqual(formatTime(.infinity), "--:--")
        XCTAssertEqual(formatTime(.nan), "--:--")
    }
}
