import XCTest

@testable import WayboundCore

/// The far-zoom fan pinch.
///
/// A corridor's lanes fan out at a constant on-screen spacing while the street
/// they sit on stays the same width, so where a route doubles back its own two
/// legs end up close together and the lane offset reaches across and folds the
/// ribbon over itself. These tests pin what the pinch does to that fold, and —
/// more importantly — the runs it must leave completely alone.
final class LaneRibbonPinchTests: XCTestCase {

    private let streetWidth = 7.1   // 6.0pt stroke + 1.1pt ink separator

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// Proper crossing test, independent of the one under test.
    private func crosses(
        _ a0: (x: Double, y: Double), _ a1: (x: Double, y: Double),
        _ b0: (x: Double, y: Double), _ b1: (x: Double, y: Double)
    ) -> Bool {
        let d1x = a1.x - a0.x, d1y = a1.y - a0.y
        let d2x = b1.x - b0.x, d2y = b1.y - b0.y
        let den = d1x * d2y - d1y * d2x
        guard abs(den) > 1e-12 else { return false }
        let ex = b0.x - a0.x, ey = b0.y - a0.y
        let t = (ex * d2y - ey * d2x) / den
        let u = (ex * d1y - ey * d1x) / den
        return t > 1e-6 && t < 1 - 1e-6 && u > 1e-6 && u < 1 - 1e-6
    }

    private func magnitude(_ v: (x: Double, y: Double)) -> Double {
        (v.x * v.x + v.y * v.y).squareRoot()
    }

    private func ribbon(
        _ centre: [(x: Double, y: Double)],
        _ displacement: [(x: Double, y: Double)],
        scale: Double
    ) -> [(x: Double, y: Double)] {
        zip(centre, displacement).map {
            (x: $0.x + $1.x * scale, y: $0.y + $1.y * scale)
        }
    }

    /// Does the ribbon fold over itself? Only non-adjacent segment pairs are
    /// compared, and the loop bounds are written so the inner range is never
    /// empty-with-reversed-bounds: `(i + 2)..<(count - 1)` traps once `i`
    /// reaches `count - 2`.
    private func anyFold(
        _ centre: [(x: Double, y: Double)],
        _ displacement: [(x: Double, y: Double)],
        scale: Double
    ) -> Bool {
        let rib = ribbon(centre, displacement, scale: scale)
        let segmentCount = rib.count - 1
        guard segmentCount >= 3 else { return false }
        for i in 0...(segmentCount - 3) {
            for j in (i + 2)...(segmentCount - 1) {
                if crosses(rib[i], rib[i + 1], rib[j], rib[j + 1]) { return true }
            }
        }
        return false
    }

    // ------------------------------------------------------------------
    // The reported bug
    // ------------------------------------------------------------------

    /// A downtown loop: the route runs out along one leg and comes back along
    /// another that sits 82pt away, and the 20pt lane offset reaches across so
    /// the two offset curves cross. That is the saltire X.
    private let loopCentre: [(x: Double, y: Double)] = [
        (0, 0), (200, 0), (200, 80), (150, 80), (100, 30),
    ]
    private let loopDisplacement: [(x: Double, y: Double)] = [
        (0, 20), (0, 20), (-20, 0), (0, -20),
        (14.142135623730951, -14.142135623730951),
    ]

    func testLoopingRunWhoseLaneFoldsIsPinchedBackInsideItsStreet() {
        // Sanity: the lane as scheduled really does fold.
        XCTAssertTrue(anyFold(loopCentre, loopDisplacement, scale: 1))

        let scale = LaneRibbonPinch.runScale(
            centre: loopCentre,
            displacement: loopDisplacement,
            minimumStreetWidth: streetWidth
        )

        XCTAssertLessThan(scale, 1, "the folding run must be pinched")
        XCTAssertGreaterThan(scale, 0, "the lane must not be collapsed onto the centerline")
        XCTAssertFalse(
            anyFold(loopCentre, loopDisplacement, scale: scale),
            "the pinched lane must not fold"
        )
    }

    func testPinchIsTheSmallestScaleThatClearsTheFold() {
        let scale = LaneRibbonPinch.runScale(
            centre: loopCentre,
            displacement: loopDisplacement,
            minimumStreetWidth: streetWidth
        )
        // Anything wider than the answer still folds.
        XCTAssertTrue(anyFold(loopCentre, loopDisplacement, scale: min(1, scale * 1.02)))
        // Anything narrower does not.
        XCTAssertFalse(anyFold(loopCentre, loopDisplacement, scale: scale * 0.98))
    }

