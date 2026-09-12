import XCTest

@testable import WayboundCore

/// Golden tests: the pure-Swift membership scan must reproduce, on the
/// device-exported fixtures, the sharing structure the shipped app's scan
/// produced when it exported them.
///
/// Oracle: every schedule entry in an export exists because the app's own
/// scan found corridor mates at that segment (the only exception being the
/// handful of gap-bridge rows the scheduler fills over scan dropouts), and
/// every scan-shared row in a viable run got an entry (short runs under
/// 30 m are pruned before recording). Measured against all six exports the
/// disagreement is under 0.5% in both directions — so the gates here hold
/// the port to that contract. If a gate constant, tie-break, or grid rule
/// drifts, these numbers crater and the test goes red.
final class ScanGoldenTests: XCTestCase {

    private static let fixtures: [URL] = {
        // <root>/WayboundCore/Tests/WayboundCoreTests/ScanGoldenTests.swift
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

    private var fixtureURLs: [URL] {
        Self.fixtures.isEmpty ? [] : Self.fixtures
    }

    func testDensifySubdividesOnlyLongEdges() {
        let base = GeoCoordinate(latitude: 34.4208, longitude: -119.7000)
        // ~100 m east of base
        let far = GeoCoordinate(
            latitude: base.latitude,
            longitude: base.longitude + 0.0011
        )
        let short = [base, GeoCoordinate(
            latitude: base.latitude,
            longitude: base.longitude + 0.0001
        )]
        XCTAssertEqual(
            CorridorMembership.densify(short).count,
            2,
            "edges at or under 18 m pass through untouched"
        )
        let long = CorridorMembership.densify([base, far])
        XCTAssertGreaterThan(long.count, 2)
        // Subdivision count matches ceil(ground distance / 18): the
        // 0.0011-degree step is ~101 m, so 6 subdivisions -> 7 points.
        XCTAssertEqual(long.count, 7)
        XCTAssertEqual(long.first, base)
        XCTAssertEqual(long.last?.latitude ?? 0, far.latitude, accuracy: 1e-9)
        XCTAssertEqual(long.last?.longitude ?? 0, far.longitude, accuracy: 1e-9)
    }

    func testScanGoldenAgainstEveryExport() throws {
        XCTAssertFalse(
            fixtureURLs.isEmpty,
            "no fixtures found — the repo must carry tools/replay/data"
        )
        var failures: [String] = []
        print("SCAN-GOLDEN fixture both sched-only scan-only verdict")
        for url in fixtureURLs {
            let doc = try LaneDiagnosticsDocument(url: url)
            let scan = CorridorMembership.scan(
                journeys: doc.journeys,
                laneSpacingPoints: doc.laneSpacingPoints
            )

            var scanRows = Set<Row>()
            for (key, strandRows) in scan.rows {
                for (segmentIndex, row) in strandRows.enumerated() {
                    if !row.isEmpty {
                        scanRows.insert(
                            Row(key.journeyID, key.polylineIndex, segmentIndex)
                        )
                    }
                }
            }
            var schedRows = Set<Row>()
            for strand in doc.schedule {
                for entry in strand.entries {
                    schedRows.insert(
                        Row(
                            strand.journeyID,
                            strand.polylineIndex,
                            entry.segmentIndex
                        )
                    )
                }
            }

            let both = scanRows.intersection(schedRows).count
            let schedOnly = schedRows.subtracting(scanRows).count
            let scanOnly = scanRows.subtracting(schedRows).count

            // Measured maxima across all exports: sched-only 0.03% of
            // schedule rows, scan-only 0.5% of scan rows. Gates hold an
            // order of magnitude of headroom.
            let schedOnlyShare = Double(schedOnly)
                / Double(max(1, schedRows.count))
            let scanOnlyShare = Double(scanOnly)
                / Double(max(1, scanRows.count))
            var verdict = "OK"
            if schedOnlyShare > 0.01 || both < Int(Double(schedRows.count) * 0.99) {
                verdict = "RED: schedule rows unexplained by the scan"
                failures.append("\(url.lastPathComponent): sched-only \(schedOnly)")
            }
            if scanOnlyShare > 0.02 {
                verdict = "RED: scan rows the app never scheduled"
                failures.append("\(url.lastPathComponent): scan-only \(scanOnly)")
            }
            print(
                "SCAN-GOLDEN \(url.lastPathComponent) both=\(both) "
                    + "sched-only=\(schedOnly)(\(String(format: "%.2f%%", schedOnlyShare * 100))) "
                    + "scan-only=\(scanOnly)(\(String(format: "%.2f%%", scanOnlyShare * 100))) "
                    + verdict
            )
        }
        XCTAssertTrue(
            failures.isEmpty,
            "scan golden mismatches: \(failures.joined(separator: "; "))"
        )
    }

    private struct Row: Hashable {
        let journeyID: Int
        let polylineIndex: Int
        let segmentIndex: Int

        init(_ journeyID: Int, _ polylineIndex: Int, _ segmentIndex: Int) {
            self.journeyID = journeyID
            self.polylineIndex = polylineIndex
            self.segmentIndex = segmentIndex
        }
    }
}
