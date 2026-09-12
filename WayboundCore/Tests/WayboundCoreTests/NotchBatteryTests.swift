import XCTest

@testable import WayboundCore

/// Regression battery for the stop-connector notch stage, ported from
/// `battery.py` (now gone; this is its successor).
///
///   MUST-DELETE: the stop coordinate is gone and every surviving vertex is
///   still on the input street polyline (≤ 1 m) — deletions are
///   street-aligned by construction.
///   MUST-KEEP:   output is the input, unchanged.
final class NotchBatteryTests: XCTestCase {

    private var dataDirectory: URL {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let packageRoot = tests.deletingLastPathComponent().deletingLastPathComponent()
        let repoRoot = packageRoot.deletingLastPathComponent()
        return repoRoot
            .appendingPathComponent("tools/replay/data", isDirectory: true)
    }

    private let baseLatitude = 34.4208
    private let baseLongitude = -119.7000

    /// Local meter-framed coordinate fixture.
    private func coordinate(north: Double, east: Double) -> GeoCoordinate {
        GeoCoordinate(
            latitude: baseLatitude + north / 111_320.0,
            longitude: baseLongitude
                + east / (111_320.0 * cos(baseLatitude * .pi / 180))
        )
    }

    private func clean(_ output: [GeoCoordinate])
        -> [ProjectedPoint] {
        output.map { $0.projected }
    }

    private func maxStreetOffset(
        _ path: [GeoCoordinate],
        _ output: [GeoCoordinate]
    ) -> Double {
        let street = path.map { $0.projected }
        let metersPerUnit = GeoProjection.metersPerUnit(
            atLatitude: path[0].latitude
        )
        return output.map { point in
            NotchStage.distanceToPolyline(point.projected, street)
                * metersPerUnit
        }.max() ?? 0
    }

    private func stopsGone(
        _ output: [GeoCoordinate],
        _ stops: [GeoCoordinate]
    ) -> Bool {
        stops.allSatisfy { stop in
            !output.contains { point in
                abs(point.latitude - stop.latitude) < 1e-12
                    && abs(point.longitude - stop.longitude) < 1e-12
            }
        }
    }

    private func mustDelete(
        _ name: String,
        _ path: [GeoCoordinate],
        _ stops: [GeoCoordinate],
        expectCount: Int? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let out = NotchStage.removingStopConnectorNotches(path, stops)
        var ok = stopsGone(out, stops) && maxStreetOffset(path, out) <= 1.0
        if let expectCount { ok = ok && out.count == expectCount }
        XCTAssertTrue(
            ok,
            "delete: \(name) — \(path.count) -> \(out.count) pts, "
                + "worst street offset \(maxStreetOffset(path, out)) m",
            file: file,
            line: line
        )
    }

    private func mustKeep(
        _ name: String,
        _ path: [GeoCoordinate],
        _ stops: [GeoCoordinate],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let out = NotchStage.removingStopConnectorNotches(path, stops)
        let unchanged = out.count == path.count && zip(out, path).allSatisfy {
            abs($0.latitude - $1.latitude) < 1e-12
                && abs($0.longitude - $1.longitude) < 1e-12
        }
        XCTAssertTrue(
            unchanged,
            "keep: \(name) — \(path.count) -> \(out.count) pts",
            file: file,
            line: line
        )
    }

