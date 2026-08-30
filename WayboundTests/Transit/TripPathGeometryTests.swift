import CoreLocation
import MapKit
import XCTest
@testable import Waybound

final class TripPathGeometryTests: XCTestCase {

    func testDiagnosticsMapKitScalePrints() {
        // Temporary instrument, no assertions: prints what this binary
        // actually computes for a known 500 m east-west segment at the
        // fixture latitude. Reference values from the Python mirror:
        // ppm 8.1176, mpm 0.12317, point distance 4058.8, meters 500.08.
        let a = TestFixtures.coordinate(north: 0, east: 0)
        let b = TestFixtures.coordinate(north: 0, east: 500)
        let pa = MKMapPoint(a)
        let pb = MKMapPoint(b)
        let mpm = TripPathGeometry.metersPerMapPoint(atLatitude: a.latitude)
        let pointDistance = pa.distance(to: pb)
        print("DIAG ppm=\(1.0 / mpm) mpm=\(mpm) pointDistance=\(pointDistance) meters=\(pointDistance * mpm)")
        let spikeIn = pa.distance(to: MKMapPoint(TestFixtures.coordinate(north: 0, east: 500))) * mpm
        let spikeBypass = pa.distance(to: MKMapPoint(TestFixtures.coordinate(north: 0, east: 10))) * mpm
        print("DIAG spikeIncoming=\(spikeIn) spikeBypass=\(spikeBypass)")
    }

    func testMetersPerMapPointMatchesTheMercatorProjection() {
        // One map point spans ~0.149 m at the equator and ~0.123 m in Santa
        // Barbara. Skipping this conversion made every meter threshold in the
        // app roughly eight times stricter than written.
        let equator = TripPathGeometry.metersPerMapPoint(atLatitude: 0)
        let santaBarbara = TripPathGeometry.metersPerMapPoint(atLatitude: 34.4208)
        XCTAssertEqual(equator, 0.149, accuracy: 0.01)
        XCTAssertEqual(santaBarbara, 0.123, accuracy: 0.01)
        XCTAssertLessThan(santaBarbara, equator)
    }

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

    func testRemovingSinglePointSpikesUsesTrueMeterThresholds() {
        // 350 m out, 320 m back to within 30 m of the start: unmistakable in
        // meters, but invisible to the old map-point comparison, where a
        // 30 m bypass read as 244 map points against a 75 threshold.
        let coordinates = [
            TestFixtures.coordinate(north: 0, east: 0),
            TestFixtures.coordinate(north: 0, east: 350),
            TestFixtures.coordinate(north: 0, east: 30),
        ]
        let cleaned = TripPathGeometry.removingSinglePointSpikes(from: coordinates)
        XCTAssertEqual(cleaned.count, 2)
    }

    func testRemovingOutAndBackSpursDropsAStrayDetour() {
        // A stray coordinate spliced 20 m off the centerline: the shape leaves
        // the street, touches the stray point, and returns.
        let coordinates = [
            TestFixtures.coordinate(north: 0, east: 0),
            TestFixtures.coordinate(north: 0, east: 80),
            TestFixtures.coordinate(north: 20, east: 88),
            TestFixtures.coordinate(north: 0, east: 82),
            TestFixtures.coordinate(north: 0, east: 200),
        ]
        let cleaned = TripPathGeometry.removingOutAndBackSpurs(from: coordinates)
        XCTAssertEqual(cleaned.count, 4)
        let strayLatitude = TestFixtures.coordinate(north: 20, east: 88).latitude
        XCTAssertFalse(cleaned.contains { abs($0.latitude - strayLatitude) < 0.00005 })
    }

    func testRemovingOutAndBackSpursKeepsTurnaroundsAndLoops() {
        // A dead-end turnaround comes back facing the other way; the heading
        // gate must keep it.
        let turnaround = [0, 40, 60, 40, -60].map {
            TestFixtures.coordinate(north: 0, east: $0)
        }
        XCTAssertEqual(
            TripPathGeometry.removingOutAndBackSpurs(from: turnaround).count,
            5
        )

        // A loop around a block returns home but travels too far to be a spur.
        let blockLoop = [
            TestFixtures.coordinate(north: 0, east: 0),
            TestFixtures.coordinate(north: 60, east: 0),
            TestFixtures.coordinate(north: 60, east: 50),
            TestFixtures.coordinate(north: 0, east: 50),
            TestFixtures.coordinate(north: 0, east: 0),
            TestFixtures.coordinate(north: -80, east: 0),
        ]
        XCTAssertEqual(
            TripPathGeometry.removingOutAndBackSpurs(from: blockLoop).count,
            6
        )
    }

