import XCTest

@testable import WayboundCore

final class GeoTests: XCTestCase {
    // Santa Barbara's latitude — the one every lane threshold is tuned on.
    private let sbLatitude = 34.4208

    func testMetersPerUnitAtEquator() {
        // 2 * pi * 6378137 / 2^28
        let expected = 2 * Double.pi * 6_378_137 / 268_435_456
        let value = GeoProjection.metersPerUnit(atLatitude: 0)
        XCTAssertEqual(value, expected, accuracy: 1e-9)
    }

    func testMetersPerUnitAtSantaBarbara() {
        // The scale the shipped app's lateral reads were calibrated to
        // (~0.1232): cos(34.4208) * equator scale.
        let value = GeoProjection.metersPerUnit(atLatitude: sbLatitude)
        XCTAssertEqual(value, 0.1232, accuracy: 0.0002)
    }

    func testEquatorToSantaBarbaraRatioIsInverseCosine() {
        // The exact overcount the two-scales bug introduced: converting a
        // Mercator-component sum with the equator rate inflates it by
        // 1/cos(latitude) — ~21% at Santa Barbara's latitude.
        let equator = GeoProjection.metersPerUnit(atLatitude: 0)
        let sb = GeoProjection.metersPerUnit(atLatitude: sbLatitude)
        let ratio = equator / sb
        let expected = 1 / cos(sbLatitude * .pi / 180)
        XCTAssertEqual(ratio, expected, accuracy: 1e-9)
        XCTAssertEqual(ratio, 1.212, accuracy: 0.001)
    }

    func testProjectionRoundTrip() {
        let original = GeoCoordinate(latitude: 34.4208, longitude: -119.7000)
        let back = GeoCoordinate.fromProjected(original.projected)
        XCTAssertEqual(back.latitude, original.latitude, accuracy: 1e-9)
        XCTAssertEqual(back.longitude, original.longitude, accuracy: 1e-9)
    }

    func testConformalScaleConvertsLocalDistances() {
        // Mercator is conformal: a 100 m step east and a 100 m step north
        // must both project to (scale-scaled) 100 m — in every direction.
        let base = GeoCoordinate(latitude: 34.4208, longitude: -119.7000)
        let metersPerDegreeLatitude = 111_320.0
        let metersPerDegreeLongitude =
            111_320.0 * cos(sbLatitude * .pi / 180)

        let east = GeoCoordinate(
            latitude: base.latitude,
            longitude: base.longitude + 100 / metersPerDegreeLongitude
        )
        let north = GeoCoordinate(
            latitude: base.latitude + 100 / metersPerDegreeLatitude,
            longitude: base.longitude
        )

        let scale = GeoProjection.metersPerUnit(atLatitude: sbLatitude)
        let eastMeters = base.projected.distance(to: east.projected) * scale
        let northMeters = base.projected.distance(to: north.projected) * scale
        XCTAssertEqual(eastMeters, 100, accuracy: 0.2)
        XCTAssertEqual(northMeters, 100, accuracy: 0.2)
    }

    func testMetersHelper() {
        let base = GeoCoordinate(latitude: 34.4208, longitude: -119.7000)
        let east = GeoCoordinate(
            latitude: base.latitude,
            longitude: base.longitude + 0.001
        )
        let meters = base.projected.meters(
            to: east.projected,
            atLatitude: sbLatitude
        )
        // 0.001 degrees of longitude at 34.42N is about 91.9 m.
        XCTAssertEqual(meters, 91.9, accuracy: 0.5)
    }
}
