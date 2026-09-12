import XCTest

@testable import WayboundCore

/// Scenario geometry builders: the lane-check scenarios model the downtown
/// Santa Barbara patterns that matter (state trunk bundle, one-way couplet,
/// boarding-stop bundle, dropout-and-return, fork, fan-out, reversed spine,
/// the real Chapala × Sola handoff). Verbatim ports of `lane_check.py`'s
/// builders — same control points, same stubs, same drift injection.
enum LaneScenarios {

    static let baseLatitude = 34.4209
    static let baseLongitude = -119.7033
    static let metersPerMapPoint = GeoProjection.metersPerUnit(
        atLatitude: baseLatitude
    )
    static let origin = GeoCoordinate(
        latitude: baseLatitude,
        longitude: baseLongitude
    ).projected

    /// Local east/north metres -> lat/lon via the mercator map-point frame.
    static func coordinate(east x: Double, north y: Double) -> GeoCoordinate {
        GeoCoordinate.fromProjected(ProjectedPoint(
            x: origin.x + x / metersPerMapPoint,
            y: origin.y - y / metersPerMapPoint
        ))
    }

    static func polyline(_ points: [(x: Double, y: Double)]) -> [GeoCoordinate] {
        points.map { coordinate(east: $0.x, north: $0.y) }
    }

    /// Densified smooth spine through control points (metres, x east y north).
    static func spinePoints(_ control: [(x: Double, y: Double)])
        -> [(x: Double, y: Double)] {
        var pts: [(x: Double, y: Double)] = []
        for i in 0..<(control.count - 1) {
            let (x0, y0) = control[i]
            let (x1, y1) = control[i + 1]
            let d = ((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0))
                .squareRoot()
            let steps = max(1, Int(d / 40))
            for s in 0..<steps {
                let t = Double(s) / Double(steps)
                pts.append((x0 + (x1 - x0) * t, y0 + (y1 - y0) * t))
            }
        }
        pts.append(control[control.count - 1])
        return pts
    }

    static func arcOf(_ points: [(x: Double, y: Double)]) -> [Double] {
        var arcs = [0.0]
        for i in 1..<points.count {
            let dx = points[i].x - points[i - 1].x
            let dy = points[i].y - points[i - 1].y
            arcs.append(arcs.last! + (dx * dx + dy * dy).squareRoot())
        }
        return arcs
    }

    static func pointAt(
        _ spine: [(x: Double, y: Double)],
        _ arcs: [Double],
        _ target: Double
    ) -> (x: Double, y: Double, dx: Double, dy: Double) {
        for i in 1..<spine.count {
            if arcs[i] >= target {
                let t = (target - arcs[i - 1])
                    / max(arcs[i] - arcs[i - 1], 1e-9)
                return (
                    spine[i - 1].x + (spine[i].x - spine[i - 1].x) * t,
                    spine[i - 1].y + (spine[i].y - spine[i - 1].y) * t,
                    spine[i].x - spine[i - 1].x,
                    spine[i].y - spine[i - 1].y
                )
            }
        }
        let last = spine[spine.count - 1]
        return (last.x, last.y, 0.001, 0.0)
    }

    static func indicesBetween(
        _ spine: [(x: Double, y: Double)],
        _ arcs: [Double],
        _ a: Double,
        _ b: Double
    ) -> (start: Int, end: Int) {
        var start: Int?
        var end: Int?
        for (i, arc) in arcs.enumerated() {
            if start == nil && arc >= a { start = i }
            if arc >= b {
                end = i
                break
            }
        }
        return (
            start ?? spine.count - 1,
            end ?? spine.count - 1
        )
    }