    func testCleanedShapeChainsSpikeAndSpurRemoval() {
        // One stray single-vertex reversal near the start, plus one short
        // multi-vertex returning detour mid-line, both disappear in one pass.
        let coordinates = [
            TestFixtures.coordinate(north: 0, east: 0),
            TestFixtures.coordinate(north: 0, east: 20),   // out-and-back spike
            TestFixtures.coordinate(north: 1, east: 0),
            TestFixtures.coordinate(north: 1, east: 100),
            TestFixtures.coordinate(north: 18, east: 104), // detour out...
            TestFixtures.coordinate(north: 26, east: 108), // ...and back
            TestFixtures.coordinate(north: 3, east: 102),
            TestFixtures.coordinate(north: 3, east: 220),
        ]
        let cleaned = TripPathGeometry.cleanedShape(from: coordinates)
        XCTAssertEqual(cleaned.count, 5)
    }

    func testRemovingStopConnectorNotchesDropsPerpendicularConnectors() {
        // SBMTD-style comb: the shape steps 10 m sideways to the stop
        // coordinate and resumes down the street (a V, never retracing).
        let street = [0, 40, 80, 100, 128, 160, 220].map {
            TestFixtures.coordinate(north: 0, east: $0)
        }
        let stop = TestFixtures.coordinate(north: 10, east: 100)
        let comb = [
            TestFixtures.coordinate(north: 0, east: 0),
            TestFixtures.coordinate(north: 0, east: 40),
            TestFixtures.coordinate(north: 0, east: 80),
            TestFixtures.coordinate(north: 0, east: 100),
            stop,
            TestFixtures.coordinate(north: 0, east: 128),
            TestFixtures.coordinate(north: 0, east: 160),
            TestFixtures.coordinate(north: 0, east: 220),
        ]
        let cleaned = TripPathGeometry.removingStopConnectorNotches(
            from: comb,
            nearStops: [stop]
        )
        XCTAssertEqual(cleaned.count, street.count)
        XCTAssertEqual(cleaned.map(\.latitude), street.map(\.latitude))
        XCTAssertEqual(cleaned.map(\.longitude), street.map(\.longitude))
    }

    func testRemovingStopConnectorNotchesKeepsBlockJogs() {
        // Real routing constantly jogs one block over. The first version of
        // this stage deleted jogs like this and drew diagonals off-street;
        // a jog resumes on a different street line and must be kept.
        let jog = [
            TestFixtures.coordinate(north: 0, east: 0),
            TestFixtures.coordinate(north: 100, east: 0),
            TestFixtures.coordinate(north: 100, east: 40),
            TestFixtures.coordinate(north: 220, east: 40),
            TestFixtures.coordinate(north: 320, east: 40),
        ]
        let cornerStop = TestFixtures.coordinate(north: 100, east: 40)
        let cleaned = TripPathGeometry.removingStopConnectorNotches(
            from: jog,
            nearStops: [cornerStop]
        )
        XCTAssertEqual(cleaned.count, jog.count)
    }

    func testRemovingStopConnectorNotchesKeepsAsymmetricCorners() {
        // A turn whose legs differ in length, with a stop at the bend: the
        // route resumes on a different line, so it stays.
        let corner = [
            TestFixtures.coordinate(north: 0, east: 0),
            TestFixtures.coordinate(north: 0, east: 60),
            TestFixtures.coordinate(north: 0, east: 120),
            TestFixtures.coordinate(north: 180, east: 120),
            TestFixtures.coordinate(north: 180, east: 300),
        ]
        let stopAtBend = TestFixtures.coordinate(north: 4, east: 116)
        let cleaned = TripPathGeometry.removingStopConnectorNotches(
            from: corner,
            nearStops: [stopAtBend]
        )
        XCTAssertEqual(cleaned.count, corner.count)
    }

