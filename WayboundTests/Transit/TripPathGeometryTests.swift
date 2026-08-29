import CoreLocation
import XCTest
@testable import Waybound

final class TripPathGeometryTests: XCTestCase {

    func testMaximumGeometryJumpFavorsIntercityAndFerry() {
        XCTAssertEqual(TripPathGeometry.maximumGeometryJump(for: 4), 200_000)
        XCTAssertEqual(TripPathGeometry.maximumGeometryJump(for: 2), 100_000)
        XCTAssertEqual(TripPathGeometry.maximumGeometryJump(for: 3), 50_000)
    }

    func testSplitPolylineDropsTheJumpAndTrailingSingletons() {
        let line = [0, 100, 200, 60_000, 60_100].map {
            TestFixtures.coordinate(north: 0, east: $0)
        }
        let segments = TripPathGeometry.splitPolyline(
            line,
            atJumpsLongerThan: 50_000
        )
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].count, 3)
        XCTAssertEqual(segments[1].count, 2)
    }

    func testRemovingSinglePointSpikesDropsTinyReversals() {
        let coordinates = [
            TestFixtures.coordinate(north: 0, east: 0),
            TestFixtures.coordinate(north: 30, east: 0),
            TestFixtures.coordinate(north: 0, east: 1),
        ]
        let cleaned = TripPathGeometry.removingSinglePointSpikes(from: coordinates)
        XCTAssertEqual(cleaned.count, 2)
    }

    func testRemovingSinglePointSpikesDropsLargeOutAndBackSpikes() {
        let coordinates = [
            TestFixtures.coordinate(north: 0, east: 0),
            TestFixtures.coordinate(north: 0, east: 500),
            TestFixtures.coordinate(north: 0, east: 10),
        ]
        let cleaned = TripPathGeometry.removingSinglePointSpikes(from: coordinates)
        XCTAssertEqual(cleaned.count, 2)
        XCTAssertEqual(
            cleaned[1].longitude,
            TestFixtures.coordinate(north: 0, east: 10).longitude,
            accuracy: 0.000_01
        )
    }

    func testRemovingSinglePointSpikesLeavesALegitimateRun() {
        let coordinates = [0, 100, 200, 300].map {
            TestFixtures.coordinate(north: 0, east: $0)
        }
        let cleaned = TripPathGeometry.removingSinglePointSpikes(from: coordinates)
        XCTAssertEqual(cleaned.count, 4)
    }

    func testMonotonicShapeAlignmentIsStrictlyIncreasing() {
        let line = stride(from: 0.0, through: 1_000.0, by: 100).map {
            TestFixtures.coordinate(north: 0, east: $0)
        }
        let stops = [0, 250, 500, 750, 1_000].map {
            TestFixtures.coordinate(north: 0, east: $0)
        }
        let alignment = TripPathGeometry.monotonicShapeAlignment(
            stops: stops,
            line: line
        )
        XCTAssertNotNil(alignment)
        let indices = alignment!.indices
        XCTAssertEqual(indices.count, 5)
        XCTAssertTrue(zip(indices, indices.dropFirst()).allSatisfy { $0 < $1 })
        XCTAssertLessThan(alignment!.maximumDistance, 60)
    }

    func testClipPolylineCutsASegmentToTheDisplayRadius() {
        let line = [
            TestFixtures.coordinate(north: 0, east: 100),
            TestFixtures.coordinate(north: 0, east: 900),
        ]
        let origin = TestFixtures.coordinate(north: 0, east: 0)
        let clipped = TripPathGeometry.clipPolyline(
            line,
            toRadius: 500,
            around: origin
        )
        XCTAssertEqual(clipped.count, 1)
        XCTAssertEqual(clipped[0].count, 2)
        let start = CLLocation(
            latitude: clipped[0][0].latitude,
            longitude: clipped[0][0].longitude
        )
        let end = CLLocation(
            latitude: clipped[0][1].latitude,
            longitude: clipped[0][1].longitude
        )
        let originLocation = CLLocation(
            latitude: origin.latitude,
            longitude: origin.longitude
        )
        XCTAssertEqual(originLocation.distance(from: start), 100, accuracy: 15)
        XCTAssertEqual(originLocation.distance(from: end), 500, accuracy: 15)
    }

    func testTripPathSplitsApproachFlagshipAndContinuation() {
        let shape = stride(from: -200.0, through: 1_200.0, by: 100).map {
            TestFixtures.coordinate(north: 0, east: $0)
        }
        let stops = [0, 250, 500, 750, 1_000].map {
            TestFixtures.coordinate(north: 0, east: $0)
        }
        let path = TripPathGeometry.tripPath(
            in: [shape],
            alignedTo: stops,
            flagshipStopIndex: 2
        )
        XCTAssertNotNil(path)
        XCTAssertEqual(path!.approach.count, 1)
        XCTAssertEqual(path!.approach[0].count, 3)
        XCTAssertEqual(path!.flagship.count, 1)
        XCTAssertGreaterThanOrEqual(path!.flagship[0].count, 2)
        XCTAssertEqual(path!.continuation.count, 1)
        XCTAssertGreaterThanOrEqual(path!.continuation[0].count, 2)

        let origin = TestFixtures.coordinate(north: 0, east: 0)
        let originLocation = CLLocation(
            latitude: origin.latitude,
            longitude: origin.longitude
        )
        func distance(of coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
            originLocation.distance(
                from: CLLocation(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                )
            )
        }
        XCTAssertEqual(distance(of: path!.flagship[0].first!), 0, accuracy: 20)
        XCTAssertEqual(distance(of: path!.flagship[0].last!), 500, accuracy: 20)
        XCTAssertEqual(distance(of: path!.continuation[0].last!), 1_000, accuracy: 20)

        let reversedPath = TripPathGeometry.tripPath(
            in: [Array(shape.reversed())],
            alignedTo: stops,
            flagshipStopIndex: 2
        )
        XCTAssertNotNil(reversedPath)
    }

    func testTripPathReturnsNilWhenAStopIsOffTheLine() {
        var stops = [0, 250, 500, 750, 1_000].map {
            TestFixtures.coordinate(north: 0, east: $0)
        }
        stops[2] = TestFixtures.coordinate(north: 5_000, east: 500)
        let shape = stride(from: -200.0, through: 1_200.0, by: 100).map {
            TestFixtures.coordinate(north: 0, east: $0)
        }
        XCTAssertNil(
            TripPathGeometry.tripPath(
                in: [shape],
                alignedTo: stops,
                flagshipStopIndex: 2
            )
        )
    }
}
