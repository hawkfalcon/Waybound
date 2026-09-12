import XCTest

@testable import WayboundCore

/// Lane-ordering gates: main's per-sample lane source vs the anchored-lane
/// scheduler, on the downtown scenarios — pure Swift ports of
/// `lane_check.py`'s evaluate/gates (that file is gone; this is its
/// successor). For each scenario: render main vs scheduled ribbons, count
/// proper strand crossings, count in-bundle crossings, continuing-strand
/// wobble, bundle separation, alignment kink, and (couplet) direction
/// contiguity. The comparative gates attribute every difference to lane
/// ORDERING only: both sides share the scan, the pipeline, and the ribbon.
final class LaneCheckTests: XCTestCase {

    private var dataDirectory: URL {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let packageRoot = tests.deletingLastPathComponent().deletingLastPathComponent()
        let repoRoot = packageRoot.deletingLastPathComponent()
        return repoRoot
            .appendingPathComponent("tools/replay/data", isDirectory: true)
    }

    struct Scenario {
        let name: String
        let strands: [LaneHarness.Strand]
        var maxBundle = 0
        var sepSlack = 0.0
        /// (probe arc in metres, expected route numbers outermost-first)
        var expectOrder: (Double, [String])?
    }

    func scenarios() -> [Scenario] {
        [
            Scenario(name: "state_trunk", strands: LaneScenarios.stateTrunk()),
            Scenario(name: "couplet", strands: LaneScenarios.couplet()),
            Scenario(
                name: "boarding_bundle",
                strands: LaneScenarios.boardingBundle()
            ),
            Scenario(
                name: "dropout",
                strands: LaneScenarios.dropout(),
                maxBundle: 2,
                sepSlack: 0.2
            ),
            Scenario(name: "fork", strands: LaneScenarios.fork(), maxBundle: 1),
            // The synthetic legs put 5/17/4 on the -side and 7/80 on the
            // +side; in this geometry least-crosses reads (5, 17, 4, 1, 7,
            // 80) left-to-right, the mirror of the real-world
            // (80, 7, 1, 4, 17, 5).
            Scenario(
                name: "fanout",
                strands: LaneScenarios.fanout(),
                expectOrder: (250, ["5", "17", "4", "1", "7", "80"])
            ),
            Scenario(
                name: "reversed_spine",
                strands: LaneScenarios.reversedSpine()
            ),
            Scenario(
                name: "chapala",
                strands: LaneScenarios.chapala(dataDirectory: dataDirectory)
            ),
        ]
    }

    // ------------------------------------------------------------------
    // Evaluation
    // ------------------------------------------------------------------

    func evaluate(_ scenario: Scenario) -> [String] {
        let strands = scenario.strands
        let scan = LaneHarness.membershipScan(strands)
        let mainLayouts = LaneHarness.mainLayouts(
            strands: strands,
            scan: scan
        )
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
        let schedule = CorridorLaneSchedule.schedule(
            journeys: journeys,
            laneSpacingPoints: LaneHarness.laneSpacing
        )
        let schedLayouts = LaneHarness.scheduledLayouts(
            strands: strands,
            scan: scan,
            schedule: LaneHarness.rekeySchedule(schedule)
        )

        let ribbonsMain = mainLayouts.mapValues { LaneHarness.ribbon($0) }
        let ribbonsSched = schedLayouts.mapValues { LaneHarness.ribbon($0) }
        let crossingsMain = LaneHarness.countCrossings(ribbonsMain)
        let crossingsSched = LaneHarness.countCrossings(ribbonsSched)
        let (bundleMain, _) = LaneHarness.countBundleCrossings(
            mainLayouts,
            ribbonsMain
        )
        let (bundleSched, pairsSched) = LaneHarness.countBundleCrossings(
            schedLayouts,
            ribbonsSched
        )
        var spineFramesMain: [Int: LaneHarness.SpineFrame] = [:]
        var spineFramesSched: [Int: LaneHarness.SpineFrame] = [:]
        let wobbleMain = LaneHarness.bundleWobble(
            mainLayouts,
            strands: strands,
            scan: scan,
            spineFrames: &spineFramesMain
        )
        let wobbleSched = LaneHarness.bundleWobble(
            schedLayouts,
            strands: strands,
            scan: scan,
            spineFrames: &spineFramesSched
        )
        let separation = LaneHarness.minLaneSeparation(
            schedLayouts,
            strands: strands,
            scan: scan,
            spineFrames: &spineFramesSched
        )
        let sepMain = LaneHarness.minLaneSeparation(
            mainLayouts,
            strands: strands,
            scan: scan,
            spineFrames: &spineFramesMain
        )
        let kinkMain = mainLayouts.values.map {
            LaneHarness.alignmentKink($0)
        }.max() ?? 0
        let kinkSched = schedLayouts.values.map {
            LaneHarness.alignmentKink($0)
        }.max() ?? 0

        let pairText = pairsSched.map { pair in
            "\(strands[pair.0].num)/\(strands[pair.1].num)×\(pair.2)"
        }.joined(separator: ",")
        print(
            "LANE-CHECK \(scenario.name) crossings main=\(crossingsMain) "
                + "sched=\(crossingsSched) bundle main=\(bundleMain) "
                + "sched=\(bundleSched) pairs=[\(pairText)] "
                + "wobble main=\(String(format: "%.2f", wobbleMain)) "
                + "sched=\(String(format: "%.2f", wobbleSched)) "
                + "sep main=\(sepMain.map { String(format: "%.2f", $0) } ?? "nil") "
                + "sched=\(separation.map { String(format: "%.2f", $0) } ?? "nil") "
                + "kink main=\(String(format: "%.2f", kinkMain)) "
                + "sched=\(String(format: "%.2f", kinkSched))"
        )

        var problems: [String] = []
        if bundleSched > bundleMain {
            problems.append(
                "scheduler adds in-bundle crossings (\(bundleMain) -> \(bundleSched))"
            )
        }
        if bundleSched > scenario.maxBundle {
            problems.append(
                "strands cross inside the bundle (\(bundleSched) > "
                    + "\(scenario.maxBundle): \(pairText))"
            )
        }
        if let (probe, expectedNums) = scenario.expectOrder {
            let order = lateralOrder(
                strands: strands,
                schedule: schedule,
                probeArc: probe
            )
            let ok = order == expectedNums
            print(
                "LANE-CHECK \(scenario.name) lateral order "
                    + (ok ? "ok " : "BAD ")
                    + "[\(order.joined(separator: ", "))]"
            )
            if !ok {
                problems.append(
                    "lateral order [\(order.joined(separator: ", "))] "
                        + "!= [\(expectedNums.joined(separator: ", "))]"
                )
            }
        }
        if wobbleSched > max(0.05, wobbleMain) * 1.10 + 0.05 {
            problems.append(
                "continuing strands still wobble (\(wobbleSched) lanes, "
                    + "main \(wobbleMain))"
            )
        }
        let sepFloor = min(0.75, sepMain ?? 0.75) - 0.02 - scenario.sepSlack
        if let separation, separation < sepFloor {
            problems.append(
                "lanes overlap (\(separation), main \(sepMain.map(String.init) ?? "nil"))"
            )
        }
        if kinkSched > max(0.5, kinkMain) {
            problems.append(
                "alignment kink regresses (\(kinkMain) -> \(kinkSched) m)"
            )
        }
        if scenario.name == "couplet" {
            problems += directionContiguityProblems(
                strands: strands,
                layouts: schedLayouts,
                scan: scan
            )
        }
        return problems
    }