    func testRemovingStopConnectorNotchesDropsShallowNearExactReturns() {
        // The other published form: out to an 8 m-off stop and back to a
        // point 4 m past the anchor. Too shallow and too short for the spur
        // gates, but unmistakable with the stop known.
        let stop = TestFixtures.coordinate(north: 8, east: 120)
        let comb = [
            TestFixtures.coordinate(north: 0, east: 0),
            TestFixtures.coordinate(north: 0, east: 60),
            TestFixtures.coordinate(north: 0, east: 120),
            stop,
            TestFixtures.coordinate(north: 0, east: 124),
            TestFixtures.coordinate(north: 0, east: 200),
        ]
        let cleaned = TripPathGeometry.removingStopConnectorNotches(
            from: comb,
            nearStops: [stop]
        )
        // The connector's street-side anchor stays and the stop vertex goes;
        // redundant collinear street vertices inside the span go with it —
        // the drawn line is the street either way.
        XCTAssertEqual(cleaned.count, 4)
        XCTAssertFalse(cleaned.contains { $0.latitude == stop.latitude })
    }

    func testRemovingStopConnectorNotchesRemovesEveryStopInAComb() {
        // One connector per stop down the whole line; the pass must iterate.
        // Each connector leaves from the street point opposite its stop and
        // resumes 40 m downstream, like the published route 3 shapes.
        var comb = [TestFixtures.coordinate(north: 0, east: 0)]
        var stops: [CLLocationCoordinate2D] = []
        for east in stride(from: 80, through: 400, by: 80) {
            let stop = TestFixtures.coordinate(north: 12, east: Double(east))
            stops.append(stop)
            comb.append(TestFixtures.coordinate(north: 0, east: Double(east)))
            comb.append(stop)
            comb.append(TestFixtures.coordinate(north: 0, east: Double(east + 40)))
        }
        comb.append(TestFixtures.coordinate(north: 0, east: 460))
        let cleaned = TripPathGeometry.removingStopConnectorNotches(
            from: comb,
            nearStops: stops
        )
        // Connectors whose spans reach past the next street vertex absorb
        // the collinear ones (both span ends are gated onto the street
        // lines), so the count lands below the strict minimum — but every
        // stop coordinate is gone and every survivor is on the street.
        XCTAssertEqual(cleaned.count, 8)
        XCTAssertTrue(
            cleaned.allSatisfy { $0.latitude == comb[0].latitude },
            "a surviving vertex is off the street"
        )
        for stop in stops {
            XCTAssertFalse(
                cleaned.contains { $0.latitude == stop.latitude },
                "connector at east \(stop.longitude) survived"
            )
        }
    }

    func testRemovingStopConnectorNotchesKeepsCornersEvenWithStops() {
        // A genuine 90-degree corner whose apex sits right beside a stop: the
        // corner's farthest vertex lies along the chord, not beside it, so
        // the perpendicularity gate keeps the turn.
        let corner = [
            TestFixtures.coordinate(north: 0, east: 0),
            TestFixtures.coordinate(north: 0, east: 80),
            TestFixtures.coordinate(north: 0, east: 160),
            TestFixtures.coordinate(north: 80, east: 160),
            TestFixtures.coordinate(north: 160, east: 160),
            TestFixtures.coordinate(north: 160, east: 240),
        ]
        let stopAtCorner = TestFixtures.coordinate(north: 8, east: 156)
        let cleaned = TripPathGeometry.removingStopConnectorNotches(
            from: corner,
            nearStops: [stopAtCorner]
        )
        XCTAssertEqual(cleaned.count, corner.count)
    }

    func testRemovingStopConnectorNotchesKeepsTurnaroundsAtStops() {
        // A hairpin that serves a stop is real service: travel reverses, so
        // the continuation gate must keep it.
        let stop = TestFixtures.coordinate(north: 18, east: 104)
        let turnaround = [
            TestFixtures.coordinate(north: 0, east: 0),
            TestFixtures.coordinate(north: 0, east: 60),
            TestFixtures.coordinate(north: 0, east: 100),
            TestFixtures.coordinate(north: 18, east: 104),
            TestFixtures.coordinate(north: 0, east: 108),
            TestFixtures.coordinate(north: 0, east: 30),
        ]
        let cleaned = TripPathGeometry.removingStopConnectorNotches(
            from: turnaround,
            nearStops: [stop]
        )
        XCTAssertEqual(cleaned.count, turnaround.count)
    }

