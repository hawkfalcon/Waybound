import XCTest

@testable import WayboundCore

/// The momentary-crowd collapse decides whether a corridor's lane lattice
/// translates back onto the street. It is reached whenever a whole public
/// route key leaves a sweep, and both directions of one route share that key,
/// so the decision needs a rule for "how far did this key ride".
///
/// That rule used to be "whichever member the `presence` Dictionary happened
/// to visit last", which is Swift's per-process hash seed — so the decision,
/// and with it the corridor's lane order, differed between launches on
/// byte-identical data. These tests pin the replacement's semantics, its
/// order-independence, and the fact that the retired rule really was
/// order-dependent (which is what an audit has to sample).
final class LaneCollapseTests: XCTestCase {

    // ------------------------------------------------------------------
    // The rule
    // ------------------------------------------------------------------

    /// One departing key, three members, three different rides ending here.
    private let leavers: [(id: Int, length: Double)] = [
        (id: 10, length: 400),
        (id: 11, length: 36),
        (id: 12, length: 120),
    ]

    func testLongestLeaverReadsTheLongestRideEndingHere() {
        // Any arriving order, one answer: this is the production rule, and it
        // is what makes the collapse decision reproducible.
        let orders: [[(id: Int, length: Double)]] = [
            leavers,
            Array(leavers.reversed()),
            [leavers[1], leavers[2], leavers[0]],
        ]
        for leavers in orders {
            XCTAssertEqual(
                CorridorLaneSchedule.departingRideLength(
                    .longestLeaver,
                    rankedLeavers: leavers,
                    drawnLeaver: nil
                ),
                400
            )
        }
    }

    func testShortestLeaverReadsTheShortestRideEndingHere() {
        let orders: [[(id: Int, length: Double)]] = [
            leavers,
            Array(leavers.reversed()),
            [leavers[2], leavers[0], leavers[1]],
        ]
        for leavers in orders {
            XCTAssertEqual(
                CorridorLaneSchedule.departingRideLength(
                    .shortestLeaver,
                    rankedLeavers: leavers,
                    drawnLeaver: nil
                ),
                36
            )
        }
    }

    func testRankedLeaverReadsTheRankedFirstMember() {
        // The ranking is the caller's (`laneComesBefore` order), so this case
        // is reproducible for a given corridor but does not read lengths.
        XCTAssertEqual(
            CorridorLaneSchedule.departingRideLength(
                .rankedLeaver,
                rankedLeavers: leavers,
                drawnLeaver: (id: 11, length: 36)
            ),
            400
        )
    }

    func testDrawOrderReadsTheDrawnMember() {
        XCTAssertEqual(
            CorridorLaneSchedule.departingRideLength(
                .drawOrder(seed: 7),
                rankedLeavers: leavers,
                drawnLeaver: (id: 11, length: 36)
            ),
            36
        )
        // A drawn member whose own ride does not end here reads as zero, which
        // is exactly how the retired rule could collapse a corridor it should
        // have left alone.
        XCTAssertEqual(
            CorridorLaneSchedule.departingRideLength(
                .drawOrder(seed: 7),
                rankedLeavers: leavers,
                drawnLeaver: (id: 11, length: 0)
            ),
            0
        )
    }

    func testEmptyLeaverSetReadsAsZero() {
        for rider in LaneCollapseRider.auditSet() {
            XCTAssertEqual(
                CorridorLaneSchedule.departingRideLength(
                    rider,
                    rankedLeavers: [],
                    drawnLeaver: nil
                ),
                0
            )
        }
    }

    // ------------------------------------------------------------------
    // The retired rule, as an audit can sample it
    // ------------------------------------------------------------------