    /// The fanout gate: the scheduled lateral order at a probe arc.
    func lateralOrder(
        strands: [LaneHarness.Strand],
        schedule: [CorridorLaneSchedule.StrandKey: [Int: CorridorLaneSchedule.Sample]],
        probeArc: Double
    ) -> [String] {
        var entries: [(offset: Double, num: String)] = []
        for (index, strand) in strands.enumerated() {
            let arcs = strand.arc
            var bestSegment: Int?
            var bestDistance: Double?
            for si in 0..<strand.segments.count
            where strand.segments[si] != nil {
                let d = abs(arcs[si] - probeArc)
                if bestDistance == nil || d < bestDistance! {
                    bestDistance = d
                    bestSegment = si
                }
            }
            guard let si = bestSegment,
                  let entry = schedule[
                      CorridorLaneSchedule.StrandKey(
                          journeyID: index,
                          polylineIndex: 0
                      )
                  ]?[si]
            else { continue }
            entries.append((entry.offset, strand.num))
        }
        return entries
            .sorted { $0.offset < $1.offset }
            .map { $0.num }
    }

    /// Opposite-direction lanes may not sit between two same-direction
    /// lanes in the corridor stack.
    func directionContiguityProblems(
        strands: [LaneHarness.Strand],
        layouts: [Int: LaneHarness.Layout],
        scan: [[[LaneHarness.Match]]]
    ) -> [String] {
        var problems: [String] = []
        let ids = layouts.keys.sorted()
        for ii in 0..<ids.count {
            for jj in (ii + 1)..<ids.count {
                let a = ids[ii]
                let b = ids[jj]
                guard scan[a].contains(where: { row in
                    row.contains { $0.strandIndex == b }
                }) else { continue }
                // Direction relation via the first shared sample.
                var relation: Int?
                for (k, row) in scan[a].enumerated() {
                    if let hit = row.first(where: { $0.strandIndex == b }),
                       let segment = strands[a].segments[k] {
                        relation =
                            (segment.unitX * hit.segment.unitX
                                + segment.unitY * hit.segment.unitY) >= 0
                                ? 1 : -1
                        break
                    }
                }
                guard relation == -1 else { continue }
                let la = layouts[a]!
                let lb = layouts[b]!
                let lanesA: Set<Double> = Set(
                    zip(la.offsets, la.stacked).filter { $0.1 }
                        .map { ($0.0 / 2.1).rounded(.toNearestOrEven) }
                )
                let lanesB: Set<Double> = Set(
                    zip(lb.offsets, lb.stacked).filter { $0.1 }
                        .map { ($0.0 / 2.1).rounded(.toNearestOrEven) }
                )
                for ob in lanesB {
                    for o1 in lanesA {
                        for o2 in lanesA where o1 < ob && ob < o2 {
                            problems.append(
                                "opposite-direction \(strands[b].num) lane "
                                    + "interleave between \(strands[a].num) "
                                    + "lanes \(o1)..\(o2)"
                            )
                            return problems
                        }
                    }
                }
            }
        }
        return problems
    }

    // ------------------------------------------------------------------
    // The gate
    // ------------------------------------------------------------------

    func testLaneCheckScenarios() {
        var failures: [String] = []
        for scenario in scenarios() {
            let problems = evaluate(scenario)
            for problem in problems {
                print("LANE-CHECK \(scenario.name) FAIL \(problem)")
                failures.append("\(scenario.name): \(problem)")
            }
        }
        XCTAssertTrue(
            failures.isEmpty,
            "lane check RED: \(failures.joined(separator: "; "))"
        )
        print("LANE-CHECK done, \(failures.isEmpty ? "green" : "RED")")
    }
}