    func testPinchIsUniformOverTheRun() {
        let scale = LaneRibbonPinch.runScale(
            centre: loopCentre,
            displacement: loopDisplacement,
            minimumStreetWidth: streetWidth
        )
        let pinched = ribbon(loopCentre, loopDisplacement, scale: scale)
        // A uniform scale is what keeps the lane parallel to its neighbours:
        // every sample moves by the same fraction, so no lane braids across
        // another and the fan keeps its shape.
        var ratios: [Double] = []
        for index in loopDisplacement.indices {
            let drawn = magnitude((
                pinched[index].x - loopCentre[index].x,
                pinched[index].y - loopCentre[index].y
            ))
            ratios.append(drawn / magnitude(loopDisplacement[index]))
        }
        for ratio in ratios {
            XCTAssertEqual(ratio, scale, accuracy: 1e-9)
        }
    }

    func testPinchNeverWidensALane() {
        let scale = LaneRibbonPinch.runScale(
            centre: loopCentre,
            displacement: loopDisplacement,
            minimumStreetWidth: streetWidth
        )
        let pinched = ribbon(loopCentre, loopDisplacement, scale: scale)
        for index in loopDisplacement.indices {
            let drawn = magnitude((
                pinched[index].x - loopCentre[index].x,
                pinched[index].y - loopCentre[index].y
            ))
            XCTAssertLessThanOrEqual(
                drawn,
                magnitude(loopDisplacement[index]) + 1e-9
            )
        }
    }

    // ------------------------------------------------------------------
    // Runs the pinch must leave completely alone
    // ------------------------------------------------------------------

    func testStraightRunIsLeftAlone() {
        let centre: [(x: Double, y: Double)] = [
            (0, 0), (50, 0), (100, 0), (150, 0), (200, 0),
        ]
        let displacement: [(x: Double, y: Double)] = [
            (0, 30), (0, 30), (0, 30), (0, 30), (0, 30),
        ]
        XCTAssertEqual(
            LaneRibbonPinch.runScale(
                centre: centre,
                displacement: displacement,
                minimumStreetWidth: streetWidth
            ),
            1
        )
    }

    /// A route that doubles back along the corridor it just came down has two
    /// legs of the *same* street. No offset scale can separate them, so
    /// pinching would only flatten the route onto itself.
    func testRouteDoublingBackAlongOneStreetIsLeftAlone() {
        let centre: [(x: Double, y: Double)] = [
            (0, 0), (100, 0), (100, 2), (30, -1),
        ]
        let displacement: [(x: Double, y: Double)] = [
            (0, 10), (0, 10), (0, 10), (0, 10),
        ]
        // The two legs are 2pt apart — one street drawn twice — and their
        // offset curves do cross, so without the street-width guard this run
        // would be pinched.
        XCTAssertTrue(anyFold(centre, displacement, scale: 1))
        XCTAssertEqual(
            LaneRibbonPinch.runScale(
                centre: centre,
                displacement: displacement,
                minimumStreetWidth: streetWidth
            ),
            1
        )
    }

    /// A run whose centerline itself crosses is the route's real shape. Moving
    /// its lane cannot fix that, and pinching it would collapse the route onto
    /// the crossing.
    func testRunWhoseCenterlineCrossesIsLeftAlone() {
        let centre: [(x: Double, y: Double)] = [
            (0, 0), (100, 100), (100, 0), (0, 100),
        ]
        let displacement: [(x: Double, y: Double)] = [
            (0, 5), (0, 5), (0, 5), (0, 5),
        ]
        XCTAssertTrue(anyFold(centre, displacement, scale: 0))
        XCTAssertEqual(
            LaneRibbonPinch.runScale(
                centre: centre,
                displacement: displacement,
                minimumStreetWidth: streetWidth
            ),
            1
        )
    }

    func testZeroLaneOffsetsAreLeftAlone() {
        let centre = loopCentre
        let displacement: [(x: Double, y: Double)] = [
            (0, 0), (0, 0), (0, 0), (0, 0), (0, 0),
        ]
        XCTAssertEqual(
            LaneRibbonPinch.runScale(
                centre: centre,
                displacement: displacement,
                minimumStreetWidth: streetWidth
            ),
            1
        )
    }

    func testRunsTooShortToFoldAreLeftAlone() {
        let centre: [(x: Double, y: Double)] = [(0, 0), (10, 0), (20, 0)]
        let displacement: [(x: Double, y: Double)] = [(0, 50), (0, 50), (0, 50)]
        XCTAssertEqual(
            LaneRibbonPinch.runScale(
                centre: centre,
                displacement: displacement,
                minimumStreetWidth: streetWidth
            ),
            1
        )
    }

    // ------------------------------------------------------------------
    // The run-level pass the renderer calls
    // ------------------------------------------------------------------