    func testCleanedShapeUsesStopsToDropNotches() {
        // Without stops the notch stage is inert; with them the connector
        // disappears even though it is far too shallow for the spur gates.
        let stop = TestFixtures.coordinate(north: 8, east: 120)
        let comb = [
            TestFixtures.coordinate(north: 0, east: 0),
            TestFixtures.coordinate(north: 0, east: 60),
            TestFixtures.coordinate(north: 0, east: 120),
            stop,
            TestFixtures.coordinate(north: 0, east: 124),
            TestFixtures.coordinate(north: 0, east: 200),
        ]
        XCTAssertEqual(
            TripPathGeometry.cleanedShape(from: comb).count,
            6
        )
        XCTAssertEqual(
            TripPathGeometry.cleanedShape(from: comb, nearStops: [stop]).count,
            4
        )
    }

    func testRemovingStopConnectorNotchesDropsSparseShapeConnectors() {
        // A feed that samples sparsely draws the connector as: street,
        // stop, next street vertex a hundred meters on. The span gates must
        // tolerate the long re-entry, not just the dense downtown form.
        let stop = TestFixtures.coordinate(north: 9, east: 200)
        let sparse = [
            TestFixtures.coordinate(north: 0, east: 0),
            TestFixtures.coordinate(north: 0, east: 100),
            TestFixtures.coordinate(north: 0, east: 200),
            stop,
            TestFixtures.coordinate(north: 0, east: 300),
            TestFixtures.coordinate(north: 0, east: 420),
        ]
        let cleaned = TripPathGeometry.removingStopConnectorNotches(
            from: sparse,
            nearStops: [stop]
        )
        XCTAssertEqual(cleaned.count, 5)
        XCTAssertFalse(cleaned.contains { $0.latitude == stop.latitude })
    }

    func testRemovingStopConnectorNotchesDropsTerminalStopConnectors() {
        // At the end of a journey the connector has no return span at all:
        // the shape simply ends on the stop coordinate, reached sideways
        // off the street line. Both ends are trimmed the same way.
        let endStop = TestFixtures.coordinate(north: 10, east: 300)
        let startStop = TestFixtures.coordinate(north: 10, east: 0)
        let outbound = [
            TestFixtures.coordinate(north: 0, east: 0),
            TestFixtures.coordinate(north: 0, east: 100),
            TestFixtures.coordinate(north: 0, east: 200),
            TestFixtures.coordinate(north: 0, east: 300),
            endStop,
        ]
        let trimmedEnd = TripPathGeometry.removingStopConnectorNotches(
            from: outbound,
            nearStops: [endStop]
        )
        XCTAssertEqual(trimmedEnd.count, 4)
        XCTAssertFalse(trimmedEnd.contains { $0.latitude == endStop.latitude })

        let inbound = [startStop] + Array(outbound.dropLast())
        let trimmedStart = TripPathGeometry.removingStopConnectorNotches(
            from: inbound,
            nearStops: [startStop]
        )
        XCTAssertEqual(trimmedStart.count, 4)
        XCTAssertFalse(trimmedStart.contains { $0.latitude == startStop.latitude })
    }

    func testRemovingStopConnectorNotchesKeepsAngledTerminalApproaches() {
        // A route that genuinely leaves the street to end at its terminal
        // stop at 45 degrees is service, not an artifact — only sideways
        // (≥70° off the street) terminal coordinates are trimmed.
        let terminalStop = TestFixtures.coordinate(north: 60, east: 240)
        let approach = [
            TestFixtures.coordinate(north: 0, east: 0),
            TestFixtures.coordinate(north: 0, east: 120),
            TestFixtures.coordinate(north: 0, east: 180),
            terminalStop,
        ]
        let cleaned = TripPathGeometry.removingStopConnectorNotches(
            from: approach,
            nearStops: [terminalStop]
        )
        XCTAssertEqual(cleaned.count, approach.count)
    }

    func testRemovingStopConnectorNotchesKeepsCrestsWithStopsAtTheApex() {
        // A gentle vertical curve (R = 250 m) whose highest point sits beside
        // a stop: both legs diverge from the street gradually, so the
        // steep-leg gate must keep the whole curve.
        let crest = (0..<15).map { step in
            let angle = Double(step - 7) * 2.0
            let radians = angle * .pi / 180
            return TestFixtures.coordinate(
                north: 60 - 250 * (1 - cos(radians)),
                east: 250 * sin(radians)
            )
        }
        let stopAtApex = TestFixtures.coordinate(north: 68, east: 0)
        let cleaned = TripPathGeometry.removingStopConnectorNotches(
            from: crest,
            nearStops: [stopAtApex]
        )
        XCTAssertEqual(cleaned.count, crest.count)
    }