    func testMustDeleteFixtures() {
        mustDelete(
            "dense V (route-3 downtown form)",
            [
                coordinate(north: 0, east: 0), coordinate(north: 0, east: 40),
                coordinate(north: 0, east: 80), coordinate(north: 0, east: 100),
                coordinate(north: 10, east: 100),
                coordinate(north: 0, east: 128),
                coordinate(north: 0, east: 160),
                coordinate(north: 0, east: 220),
            ],
            [coordinate(north: 10, east: 100)],
            expectCount: 7
        )
        mustDelete(
            "shallow near-exact return (published oab form)",
            [
                coordinate(north: 0, east: 0),
                coordinate(north: 0, east: 60),
                coordinate(north: 0, east: 120),
                coordinate(north: 8, east: 120),
                coordinate(north: 0, east: 124),
                coordinate(north: 0, east: 200),
            ],
            [coordinate(north: 8, east: 120)],
            expectCount: 4
        )
        var comb: [GeoCoordinate] = [coordinate(north: 0, east: 0)]
        for east in stride(from: 80, through: 400, by: 80) {
            comb += [
                coordinate(north: 0, east: east),
                coordinate(north: 12, east: east),
                coordinate(north: 0, east: east + 40),
            ]
        }
        comb.append(coordinate(north: 0, east: 460))
        mustDelete(
            "comb of five (pass iterates)",
            comb,
            stride(from: 80, through: 400, by: 80).map {
                coordinate(north: 12, east: $0)
            },
            expectCount: 8
        )
        mustDelete(
            "sparse V (re-entry vertex 100 m on; route-2 form)",
            [
                coordinate(north: 0, east: 0),
                coordinate(north: 0, east: 100),
                coordinate(north: 0, east: 200),
                coordinate(north: 9, east: 200),
                coordinate(north: 0, east: 300),
                coordinate(north: 0, east: 420),
            ],
            [coordinate(north: 9, east: 200)],
            expectCount: 5
        )
        mustDelete(
            "very sparse V (re-entry vertex 200 m on; route-20/14 form)",
            [
                coordinate(north: 0, east: 0),
                coordinate(north: 0, east: 150),
                coordinate(north: 0, east: 300),
                coordinate(north: 9, east: 300),
                coordinate(north: 0, east: 500),
                coordinate(north: 0, east: 650),
            ],
            [coordinate(north: 9, east: 300)],
            expectCount: 5
        )
        mustDelete(
            "noisy V (re-entry drifts 4 m sideways)",
            [
                coordinate(north: 0, east: 0),
                coordinate(north: 0, east: 100),
                coordinate(north: 10, east: 106),
                coordinate(north: 4, east: 132),
                coordinate(north: 4, east: 230),
                coordinate(north: 4, east: 330),
            ],
            [coordinate(north: 12, east: 112)]
        )
        mustDelete(
            "terminal connector at the end",
            [
                coordinate(north: 0, east: 0),
                coordinate(north: 0, east: 100),
                coordinate(north: 0, east: 200),
                coordinate(north: 0, east: 300),
                coordinate(north: 10, east: 300),
            ],
            [coordinate(north: 10, east: 300)],
            expectCount: 4
        )
        mustDelete(
            "terminal connector at the start",
            [
                coordinate(north: 10, east: 0),
                coordinate(north: 0, east: 0),
                coordinate(north: 0, east: 100),
                coordinate(north: 0, east: 200),
                coordinate(north: 0, east: 300),
            ],
            [coordinate(north: 10, east: 0)],
            expectCount: 4
        )
        mustDelete(
            "two-vertex terminal tail (perpendicular, both points at the stop)",
            [
                coordinate(north: 0, east: 0),
                coordinate(north: 0, east: 100),
                coordinate(north: 0, east: 200),
                coordinate(north: 0, east: 290),
                coordinate(north: 8, east: 290),
                coordinate(north: 16, east: 290),
            ],
            [coordinate(north: 16, east: 290)],
            expectCount: 4
        )
    }

    func testMustKeepFixtures() {
        mustKeep(
            "block jog with a stop at the corner",
            [
                coordinate(north: 0, east: 0),
                coordinate(north: 100, east: 0),
                coordinate(north: 100, east: 40),
                coordinate(north: 220, east: 40),
                coordinate(north: 320, east: 40),
            ],
            [coordinate(north: 100, east: 40)]
        )
        mustKeep(
            "asymmetric corner with a stop at the bend",
            [
                coordinate(north: 0, east: 0),
                coordinate(north: 0, east: 60),
                coordinate(north: 0, east: 120),
                coordinate(north: 180, east: 120),
                coordinate(north: 180, east: 300),
            ],
            [coordinate(north: 4, east: 116)]
        )
        mustKeep(
            "90-degree corner with a stop beside the apex",
            [
                coordinate(north: 0, east: 0),
                coordinate(north: 0, east: 80),
                coordinate(north: 0, east: 160),
                coordinate(north: 80, east: 160),
                coordinate(north: 160, east: 160),
                coordinate(north: 160, east: 240),
            ],
            [coordinate(north: 8, east: 156)]
        )
        mustKeep(
            "hairpin turnaround serving a stop",
            [
                coordinate(north: 0, east: 0),
                coordinate(north: 0, east: 60),
                coordinate(north: 0, east: 100),
                coordinate(north: 18, east: 104),
                coordinate(north: 0, east: 108),
                coordinate(north: 0, east: 30),
            ],
            [coordinate(north: 18, east: 104)]
        )
        let r150: [GeoCoordinate] = stride(from: -23, through: 24, by: 5)
            .map { degrees in
                let t = Double(degrees)
                return coordinate(
                    north: 150 - 150 * (1 - cos(t * .pi / 180)),
                    east: 150 * sin(t * .pi / 180)
                )
            }
        mustKeep(
            "R150 curve with a stop outside the mid-curve",
            r150,
            [coordinate(north: 8, east: 0)]
        )
        let r250: [GeoCoordinate] = stride(from: -14, through: 15, by: 2)
            .map { degrees in
                let t = Double(degrees)
                return coordinate(
                    north: 60 - 250 * (1 - cos(t * .pi / 180)),
                    east: 250 * sin(t * .pi / 180)
                )
            }
        mustKeep(
            "R250 crest with a stop beyond the apex",
            r250,
            [coordinate(north: 68, east: 0)]
        )
        mustKeep(
            "sparse shallow S-bow with a stop at the apex (steep-leg gate)",
            [
                coordinate(north: 0, east: -60),
                coordinate(north: 0, east: 0),
                coordinate(north: 12, east: 55),
                coordinate(north: 0, east: 110),
                coordinate(north: 0, east: 210),
            ],
            [coordinate(north: 22, east: 60)]
        )
        mustKeep(
            "45-degree terminal approach to a stop",
            [
                coordinate(north: 0, east: 0),
                coordinate(north: 0, east: 120),
                coordinate(north: 0, east: 180),
                coordinate(north: 60, east: 240),
            ],
            [coordinate(north: 60, east: 240)]
        )
        mustKeep(
            "straight-in terminal stop",
            [
                coordinate(north: 0, east: 0),
                coordinate(north: 0, east: 120),
                coordinate(north: 0, east: 240),
                coordinate(north: 0, east: 300),
            ],
            [coordinate(north: 0, east: 300)]
        )
        mustKeep(
            "parallel bay/terminal entry (indistinguishable from service)",
            [
                coordinate(north: 0, east: 0),
                coordinate(north: 0, east: 100),
                coordinate(north: 0, east: 200),
                coordinate(north: 10, east: 260),
                coordinate(north: 10, east: 320),
            ],
            [coordinate(north: 10, east: 320)]
        )
    }

