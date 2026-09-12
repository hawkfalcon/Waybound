import XCTest

@testable import WayboundCore

/// Golden tests: the pure-Swift layout stage must reproduce, from the
/// exported schedule + polylines alone, the per-vertex lane structure the
/// device's layout pass produced when it exported the fixture: offsets,
/// shared flags, and trunk-owner flags per strand vertex.
///
/// The schedule is fed from the export itself, which isolates the layout
/// port from schedule staleness: the older fixtures were drawn by device
/// builds whose LAYOUT passes also moved since (street-anchored anchors
/// 8da64de on 09-07, hairpin decays 4561799 on 09-08), so those diverge
/// where those passes changed and are held to measured baselines. The
/// newest fixture (1789193224, exported from current main) is pinned:
/// the layout passes have not changed since it was drawn, so the port
/// must match it at scan-noise tolerances (the package's membership scan
/// differs from the device's on <=0.5% of rows, which is the one
/// remaining divergence source).
final class LaneLayoutGoldenTests: XCTestCase {

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

    /// Fixtures exported from a build whose layout passes match current
    /// main. Held to scan-noise tolerances: offset share <= 0.5%, shared
    /// <= 0.5%, trunk <= 1%.
    private static let pinnedFixtures: Set<String> = [
        "waybound-lanes-1789193224.json",
    ]

    /// Measured offset-mismatch shares for fixtures drawn before the last
    /// layout-pass changes (baseline gates: a regression gets worse and
    /// trips). Updated from the first CI run's table.
    private static let baselineOffsetMismatchShare: [String: Double] = [:]

    /// Default staleness allowance for an unpinned, unmeasured fixture.
    private static let defaultBaseline = 0.35

    func testBridgeAndTaperShapeOnASyntheticStrand() {
        // A 300 m east-west strand with one 90 m shared run in the middle:
        // the run holds its schedule lane, the ends taper toward zero, and
        // a short dropout inside the run bridges at the same lane.
        let laneSpacing = 4.2
        func coordinate(atMeters m: Double) -> GeoCoordinate {
            // ~1 degree of longitude ≈ 91.5 km at 34.42° N.
            GeoCoordinate(
                latitude: 34.42,
                longitude: -119.7 + m / 91_500
            )
        }
        let coordinates = (0...30).map { coordinate(atMeters: Double($0) * 10) }
        let journey = LaneDiagnosticsDocument.Journey(
            id: 1,
            routeNumber: "1",
            agency: "T",
            directionID: 0,
            stackOrder: 0,
            departures: 1,
            polylines: [coordinates]
        )
        let key = CorridorLaneSchedule.StrandKey(journeyID: 1, polylineIndex: 0)
        // Schedule: segments 10..<19 (vertices 10..19) share at half a
        // lane against due-east travel; segments 20..<24 are a dropout
        // the stage does NOT schedule (no entries) — the bridge decides.
        var schedule: [CorridorLaneSchedule.StrandKey: [Int: CorridorLaneSchedule.Sample]] = [:]
        schedule[key] = [:]
        for segmentIndex in 10..<19 {
            schedule[key]?[segmentIndex] = CorridorLaneSchedule.Sample(
                offset: laneSpacing / 2,
                directionX: 1,
                directionY: 0,
                referenceID: 1
            )
        }

        // With only one journey there is no corridor: nothing is shared.
        let alone = CorridorLaneLayoutEngine.layouts(
            journeys: [journey],
            schedule: schedule,
            selectedJourneyID: nil,
            laneSpacingPoints: laneSpacing
        )
        XCTAssertEqual(alone[key]?.offsets.count, coordinates.count)
        XCTAssertTrue(
            (alone[key]?.shared ?? []).allSatisfy { !$0 },
            "a strand with no members shares nothing regardless of schedule"
        )

        // Add a companion running the same street: now the run is shared.
        let companion = LaneDiagnosticsDocument.Journey(
            id: 2,
            routeNumber: "2",
            agency: "T",
            directionID: 0,
            stackOrder: 1,
            departures: 1,
            polylines: [coordinates]
        )
        let shared = CorridorLaneLayoutEngine.layouts(
            journeys: [journey, companion],
            schedule: schedule,
            selectedJourneyID: nil,
            laneSpacingPoints: laneSpacing
        )
        let layout = shared[key]
        XCTAssertEqual(layout?.offsets.count, coordinates.count)
        // Vertices 10..19 (inside the scheduled run) carry the lane.
        for vertex in 10...19 {
            XCTAssertTrue(
                layout?.shared[vertex] ?? false,
                "vertex \(vertex) inside the scheduled run must be shared"
            )
        }
        // Vertices well outside the run taper to under a twentieth of a
        // lane (taper reaches 58 m at 10 m/segment ≈ 6 vertices).
        for vertex in 0...3 {
            XCTAssertLessThan(
                abs(layout?.offsets[vertex] ?? 99),
                0.05 * laneSpacing,
                "vertex \(vertex) is outside the taper reach"
            )
        }
        // The trunk belongs to the dominant public route: route 2 sorts
        // after route 1 numerically but both have one departure, so stack
        // order decides — journey 2 (stack 1) does NOT own the trunk.
        XCTAssertEqual(shared[CorridorLaneSchedule.StrandKey(
            journeyID: 2, polylineIndex: 0
        )]?.trunk.first(where: { $0 }), nil)
    }

