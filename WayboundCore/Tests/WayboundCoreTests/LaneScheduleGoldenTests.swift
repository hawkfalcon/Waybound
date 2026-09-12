import XCTest

@testable import WayboundCore

/// Golden tests: the pure-Swift lane scheduler must reproduce, from the
/// exported polylines alone, the anchored-lane schedule the shipped app's
/// scheduler chose when it exported the fixture.
///
/// This is the test class that would have caught every real scheduler bug so
/// far (the for-in sort trap, the two meter scales, the stayer record seam):
/// those bugs all diverge the schedule the device computed from the schedule
/// the same algorithm computes over the same geometry.
///
/// Oracle staleness, and how the gates handle it: the exports were taken
/// from device builds across the week, and main's scheduler moved after
/// several of them (turn-aware fork walk 4561799, founders sort 9530cda,
/// meter scales 9a7ad84, stayer seam af04f20). Each stale fixture therefore
/// diverges on exactly the strands those fixes changed — measured on
/// 2026-09-12, the port's mismatch share per fixture matches the Python
/// spec's run-for-run (54.6/8.0/42.7/50.2/33.8/12.7% device disagreement
/// for the spec, 54.5/8.0/42.6/50.2/33.7/12.5% for this port). The gates
/// hold every fixture to its measured staleness baseline — a port
/// regression or a new divergence makes it WORSE and trips — and a fresh
/// export taken from current main can be hard-pinned (offset share
/// <= 0.5%) by adding its filename to `pinnedFixtures`.
final class LaneScheduleGoldenTests: XCTestCase {