    func testSeededDrawVariesAcrossSeedsAndRepeatsWithinOne() {
        let members = [10, 11, 12]
        var drawn = Set<Int>()
        for seed in UInt64(0)..<UInt64(32) {
            let pick = CorridorLaneSchedule.drawnMember(
                members,
                journeyID: 4,
                boundary: 90,
                seed: seed
            )
            XCTAssertNotNil(pick)
            XCTAssertTrue(members.contains(pick!))
            drawn.insert(pick!)
            // Reproducible: the same seed draws the same member, which is
            // what makes the audit's samples comparable between runs.
            XCTAssertEqual(
                pick,
                CorridorLaneSchedule.drawnMember(
                    members,
                    journeyID: 4,
                    boundary: 90,
                    seed: seed
                )
            )
        }
        XCTAssertGreaterThan(
            drawn.count,
            1,
            "a seeded draw that always picks the same member could not stand in "
                + "for the per-process hash seed that caused this bug"
        )
        // Order-free for a fixed seed: a shuffled member list draws the same.
        XCTAssertEqual(
            CorridorLaneSchedule.drawnMember(
                members.reversed(),
                journeyID: 4,
                boundary: 90,
                seed: 3
            ),
            CorridorLaneSchedule.drawnMember(
                members,
                journeyID: 4,
                boundary: 90,
                seed: 3
            )
        )
    }

    // ------------------------------------------------------------------
    // The scheduler reads the rule, not the input order
    // ------------------------------------------------------------------

    private func journeys(
        from strands: [LaneHarness.Strand]
    ) -> [LaneDiagnosticsDocument.Journey] {
        strands.enumerated().map { index, strand in
            LaneDiagnosticsDocument.Journey(
                id: index,
                routeNumber: strand.num,
                agency: strand.agency,
                directionID: strand.direction,
                stackOrder: index,
                departures: strand.departures,
                polylines: [strand.coords]
            )
        }
    }

    func testScheduleIgnoresInputArrayOrderForEveryDeterministicRule() {
        // Array order is the only handle a unit test has on the ordering that
        // Swift's hash seed moves around in the app, so a schedule that
        // changes when the same journeys arrive in a different order is a
        // schedule that can change between launches.
        let strands = LaneScenarios.stateTrunk()
        let forward = journeys(from: strands)
        let backward = Array(forward.reversed())
        for rider in [
            LaneCollapseRider.longestLeaver,
            .shortestLeaver,
            .rankedLeaver,
        ] {
            XCTAssertEqual(
                CorridorLaneSchedule.schedule(
                    journeys: forward,
                    collapseRider: rider
                ),
                CorridorLaneSchedule.schedule(
                    journeys: backward,
                    collapseRider: rider
                ),
                "\(rider) answered differently when the same journeys arrived "
                    + "in a different order"
            )
        }
    }

    func testScheduleDefaultFollowsTheProductionRule() {
        // The app calls `schedule(journeys:laneSpacingPoints:)` with no policy
        // argument, so the default is part of the contract.
        let strands = LaneScenarios.stateTrunk()
        let forward = journeys(from: strands)
        XCTAssertEqual(
            CorridorLaneSchedule.schedule(journeys: forward),
            CorridorLaneSchedule.schedule(
                journeys: forward,
                collapseRider: LaneCollapseRider.production
            )
        )
    }

    // ------------------------------------------------------------------
    // The audit measures what it claims to
    // ------------------------------------------------------------------

    func testAuditIsDeterministicAndCountsCollapseDecisions() throws {
        let strands = LaneScenarios.stateTrunk()
        let forward = journeys(from: strands)
        let first = try XCTUnwrap(LanePolicyAudit.metrics(
            journeys: forward,
            rider: .longestLeaver
        ))
        let second = try XCTUnwrap(LanePolicyAudit.metrics(
            journeys: forward,
            rider: .longestLeaver
        ))
        XCTAssertEqual(first, second)
        XCTAssertGreaterThan(
            first.collapseEvaluations,
            0,
            "the trunk scenario must reach the collapse decision, or this "
                + "sweep cannot say anything about the rule"
        )
        XCTAssertGreaterThanOrEqual(first.bundleCrossings, 0)
        XCTAssertLessThanOrEqual(first.bundleCrossings, first.crossings)
        XCTAssertGreaterThanOrEqual(first.maxAbsOffsetLanes, 0)
    }
}
