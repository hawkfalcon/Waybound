import XCTest
@testable import Waybound

final class TransitRouteNamingTests: XCTestCase {

    func testRouteNumberRequiresADigit() {
        XCTAssertEqual(TransitRouteNaming.routeNumber(shortName: "6"), "6")
        XCTAssertEqual(TransitRouteNaming.routeNumber(shortName: "11"), "11")
        XCTAssertEqual(TransitRouteNaming.routeNumber(shortName: "1A"), "1A")
        XCTAssertNil(TransitRouteNaming.routeNumber(shortName: "Lompoc"))
        XCTAssertNil(TransitRouteNaming.routeNumber(shortName: "Midday"))
        XCTAssertNil(TransitRouteNaming.routeNumber(shortName: nil))
    }

    func testDisplayNamePrefersLongNameWhenShortNameIsANumber() {
        XCTAssertEqual(
            TransitRouteNaming.displayName(shortName: "6", longName: "Pismo Beach"),
            "Pismo Beach"
        )
        XCTAssertEqual(
            TransitRouteNaming.displayName(shortName: "6", longName: "6"),
            "6"
        )
        XCTAssertEqual(
            TransitRouteNaming.displayName(shortName: "Lompoc", longName: "Lompoc"),
            "Lompoc"
        )
        XCTAssertEqual(
            TransitRouteNaming.displayName(
                shortName: nil,
                longName: "Santa Barbara Downtown"
            ),
            "Santa Barbara Downtown"
        )
        XCTAssertEqual(
            TransitRouteNaming.displayName(shortName: nil, longName: nil),
            "Unknown Route"
        )
        XCTAssertEqual(
            TransitRouteNaming.displayName(shortName: "?", longName: "X"),
            "X"
        )
    }

    func testFullDisplayNameJoinsNumberWithEmDash() {
        XCTAssertEqual(
            TransitRouteNaming.fullDisplayName(
                shortName: "6",
                longName: "Pismo Beach"
            ),
            "6 — Pismo Beach"
        )
        XCTAssertEqual(
            TransitRouteNaming.fullDisplayName(shortName: "6", longName: "6"),
            "6"
        )
    }
}
