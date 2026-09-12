import XCTest
@testable import WayboundCore

/// TEMPORARY bisect probe: runs the scheduler on progressively complex
/// synthetic corridors and prints before each, so a crashing feature is
/// identified by the last printed line. Delete once lane_check is green.
final class ScheduleBisectProbeTests: XCTestCase {
    func testBisectProbe() {
        setvbuf(stdout, nil, _IONBF, 0)

        func run(_ label: String, _ strands: [LaneHarness.Strand]) {
            print("PROBE \(label) begin")
            let journeys = strands.enumerated().map { index, strand in
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
            _ = CorridorLaneSchedule.schedule(
                journeys: journeys,
                laneSpacingPoints: LaneHarness.laneSpacing
            )
            print("PROBE \(label) ok")
        }

        let straight = LaneScenarios.spinePoints([
            (x: 0, y: 0),
            (x: 400, y: 0),
        ])
        let arcs = LaneScenarios.arcOf(straight)

        run("1-two-full-share", [
            LaneScenarios.strandGeometry("a", "1", 0, LaneScenarios.strand(straight, arcs, 0, 400)),
            LaneScenarios.strandGeometry("b", "2", 0, LaneScenarios.strand(straight, arcs, 0, 400)),
        ])

        run("2-two-share-to-end", [
            LaneScenarios.strandGeometry("a", "1", 0, LaneScenarios.strand(straight, arcs, 0, 400)),
            LaneScenarios.strandGeometry("b", "2", 0, LaneScenarios.strand(straight, arcs, 100, 400)),
        ])

        run("3-three-full-share", [
            LaneScenarios.strandGeometry("a", "1", 0, LaneScenarios.strand(straight, arcs, 0, 400)),
            LaneScenarios.strandGeometry("b", "2", 0, LaneScenarios.strand(straight, arcs, 0, 400)),
            LaneScenarios.strandGeometry("c", "3", 0, LaneScenarios.strand(straight, arcs, 0, 400)),
        ])

        run("4-join-mid", [
            LaneScenarios.strandGeometry("a", "1", 0, LaneScenarios.strand(straight, arcs, 0, 400)),
            LaneScenarios.strandGeometry("b", "2", 0, LaneScenarios.strand(straight, arcs, 150, 400, sideIn: 1)),
        ])

        run("5-leave-mid", [
            LaneScenarios.strandGeometry("a", "1", 0, LaneScenarios.strand(straight, arcs, 0, 400)),
            LaneScenarios.strandGeometry("b", "2", 0, LaneScenarios.strand(straight, arcs, 0, 250, sideOut: 1)),
        ])

        run("6-reverse-pair", [
            LaneScenarios.strandGeometry("a", "1", 0, LaneScenarios.strand(straight, arcs, 0, 400)),
            LaneScenarios.strandGeometry("b", "1", 1, LaneScenarios.strand(straight, arcs, 0, 400)),
        ])

        // state_trunk's staggered shape on a short street, 3 strands.
        let trunk = LaneScenarios.spinePoints([
            (x: 0, y: 0),
            (x: 200, y: 8),
            (x: 400, y: 4),
        ])
        let trunkArcs = LaneScenarios.arcOf(trunk)
        run("7-staggered-3", [
            LaneScenarios.strandGeometry("a", "1", 0, LaneScenarios.strand(trunk, trunkArcs, 0, 400)),
            LaneScenarios.strandGeometry("b", "2", 0, LaneScenarios.strand(trunk, trunkArcs, 100, 300, sideOut: 1)),
            LaneScenarios.strandGeometry("c", "3", 0, LaneScenarios.strand(trunk, trunkArcs, 150, 400, sideIn: -1)),
        ])

        // The real first scenario, verbatim.
        let check = LaneCheckTests()
        run("8-state_trunk", check.scenarios().first { $0.name == "state_trunk" }!.strands)
        print("PROBE all ok")
    }
}