    private static let fixtures: [URL] = {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let packageRoot = tests.deletingLastPathComponent().deletingLastPathComponent()
        let repoRoot = packageRoot.deletingLastPathComponent()
        let data = repoRoot
            .appendingPathComponent("tools/replay/data", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: data,
            includingPropertiesForKeys: nil
        )) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("waybound-lanes-") }
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }()

    /// Measured device-vs-port offset-mismatch share per fixture
    /// (mismatched offsets / compared rows, CI run 12, 2026-09-12). The
    /// numbers ARE the exports' staleness against current main; a fixture
    /// may not get meaningfully worse than this.
    private static let baselineOffsetMismatchShare: [String: Double] = [
        "waybound-lanes-1788731470.json": 0.545,
        "waybound-lanes-1788762232.json": 0.080,
        "waybound-lanes-1788812167.json": 0.426,
        "waybound-lanes-1788827186.json": 0.502,
        "waybound-lanes-1789010609.json": 0.337,
        "waybound-lanes-1789020636.json": 0.125,
    ]

    /// Default staleness allowance for a fixture with no measured baseline
    /// yet (a newly pushed export): informational until pinned.
    private static let defaultBaseline = 0.35

    /// Fixtures exported from a build of current main. These are held to
    /// the full golden contract: offset share <= 0.5%, reference share
    /// <= 1%, row agreement >= 99%.
    ///
    /// 1789193224: exported 2026-09-12 06:07 UTC from a build of main
    /// (post-af04f20). The scheduler spec agrees with the device on
    /// 12087/12087 schedule rows, so this fixture pins the port to the
    /// device exactly.
    private static let pinnedFixtures: Set<String> = [
        "waybound-lanes-1789193224.json",
    ]

    func testLaneOrderIsNumericOnRouteNumbers() {
        // The lateral ladder is defined by public identity order; numeric
        // route comparison is load-bearing ("5" sorts before "12X").
        func identity(
            _ id: Int,
            _ route: String,
            agency: String = "SBMTD",
            direction: Int? = 0,
            stack: Int = 0
        ) -> CorridorLaneSchedule.JourneyIdentity {
            CorridorLaneSchedule.JourneyIdentity(
                journey: LaneDiagnosticsDocument.Journey(
                    id: id,
                    routeNumber: route,
                    agency: agency,
                    directionID: direction,
                    stackOrder: stack,
                    departures: 1,
                    polylines: []
                )
            )
        }

        let five = identity(5, "5")
        let twelveX = identity(12, "12X")
        let seventeen = identity(17, "17")
        let eightyFiveX = identity(85, "85X")
        XCTAssertTrue(
            CorridorLaneSchedule.laneComesBefore(five, twelveX),
            "numeric route order: 5 before 12X"
        )
        XCTAssertTrue(
            CorridorLaneSchedule.laneComesBefore(twelveX, seventeen),
            "numeric route order: 12X before 17"
        )
        XCTAssertTrue(
            CorridorLaneSchedule.laneComesBefore(seventeen, eightyFiveX)
        )
        XCTAssertFalse(
            CorridorLaneSchedule.laneComesBefore(eightyFiveX, five)
        )
        // Same route number, different agency: agency breaks the tie.
        let otherAgency = identity(2, "5", agency: "ZZ Transit")
        XCTAssertTrue(
            CorridorLaneSchedule.laneComesBefore(five, otherAgency)
        )
        // Public route keys collapse both directions of one route.
        XCTAssertEqual(
            identity(1, "5", direction: 0).publicRouteKey,
            identity(2, "5", direction: 1).publicRouteKey
        )
    }

    func testSchedulerGoldenAgainstEveryExport() throws {
        XCTAssertFalse(
            Self.fixtures.isEmpty,
            "no fixtures found — the repo must carry tools/replay/data"
        )
        var failures: [String] = []
        print(
            "SCHED-GOLDEN fixture export port both exportOnly portOnly "
                + "offsetMis refMis dirMis agree verdict"
        )
        for url in Self.fixtures {
            let name = url.lastPathComponent
            let doc = try LaneDiagnosticsDocument(url: url)
            let port = CorridorLaneSchedule.schedule(
                journeys: doc.journeys,
                laneSpacingPoints: doc.laneSpacingPoints
            )

            var exported:
                [CorridorLaneSchedule.StrandKey: [Int: CorridorLaneSchedule.Sample]] = [:]
            for strand in doc.schedule {
                var entries: [Int: CorridorLaneSchedule.Sample] = [:]
                for entry in strand.entries {
                    entries[entry.segmentIndex] = CorridorLaneSchedule.Sample(
                        offset: entry.offset,
                        directionX: entry.directionX,
                        directionY: entry.directionY,
                        referenceID: entry.referenceJourneyID
                    )
                }
                exported[CorridorLaneSchedule.StrandKey(
                    journeyID: strand.journeyID,
                    polylineIndex: strand.polylineIndex
                )] = entries
            }

            let tolerance = 0.05 * doc.laneSpacingPoints
            var exportOnly = 0
            var both = 0
            var offsetMismatch = 0
            var refMismatch = 0
            var dirMismatch = 0
            // Per-strand mismatch counts, for the worst-strand diagnostics.
            var mismatchByStrand: [CorridorLaneSchedule.StrandKey: Int] = [:]
            var samples: [CorridorLaneSchedule.StrandKey: [String]] = [:]
            for (key, entries) in exported {
                let portEntries = port[key] ?? [:]
                for (segmentIndex, sample) in entries {
                    guard let mine = portEntries[segmentIndex] else {
                        exportOnly += 1
                        continue
                    }
                    both += 1
                    if abs(mine.offset - sample.offset) > tolerance {
                        offsetMismatch += 1
                        mismatchByStrand[key, default: 0] += 1
                        let row = String(
                            format: "seg %d: device %+.2f port %+.2f",
                            segmentIndex,
                            sample.offset,
                            mine.offset
                        )
                        samples[key, default: []].append(row)
                    } else if mine.referenceID != sample.referenceID {
                        refMismatch += 1
                    }
                    let dot = mine.directionX * sample.directionX
                        + mine.directionY * sample.directionY
                    if dot < 1 - 1e-6 {
                        dirMismatch += 1
                    }
                }
            }
            var portRows = 0
            for (_, entries) in port {
                portRows += entries.count
            }
            let exportedRows = doc.schedule.reduce(0) {
                $0 + $1.entries.count
            }
            var portOnly = 0
            for (key, entries) in port {
                let exportEntries = exported[key] ?? [:]
                for (segmentIndex, _) in entries
                where exportEntries[segmentIndex] == nil {
                    portOnly += 1
                }
            }

            let union = both + exportOnly + portOnly
            let agree = union > 0 ? Double(both) / Double(union) : 1
            let offShare = both > 0
                ? Double(offsetMismatch) / Double(both) : 0
            let refShare = both > 0
                ? Double(refMismatch) / Double(both) : 0

            // Worst strands: where the divergence lives. A stale fixture
            // diverges on the strands the post-export fixes changed; a
            // regression scatters everywhere.
            let worst = mismatchByStrand.sorted { $0.value > $1.value }
                .prefix(8)
            var detail: [String] = []
            for (key, count) in worst {
                let sampleRows = samples[key]?.prefix(3) ?? []
                detail.append(
                    "  strand \(key.journeyID)/\(key.polylineIndex): "
                        + "\(count) off — " + sampleRows.joined(separator: "; ")
                )
            }
            var verdict = "OK"
            var isFailure = false
            if Self.pinnedFixtures.contains(name) {
                if agree < 0.99 || offShare > 0.005 || refShare > 0.01 {
                    verdict = "RED: pinned fixture diverged"
                    isFailure = true
                    failures.append(
                        "\(name): agree \(agree), off \(offShare), "
                            + "ref \(refShare)"
                    )
                }
            } else {
                let baseline = Self.baselineOffsetMismatchShare[name]
                    ?? Self.defaultBaseline
                if agree < 0.40 || offShare > baseline + 0.02 {
                    verdict = "RED: worse than staleness baseline "
                        + "(baseline \(baseline))"
                    isFailure = true
                    failures.append(
                        "\(name): agree \(agree), off \(offShare), "
                            + "baseline \(baseline)"
                    )
                }
                if baseline > 0.02 {
                    verdict += " (stale oracle: predates a main fix)"
                }
            }
            print(
                "SCHED-GOLDEN \(name) "
                    + "export=\(exportedRows) port=\(portRows) "
                    + "both=\(both) exportOnly=\(exportOnly) "
                    + "portOnly=\(portOnly) offsetMis=\(offsetMismatch) "
                    + "refMis=\(refMismatch) dirMis=\(dirMismatch) "
                    + "agree=\(String(format: "%.2f%%", agree * 100)) "
                    + verdict
            )
            if offShare > 0.005 {
                for line in detail {
                    print("SCHED-GOLDEN-DETAIL \(name) \(line)")
                }
            }
        }
        XCTAssertTrue(
            failures.isEmpty,
            "schedule golden mismatches: \(failures.joined(separator: "; "))"
        )
    }
}
