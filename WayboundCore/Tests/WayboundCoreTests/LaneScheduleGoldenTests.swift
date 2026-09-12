import XCTest

@testable import WayboundCore

/// Golden tests: the pure-Swift lane scheduler must reproduce, from the
/// exported polylines alone, the anchored-lane schedule the shipped app's
/// scheduler chose when it exported the fixture.
///
/// This is the test that would have caught every real scheduler bug so far
/// (the for-in sort trap, the two meter scales, the stayer record seam):
/// those bugs all diverge the schedule the device computed from the schedule
/// the same algorithm computes over the same geometry. The oracle is the
/// `schedule` array of each export — offset, spine direction, and sticky
/// reference per strand segment.
///
/// Agreement cannot be exact: the port's membership scan is the package's
/// own (golden-pinned to the device's scan to within 0.03%/0.5% of rows),
/// and those row differences can cascade through run birth on a strand.
/// The gates below hold the port to small fractions on every fixture; a
/// ported algorithm change that shifts real schedules craters them.
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
            var portOnly = 0
            var portRows = 0
            for (_, entries) in port {
                portRows += entries.count
            }
            let exportedRows = doc.schedule.reduce(0) {
                $0 + $1.entries.count
            }
            for (key, entries) in port {
                let exportEntries = exported[key] ?? [:]
                for (segmentIndex, _) in entries
                where exportEntries[segmentIndex] == nil {
                    portOnly += 1
                }
            }

            let union = both + exportOnly + portOnly
            let agree = union > 0 ? Double(both) / Double(union) : 1
            var verdict = "OK"
            // First-generation gates: generous enough to absorb scan-row
            // noise (the package scan differs from the device scan on
            // <=0.5% of rows and that can cascade through a strand's
            // birth), tight enough that an algorithm divergence — the
            // for-in sort trap, meter scales, a stayer seam — craters
            // them. Tighten to the measured baseline as runs accumulate.
            let offShare = both > 0
                ? Double(offsetMismatch) / Double(both) : 0
            let refShare = both > 0
                ? Double(refMismatch) / Double(both) : 0
            if agree < 0.95 {
                verdict = "RED: row agreement below 95%"
                failures.append("\(url.lastPathComponent): agree \(agree)")
            }
            if offShare > 0.05 {
                verdict = "RED: too many offset mismatches"
                failures.append(
                    "\(url.lastPathComponent): offset \(offsetMismatch)/\(both)"
                )
            }
            if refShare > 0.10 {
                verdict = "RED: too many reference mismatches"
                failures.append(
                    "\(url.lastPathComponent): ref \(refMismatch)/\(both)"
                )
            }
            print(
                "SCHED-GOLDEN \(url.lastPathComponent) "
                    + "export=\(exportedRows) port=\(portRows) "
                    + "both=\(both) exportOnly=\(exportOnly) "
                    + "portOnly=\(portOnly) offsetMis=\(offsetMismatch) "
                    + "refMis=\(refMismatch) dirMis=\(dirMismatch) "
                    + "agree=\(String(format: "%.2f%%", agree * 100)) "
                    + verdict
            )
        }
        XCTAssertTrue(
            failures.isEmpty,
            "schedule golden mismatches: \(failures.joined(separator: "; "))"
        )
    }
}
