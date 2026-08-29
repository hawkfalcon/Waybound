import XCTest
@testable import Waybound

final class RouteIdentityTests: XCTestCase {

    func testIdentityFoldsAgencyAndNumber() {
        let route = TestFixtures.makeRoute(
            shortName: "6",
            agencyName: "MTD (Santa Barbara)"
        )
        let identity = RouteIdentity.identity(for: route)
        XCTAssertEqual(identity.agency, "mtdsantabarbara")
        XCTAssertEqual(identity.routeNumber, "6")
        XCTAssertEqual(identity.stableText, "mtdsantabarbara|6")
        XCTAssertTrue(identity.isUsable)
    }

    func testUnnumberedRoutesAreNotUsable() {
        let route = TestFixtures.makeRoute(
            shortName: "Lompoc",
            longName: "Lompoc",
            agencyName: "MTD"
        )
        XCTAssertFalse(RouteIdentity.identity(for: route).isUsable)
    }

    func testStableColorIsDeterministic() {
        let route = TestFixtures.makeRoute()
        let first = RouteIdentity.stableColor(for: route)
        let second = RouteIdentity.stableColor(for: route)
        XCTAssertEqual(first, second)
    }
}