    /// A route sharing the spine between two arc positions. sideIn/sideOut:
    /// +1 joins/leaves on the spine's left, -1 right, nil starts/ends on
    /// the corridor itself (boarding-stop-born strand). reverse: travel
    /// direction against the spine (one-way couplet member).
    static func strand(
        _ spine: [(x: Double, y: Double)],
        _ arcs: [Double],
        _ join: Double,
        _ leave: Double,
        sideIn: Int? = nil,
        sideOut: Int? = nil,
        reverse: Bool = false,
        stub: Double = 70.0
    ) -> [(x: Double, y: Double)] {
        let (i0, i1) = indicesBetween(spine, arcs, join, leave)
        let core = Array(spine[i0...i1])
        var pre: [(x: Double, y: Double)] = []
        let joinPoint = pointAt(spine, arcs, join)
        if let sideIn {
            let length = max(
                1e-9,
                (joinPoint.dx * joinPoint.dx + joinPoint.dy * joinPoint.dy)
                    .squareRoot()
            )
            let ux = joinPoint.dx / length
            let uy = joinPoint.dy / length
            let nx = -uy * Double(sideIn)
            let ny = ux * Double(sideIn)
            pre = [
                (joinPoint.x + nx * stub * 0.4, joinPoint.y + ny * stub * 0.4),
                (joinPoint.x + nx * stub, joinPoint.y + ny * stub),
            ]
        }
        let leavePoint = pointAt(spine, arcs, leave)
        var post: [(x: Double, y: Double)] = []
        if let sideOut {
            let length = max(
                1e-9,
                (leavePoint.dx * leavePoint.dx
                    + leavePoint.dy * leavePoint.dy).squareRoot()
            )
            let ux = leavePoint.dx / length
            let uy = leavePoint.dy / length
            let nx = -uy * Double(sideOut)
            let ny = ux * Double(sideOut)
            post = [
                (leavePoint.x + nx * stub, leavePoint.y + ny * stub),
                (leavePoint.x + nx * stub * 0.4, leavePoint.y + ny * stub * 0.4),
            ]
        }
        var pts = pre + core + post
        if reverse { pts.reverse() }
        return pts
    }

    static func strandGeometry(
        _ id: String,
        _ num: String,
        _ direction: Int?,
        _ points: [(x: Double, y: Double)],
        agency: String = "SBMTD",
        departures: Int = 4
    ) -> LaneHarness.Strand {
        // One 18 m densify for everything, exactly like the Python
        // harness's polyline_m: the harness scan, the scheduler's rows and
        // the metrics all read the same strand geometry.
        LaneHarness.Strand(
            id: id,
            num: num,
            direction: direction,
            coords: CorridorMembership.densify(polyline(points)),
            agency: agency,
            departures: departures
        )
    }

    // ------------------------------------------------------------------
    // Scenarios
    // ------------------------------------------------------------------

    /// Downtown trunk bundle: staggered joins/leaves on a gentle curving
    /// street, the 1/3/4/5/7/12X/17/24X shape.
    static func stateTrunk() -> [LaneHarness.Strand] {
        let control: [(x: Double, y: Double)] = [
            (0, 0), (200, 8), (400, 4), (600, 18), (800, 14),
            (1000, 30), (1200, 26),
        ]
        let spine = spinePoints(control)
        let arcs = arcOf(spine)
        return [
            strandGeometry("j1", "1", 0, strand(spine, arcs, 100, 1200)),
            strandGeometry("j3", "3", 0, strand(spine, arcs, 100, 1200)),
            strandGeometry("j5", "5", 0, strand(spine, arcs, 100, 900, sideOut: 1)),
            strandGeometry("j12x", "12X", 0, strand(spine, arcs, 100, 1000, sideOut: -1)),
            strandGeometry("j17", "17", 0, strand(spine, arcs, 350, 700, sideIn: 1, sideOut: 1)),
            strandGeometry("j4", "4", 0, strand(spine, arcs, 300, 1200, sideIn: -1)),
            strandGeometry("j24x", "24X", 0, strand(spine, arcs, 450, 1200, sideIn: -1)),
            strandGeometry("j7", "7", 0, strand(spine, arcs, 500, 950, sideIn: 1, sideOut: 1)),
        ]
    }

    /// Two one-way carriageways converging on a two-way street: opposite
    /// directions must sit on opposite sides of the centreline and stay
    /// there.
    static func couplet() -> [LaneHarness.Strand] {
        let control: [(x: Double, y: Double)] = [
            (0, 0), (250, -4), (500, 2), (800, -6), (1100, 0),
        ]
        let spine = spinePoints(control)
        let arcs = arcOf(spine)
        return [
            strandGeometry("j1", "1", 0, strand(spine, arcs, 50, 1100)),
            strandGeometry("j3", "3", 0, strand(spine, arcs, 150, 1100, sideIn: 1)),
            strandGeometry("j2", "2", 1, strand(spine, arcs, 200, 1050, reverse: true)),
            strandGeometry("j4", "4", 1, strand(spine, arcs, 400, 1050, sideIn: -1, reverse: true)),
        ]
    }

