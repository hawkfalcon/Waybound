import XCTest
@testable import Waybound

final class TransitTimeTests: XCTestCase {

    func testServiceMinutesRoundsSecondsAtThirty() {
        XCTAssertEqual(TransitTime.serviceMinutes(from: "08:09:00"), 489)
        XCTAssertEqual(TransitTime.serviceMinutes(from: "08:09:14"), 489)
        XCTAssertEqual(TransitTime.serviceMinutes(from: "08:09:30"), 490)
    }

    func testServiceMinutesKeepsAfterMidnightHours() {
        XCTAssertEqual(TransitTime.serviceMinutes(from: "25:10:00"), 1_510)
    }

    func testServiceMinutesRoundsLastSecondOfDayToNextMidnight() {
        // 23:59:59 → 23×60 + 59, plus one because seconds ≥ 30.
        XCTAssertEqual(TransitTime.serviceMinutes(from: "23:59:59"), 1_440)
    }

    func testServiceMinutesAcceptsHourMinuteOnly() {
        XCTAssertEqual(TransitTime.serviceMinutes(from: "08:09"), 489)
    }

    func testServiceMinutesRejectsMissingAndJunk() {
        XCTAssertNil(TransitTime.serviceMinutes(from: nil))
        XCTAssertNil(TransitTime.serviceMinutes(from: ""))
        XCTAssertNil(TransitTime.serviceMinutes(from: "junk"))
    }

    func testDateParsesInternetDateTimeAndFractionalSeconds() {
        XCTAssertNotNil(TransitTime.date(from: "2010-01-01T00:00:00Z"))
        XCTAssertNotNil(TransitTime.date(from: "2010-01-01T00:00:00.123Z"))
        XCTAssertNil(TransitTime.date(from: "junk"))
        XCTAssertNil(TransitTime.date(from: nil))
        XCTAssertNil(TransitTime.date(from: ""))
    }
}