    func testLayoutGoldenAgainstEveryExport() throws {
        XCTAssertFalse(
            Self.fixtures.isEmpty,
            "no fixtures found — the repo must carry tools/replay/data"
        )
        var failures: [String] = []
        print(
            "LAYOUT-GOLDEN fixture verts offMis sharedMis trunkMis "
                + "strands missing verdict"
        )
        for url in Self.fixtures {
            let name = url.lastPathComponent
            let doc = try LaneDiagnosticsDocument(url: url)

            var schedule:
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
                schedule[CorridorLaneSchedule.StrandKey(
                    journeyID: strand.journeyID,
                    polylineIndex: strand.polylineIndex
                )] = entries
            }

            let port = CorridorLaneLayoutEngine.layouts(
                journeys: doc.journeys,
                schedule: schedule,
                selectedJourneyID: doc.selectedJourneyID,
                laneSpacingPoints: doc.laneSpacingPoints
            )

            let tolerance = 0.05 * doc.laneSpacingPoints
            var vertices = 0
            var offsetMismatch = 0
            var sharedMismatch = 0
            var trunkMismatch = 0
            var missingStrands = 0
            for layout in doc.layouts {
                let key = CorridorLaneSchedule.StrandKey(
                    journeyID: layout.journeyID,
                    polylineIndex: layout.polylineIndex
                )
                guard let mine = port[key] else {
                    missingStrands += 1
                    continue
                }
                guard mine.offsets.count == layout.offsets.count,
                      mine.shared.count == layout.shared.count,
                      mine.trunk.count == layout.trunk.count
                else {
                    missingStrands += 1
                    continue
                }
                for index in 0..<layout.offsets.count {
                    vertices += 1
                    if abs(mine.offsets[index] - layout.offsets[index])
                        > tolerance {
                        offsetMismatch += 1
                    }
                    if mine.shared[index] != layout.shared[index] {
                        sharedMismatch += 1
                    }
                    if mine.trunk[index] != layout.trunk[index] {
                        trunkMismatch += 1
                    }
                }
            }

            let offShare = vertices > 0
                ? Double(offsetMismatch) / Double(vertices) : 0
            let sharedShare = vertices > 0
                ? Double(sharedMismatch) / Double(vertices) : 0
            let trunkShare = vertices > 0
                ? Double(trunkMismatch) / Double(vertices) : 0

            var verdict = "OK"
            if Self.pinnedFixtures.contains(name) {
                if offShare > 0.005 || sharedShare > 0.005
                    || trunkShare > 0.01 || missingStrands > 0 {
                    verdict = "RED: pinned fixture diverged"
                    failures.append(
                        "\(name): off \(offShare), shared \(sharedShare), "
                            + "trunk \(trunkShare), missing \(missingStrands)"
                    )
                }
            } else {
                let baseline = Self.baselineOffsetMismatchShare[name]
                    ?? Self.defaultBaseline
                if offShare > baseline + 0.02 || missingStrands > 0 {
                    verdict = "RED: worse than staleness baseline "
                        + "(baseline \(baseline))"
                    failures.append(
                        "\(name): off \(offShare), baseline \(baseline)"
                    )
                } else if baseline > 0.02 {
                    verdict += " (stale oracle: predates a layout fix)"
                }
            }
            print(
                "LAYOUT-GOLDEN \(name) verts=\(vertices) "
                    + "offMis=\(offsetMismatch)(\(String(format: "%.2f%%", offShare * 100))) "
                    + "sharedMis=\(sharedMismatch) trunkMis=\(trunkMismatch) "
                    + "strands=\(doc.layouts.count - missingStrands)/\(doc.layouts.count) "
                    + verdict
            )
        }
        XCTAssertTrue(
            failures.isEmpty,
            "layout golden mismatches: \(failures.joined(separator: "; "))"
        )
    }
}