    func testPinchedRibbonKeepsEveryVertexAndOnlyTouchesSharedRuns() {
        // Segments 3...7 are a folding shared run, which covers samples
        // 3...8; samples 0...2 and 9 are not interlined at all.
        let centre: [(x: Double, y: Double)] = [
            (-40, 0), (-20, 0), (0, 0),                        // isolated
            (10, 0), (200, 0), (200, 80), (150, 80), (100, 30),   // shared loop
            (100, 30), (120, 45),                              // isolated
        ]
        let displacement: [(x: Double, y: Double)] = [
            (0, 0), (0, 0), (0, 0),
            (0, 20), (0, 20), (-20, 0), (0, -20),
            (14.142135623730951, -14.142135623730951),
            (0, 0), (0, 0),
        ]
        let ribbon = zip(centre, displacement).map {
            (x: $0.x + $1.x, y: $0.y + $1.y)
        }
        let sharedSegments: [Bool] = [
            false, false, false,
            true, true, true, true, true,
            false, false,
        ]

        let pinched = LaneRibbonPinch.pinchedRibbon(
            centre: centre,
            ribbon: ribbon,
            sharedSegments: sharedSegments,
            minimumStreetWidth: streetWidth
        )

        XCTAssertEqual(pinched.count, ribbon.count, "no vertex may be dropped")
        // Isolated geometry is drawn on its own lane at every zoom, so the
        // pinch must not move it.
        for index in [0, 1, 2, 9] {
            XCTAssertEqual(pinched[index].x, ribbon[index].x, accuracy: 1e-12)
            XCTAssertEqual(pinched[index].y, ribbon[index].y, accuracy: 1e-12)
        }
        // The shared run moved, and it moved inward.
        let drawn = magnitude((
            pinched[4].x - centre[4].x,
            pinched[4].y - centre[4].y
        ))
        XCTAssertLessThan(drawn, magnitude(displacement[4]))
        XCTAssertFalse(
            anyFold(
                Array(centre[3...7]),
                Array(displacement[3...7]),
                scale: drawn / magnitude(displacement[4])
            ),
            "the pinched shared run must not fold"
        )
    }

    func testPinchedRibbonIsIdempotent() {
        let ribbon = zip(loopCentre, loopDisplacement).map {
            (x: $0.x + $1.x, y: $0.y + $1.y)
        }
        let sharedSegments = [Bool](repeating: true, count: loopCentre.count - 1)

        let once = LaneRibbonPinch.pinchedRibbon(
            centre: loopCentre,
            ribbon: ribbon,
            sharedSegments: sharedSegments,
            minimumStreetWidth: streetWidth
        )
        let twice = LaneRibbonPinch.pinchedRibbon(
            centre: loopCentre,
            ribbon: once,
            sharedSegments: sharedSegments,
            minimumStreetWidth: streetWidth
        )

        for index in once.indices {
            XCTAssertEqual(twice[index].x, once[index].x, accuracy: 1e-9)
            XCTAssertEqual(twice[index].y, once[index].y, accuracy: 1e-9)
        }
    }

    func testPinchedRibbonLeavesAnAllIsolatedRouteAlone() {
        let centre = loopCentre
        let displacement = loopDisplacement
        let ribbon = zip(centre, displacement).map {
            (x: $0.x + $1.x, y: $0.y + $1.y)
        }
        let sharedSegments = [Bool](repeating: false, count: centre.count - 1)

        let pinched = LaneRibbonPinch.pinchedRibbon(
            centre: centre,
            ribbon: ribbon,
            sharedSegments: sharedSegments,
            minimumStreetWidth: streetWidth
        )
        for index in ribbon.indices {
            XCTAssertEqual(pinched[index].x, ribbon[index].x, accuracy: 1e-12)
            XCTAssertEqual(pinched[index].y, ribbon[index].y, accuracy: 1e-12)
        }
    }

    /// City scale: no lane offsets at all, so there is nothing to pinch and
    /// the trunk keeps drawing on the centerline.
    func testPinchedRibbonWithNoOffsetsIsTheIdentity() {
        let centre = loopCentre
        let ribbon = centre
        let sharedSegments = [Bool](repeating: true, count: centre.count - 1)

        let pinched = LaneRibbonPinch.pinchedRibbon(
            centre: centre,
            ribbon: ribbon,
            sharedSegments: sharedSegments,
            minimumStreetWidth: streetWidth
        )
        for index in ribbon.indices {
            XCTAssertEqual(pinched[index].x, ribbon[index].x, accuracy: 1e-12)
            XCTAssertEqual(pinched[index].y, ribbon[index].y, accuracy: 1e-12)
        }
    }
}