    /// Every strand is born at the same downtown boarding stop (flagship
    /// polylines start mid-corridor); service then diverges street by
    /// street.
    static func boardingBundle() -> [LaneHarness.Strand] {
        let control: [(x: Double, y: Double)] = [
            (0, 0), (180, 6), (360, 2), (540, 12), (720, 8), (900, 18),
        ]
        let spine = spinePoints(control)
        let arcs = arcOf(spine)
        return [
            strandGeometry("j1", "1", 0, strand(spine, arcs, 120, 900)),
            strandGeometry("j3", "3", 0, strand(spine, arcs, 120, 900)),
            strandGeometry("j4", "4", 0, strand(spine, arcs, 120, 900)),
            strandGeometry("j5", "5", 0, strand(spine, arcs, 120, 900, sideOut: -1)),
            strandGeometry("j11", "11", 0, strand(spine, arcs, 300, 900, sideIn: 1)),
            strandGeometry("j6", "6", 0, strand(spine, arcs, 420, 900, sideIn: -1)),
        ]
    }

    /// A strand whose parallel presence drops out briefly (side street bay)
    /// must reclaim its own lane when it returns.
    static func dropout() -> [LaneHarness.Strand] {
        let control: [(x: Double, y: Double)] = [
            (0, 0), (200, 4), (400, -2), (600, 6), (800, 0),
        ]
        let spine = spinePoints(control)
        let arcs = arcOf(spine)
        let (a, b) = indicesBetween(spine, arcs, 300, 500)
        var bulge: [(x: Double, y: Double)] = []
        for (i, point) in spine.enumerated() {
            if i >= a && i <= b {
                let t = sin(Double(i - a) / Double(max(b - a, 1)) * Double.pi)
                bulge.append((point.x + 26 * t, point.y + 26 * t))
            } else {
                bulge.append(point)
            }
        }
        return [
            strandGeometry("j1", "1", 0, strand(spine, arcs, 50, 800)),
            strandGeometry("j3", "3", 0, strand(spine, arcs, 50, 800)),
            strandGeometry("j2", "2", 0, [bulge[0]] + bulge),
            strandGeometry("j5", "5", 0, strand(spine, arcs, 50, 800)),
        ]
    }

    /// The real Chapala × Sola handoff: route 6 turns off at Sola while the
    /// express continues; the feeds disagree by a few metres.
    static func chapala(dataDirectory: URL, drift: Double = 4.0)
        -> [LaneHarness.Strand] {
        func load(_ name: String) -> [GeoCoordinate] {
            let url = dataDirectory.appendingPathComponent(name)
            let data = try! Data(contentsOf: url)
            let raw = try! JSONSerialization.jsonObject(with: data) as! [[Double]]
            return raw.map { GeoCoordinate(latitude: $0[0], longitude: $0[1]) }
        }

        func injectDrift(_ path: [GeoCoordinate], _ meters: Double)
            -> [GeoCoordinate] {
            let pts = path.map { $0.projected }
            let mm = GeoProjection.metersPerUnit(
                atLatitude: path[0].latitude
            )
            var out: [GeoCoordinate] = []
            for i in 0..<path.count {
                let a = pts[max(0, i - 1)]
                let b = pts[min(pts.count - 1, i + 1)]
                let dx = b.x - a.x
                let dy = b.y - a.y
                let length = (dx * dx + dy * dy).squareRoot()
                if length < 1e-9 {
                    out.append(path[i])
                    continue
                }
                let nx = -dy / length
                let ny = dx / length
                out.append(GeoCoordinate.fromProjected(ProjectedPoint(
                    x: pts[i].x + nx * meters / mm,
                    y: pts[i].y + ny * meters / mm
                )))
            }
            return out
        }

        return [
            LaneHarness.Strand(
                id: "j6",
                num: "6",
                direction: 0,
                coords: injectDrift(load("route_6dt.json"), drift)
            ),
            LaneHarness.Strand(
                id: "jx",
                num: "12X",
                direction: 0,
                coords: load("route_xdt.json")
            ),
        ]
    }