    func testRemovingStopConnectorNotchesDropsVerySparseConnectors() {
        // The lowest-frequency routes (20, 14) sample their shapes so
        // sparsely that a connector's re-entry vertex sits two hundred
        // meters past the stop. The structural gates — street-through and
        // the steep leg — make the longer span safe.
        let stop = TestFixtures.coordinate(north: 9, east: 300)
        let sparse = [
            TestFixtures.coordinate(north: 0, east: 0),
            TestFixtures.coordinate(north: 0, east: 150),
            TestFixtures.coordinate(north: 0, east: 300),
            stop,
            TestFixtures.coordinate(north: 0, east: 500),
            TestFixtures.coordinate(north: 0, east: 650),
        ]
        let cleaned = TripPathGeometry.removingStopConnectorNotches(
            from: sparse,
            nearStops: [stop]
        )
        XCTAssertEqual(cleaned.count, 5)
        XCTAssertFalse(cleaned.contains { $0.latitude == stop.latitude })
    }

    func testRemovingStopConnectorNotchesTrimsMultiVertexTerminalTails() {
        // A connector with two baked points at the stop: the trim drops the
        // terminal stop, then the midpoint beside it. The street heading is
        // measured from outside the connector, so the tail's own direction
        // cannot masquerade as the street.
        let stop = TestFixtures.coordinate(north: 16, east: 290)
        let tail = [
            TestFixtures.coordinate(north: 0, east: 0),
            TestFixtures.coordinate(north: 0, east: 100),
            TestFixtures.coordinate(north: 0, east: 200),
            TestFixtures.coordinate(north: 0, east: 290),
            TestFixtures.coordinate(north: 8, east: 290),
            stop,
        ]
        let cleaned = TripPathGeometry.removingStopConnectorNotches(
            from: tail,
            nearStops: [stop]
        )
        XCTAssertEqual(cleaned.count, 4)
        XCTAssertTrue(
            cleaned.allSatisfy { $0.latitude == tail[0].latitude },
            "a surviving vertex is off the street"
        )
    }

    func testRemovingStopConnectorNotchesKeepsParallelTerminalEntries() {
        // A bay or terminal entry that runs alongside the street into the
        // stop is geometrically indistinguishable from service and stays.
        let stop = TestFixtures.coordinate(north: 10, east: 320)
        let bay = [
            TestFixtures.coordinate(north: 0, east: 0),
            TestFixtures.coordinate(north: 0, east: 100),
            TestFixtures.coordinate(north: 0, east: 200),
            TestFixtures.coordinate(north: 10, east: 260),
            stop,
        ]
        let cleaned = TripPathGeometry.removingStopConnectorNotches(
            from: bay,
            nearStops: [stop]
        )
        XCTAssertEqual(cleaned.count, bay.count)
    }

    func testRemovingStopConnectorNotchesTrimsShortSidewaysTerminalStarts() {
        // Real SBMTD route 14 geometry (shp-14-01 start, North Jameson &
        // Sheffield): every early vertex sits within one notch depth of the
        // stop, so the street baseline must stop walking while it still has
        // a vertex to measure against — an unbounded walk runs off the end
        // and the sideways start survives.
        let stop = CLLocationCoordinate2D(latitude: 34.422348, longitude: -119.614727)
        let start = [
            stop,
            CLLocationCoordinate2D(latitude: 34.422280, longitude: -119.614700),
            CLLocationCoordinate2D(latitude: 34.422280, longitude: -119.614710),
            CLLocationCoordinate2D(latitude: 34.422210, longitude: -119.614910),
        ]
        let cleaned = TripPathGeometry.removingStopConnectorNotches(
            from: start,
            nearStops: [stop]
        )
        XCTAssertEqual(cleaned.count, 3)
        XCTAssertFalse(cleaned.contains { $0.latitude == stop.latitude })
    }

    func testSplitPolylineKeepsLegitimateIntercityLegs() {
        // A 20 km rural leg is legitimate intercity service at the documented
        // 50 km bus threshold; the map-point comparison used to cut it in two.
        let line = [0, 100, 20_000, 20_100].map {
            TestFixtures.coordinate(north: 0, east: $0)
        }
        let segments = TripPathGeometry.splitPolyline(
            line,
            atJumpsLongerThan: 50_000
        )
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].count, 4)
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