    func testPropertyOnRealTrace() throws {
        let url = dataDirectory.appendingPathComponent("route_6dt.json")
        let raw = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)
        ) as! [[Double]]
        let trace = raw.map {
            GeoCoordinate(latitude: $0[0], longitude: $0[1])
        }

        let identity = NotchStage.removingStopConnectorNotches(trace, [])
        XCTAssertEqual(
            identity.count,
            trace.count,
            "real \(trace.count)-pt OSRM trace: inert without stops"
        )

        // Stops 1 m beside every tenth vertex: the cleaner may delete, but
        // only onto the street it already had — the structural safety
        // property.
        let spread = trace[5...].enumerated()
            .filter { $0.offset % 10 == 0 }
            .map { GeoCoordinate(
                latitude: $0.element.latitude + 1.0 / 111_320.0,
                longitude: $0.element.longitude
            ) }
        let touched = NotchStage.removingStopConnectorNotches(trace, spread)
        XCTAssertLessThanOrEqual(
            maxStreetOffset(trace, touched),
            1.2,
            "real trace with stops: every survivor on the original street "
                + "(\(trace.count) -> \(touched.count) pts)"
        )
    }

    func testRealBakedConnectors() throws {
        let url = dataDirectory
            .appendingPathComponent("baked_fragments_1420.json")
        let root = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)
        ) as! [String: Any]
        let fragments = try XCTUnwrap(root["fragments"] as? [[String: Any]])
        for fragment in fragments {
            let name = try XCTUnwrap(fragment["name"] as? String)
            let rawPts = try XCTUnwrap(fragment["pts"] as? [[Double]])
            let pts = rawPts.map {
                GeoCoordinate(latitude: $0[0], longitude: $0[1])
            }
            let rawStop = try XCTUnwrap(fragment["stop"] as? [Double])
            let stop = GeoCoordinate(
                latitude: rawStop[0],
                longitude: rawStop[1]
            )
            let expect = try XCTUnwrap(fragment["expect"] as? String)
            let out = NotchStage.removingStopConnectorNotches(pts, [stop])
            let stopGone = !out.contains { point in
                abs(point.latitude - stop.latitude) < 1e-12
                    && abs(point.longitude - stop.longitude) < 1e-12
            }
            let street = pts.filter { point in
                abs(point.latitude - stop.latitude) > 1e-12
                    || abs(point.longitude - stop.longitude) > 1e-12
            }.map { $0.projected }
            let metersPerUnit = GeoProjection.metersPerUnit(
                atLatitude: pts[0].latitude
            )
            let offset = out.map { point in
                NotchStage.distanceToPolyline(point.projected, street)
                    * metersPerUnit
            }.max() ?? 0
            var ok: Bool
            switch expect {
            case "delete":
                ok = stopGone && offset <= 1.0 && out.count == pts.count - 2
            case "trim":
                ok = stopGone && offset <= 1.0 && out.count == pts.count - 1
            default:
                ok = out.count == pts.count
            }
            XCTAssertTrue(
                ok,
                "SBMTD \(name): \(pts.count) -> \(out.count) pts, "
                    + "stop gone: \(stopGone), street offset \(offset) m"
            )
        }
    }
}