    /// Transit-center fan-out: six lines leave the center together; 80
    /// joins slightly later; then they peel off in sequence. Least-crosses
    /// order puts the first to peel on each side outermost on that side.
    static func fanout() -> [LaneHarness.Strand] {
        let spine = spinePoints([(0, 0), (0, 1200)])
        let arcs = arcOf(spine)

        func leg(_ xExit: Double, _ side: Double)
            -> [(x: Double, y: Double)] {
            var pts = strand(spine, arcs, 0, xExit)
            pts.append((30 * side, xExit))
            pts.append((140 * side, xExit + 60))
            return pts
        }

        return [
            strandGeometry("j1", "1", 0, strand(spine, arcs, 0, 1200)),
            strandGeometry("j7", "7", 0, leg(450, 1)),
            strandGeometry(
                "j80",
                "80",
                0,
                [(-60, -150), (-25, -60)] + strand(spine, arcs, 0, 300)
                    + [(30, 300), (140, 360)],
                agency: "VCTC"
            ),
            strandGeometry("j5", "5", 0, leg(600, -1)),
            strandGeometry("j17", "17", 0, leg(750, -1)),
            strandGeometry("j4", "4", 0, leg(900, -1)),
        ]
    }

    /// A trunk that forks: 1/3 turn onto a side street and keep sharing it
    /// while 12X/24X continue on the trunk — the corridor graph branches.
    static func fork() -> [LaneHarness.Strand] {
        let xstreet = spinePoints([
            (0, 0), (200, 5), (400, 10), (600, 6), (800, 12), (1000, 8),
        ])
        let xarcs = arcOf(xstreet)
        // street Y peels off at arc 600 toward the north-east
        let forkCoordinate = pointAt(xstreet, xarcs, 600)
        let forkPoint = (x: forkCoordinate.x, y: forkCoordinate.y)
        let ystreet = spinePoints([
            (forkPoint.x, forkPoint.y),
            (forkPoint.x + 120, forkPoint.y + 90),
            (forkPoint.x + 240, forkPoint.y + 100),
            (forkPoint.x + 360, forkPoint.y + 120),
        ])
        let forkIndex = indicesBetween(xstreet, xarcs, 600, 601).start

        func combined(_ join: Double, _ leave: Double, _ tail: Int)
            -> [(x: Double, y: Double)] {
            let (i0, _) = indicesBetween(xstreet, xarcs, join, leave)
            var pts = Array(xstreet[i0..<forkIndex])
            pts.append(forkPoint)
            if tail > 0 {
                pts += Array(ystreet[0..<min(tail, ystreet.count)])
            }
            return pts
        }

        return [
            strandGeometry("j1", "1", 0, combined(100, 600, 4)),
            strandGeometry("j3", "3", 0, combined(150, 600, 4)),
            strandGeometry("j12x", "12X", 0, strand(xstreet, xarcs, 100, 1000)),
            strandGeometry(
                "j24x",
                "24X",
                0,
                strand(xstreet, xarcs, 200, 1000, sideIn: 1)
            ),
            strandGeometry(
                "j5",
                "5",
                0,
                strand(xstreet, xarcs, 300, 800, sideIn: -1, sideOut: -1)
            ),
        ]
    }

    /// The longest shared run belongs to a journey travelling against the
    /// others: the schedule's frame conversion must keep every strand on a
    /// stable side.
    static func reversedSpine() -> [LaneHarness.Strand] {
        let control: [(x: Double, y: Double)] = [
            (0, 0), (200, 6), (400, 2), (600, 10), (800, 4), (1000, 8),
        ]
        let spine = spinePoints(control)
        let arcs = arcOf(spine)
        return [
            strandGeometry("j2", "2", 1, strand(spine, arcs, 50, 1000, reverse: true)),
            strandGeometry("j4", "4", 1, strand(spine, arcs, 50, 1000, reverse: true)),
            strandGeometry("j1", "1", 0, strand(spine, arcs, 100, 900)),
            strandGeometry("j3", "3", 0, strand(spine, arcs, 250, 950, sideIn: 1)),
        ]
    }
}
