import XCTest

@testable import WayboundCore

final class TransitTextTests: XCTestCase {
    func testIdentityTextFoldsCaseDiacriticsAndSeparators() {
        XCTAssertEqual(
            TransitText.normalizedIdentityText("MTD (Santa Barbara)"),
            "mtdsantabarbara"
        )
        XCTAssertEqual(
            TransitText.normalizedIdentityText("mtd — santa barbara"),
            "mtdsantabarbara"
        )
        XCTAssertEqual(
            TransitText.normalizedIdentityText("Café Único"),
            "cafeunico"
        )
    }

    func testAgencyNameIsIdentityFold() {
        XCTAssertEqual(
            TransitText.normalizedAgencyName("VCTC Intercity"),
            "vctcintercity"
        )
    }

    func testStopPlaceNameDropsLandmarkQualifiersAndConnectors() {
        XCTAssertEqual(
            TransitText.normalizedStopPlaceName(
                "State at Anapamu (SB Library)"
            ),
            "state anapamu"
        )
        XCTAssertEqual(
            TransitText.normalizedStopPlaceName("State and Anapamu"),
            "state anapamu"
        )
        XCTAssertEqual(
            TransitText.normalizedStopPlaceName("Hollister near Kellogg"),
            "hollister kellogg"
        )
    }

    func testDirectionTerms() {
        XCTAssertEqual(
            TransitText.stopDirectionTerms(
                in: "Cathedral Oaks Westbound at Los Carneros"
            ),
            ["westbound"]
        )
        XCTAssertEqual(
            TransitText.stopDirectionTerms(in: "State Northbound"),
            ["northbound"]
        )
        // Two-letter forms are place names, not directions: "SB" is
        // Santa Barbara (as in "SB Library"), never southbound.
        XCTAssertEqual(
            TransitText.stopDirectionTerms(in: "SB Library"),
            []
        )
    }
}
