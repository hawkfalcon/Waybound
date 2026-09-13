import Foundation

/// The stop-connector notch stage: removes the out-and-back spikes a GTFS
/// feed bakes into shapes to reach the stop coordinate, plus steep
/// terminal-connector tails. A pure WayboundCore port of
/// `TripPathGeometry.removingStopConnectorNotches` and of the replay
/// harness's `notch2.py` — same gates, same constants, same iteration.
///
/// Gates: path ≤ 260 m, chord ≤ 240 m, depth 3–25 m, apex ≤ 12 m from a
/// stop, street continues straight through (anchor and return each within
/// 8 m of the other leg's line, heading-through dot ≥ 0.9), at least one
/// leg ≥ 40° off the street, ≤ 128 interior passes. Terminal trim: up to 3
/// vertices per end, each within 12 m of a stop and ≥ 70° off the street
/// line (dot ≤ 0.34), with the street line measured from outside the
/// connector.
public enum NotchStage {

    static func unit(_ a: ProjectedPoint, _ b: ProjectedPoint)
        -> (x: Double, y: Double)? {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length >= 1e-9 else { return nil }
        return (dx / length, dy / length)
    }

    static func distance(_ a: ProjectedPoint, _ b: ProjectedPoint) -> Double {
        ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y))
            .squareRoot()
    }

    /// Travel heading at i, over up to ~60 m / 3 vertices. Normalized to
    /// the direction of travel regardless of step sign.
    static func headingOver(
        _ pts: [ProjectedPoint],
        _ i: Int,
        _ step: Int,
        _ metersPerUnit: Double,
        maxLength: Double = 60.0,
        maxSteps: Int = 3
    ) -> (x: Double, y: Double)? {
        var accumulated = 0.0
        var j = i
        for _ in 0..<maxSteps {
            let next = j + step
            guard next >= 0 && next < pts.count else { break }
            let segmentLength = distance(pts[j], pts[next]) * metersPerUnit
            if accumulated > 0 && accumulated + segmentLength > maxLength {
                break
            }
            accumulated += segmentLength
            j = next
        }
        guard j != i else { return nil }
        let a = step > 0 ? pts[i] : pts[j]
        let b = step > 0 ? pts[j] : pts[i]
        return unit(a, b)
    }

    static func firstNotch(
        _ pts: [ProjectedPoint],
        _ metersPerUnit: Double,
        _ stopPoints: [ProjectedPoint],
        maxPath: Double = 260.0,
        maxChord: Double = 240.0,
        minDepth: Double = 3.0,
        maxDepth: Double = 25.0,
        maxStopDistance: Double = 12.0,
        maxLineOffset: Double = 8.0,
        minDot: Double = 0.9,
        maxLegAngleDegrees: Double = 40.0
    ) -> Range<Int>? {
        let n = pts.count
        for a in 1..<(n - 1) {
            guard let hPrev = headingOver(pts, a, -1, metersPerUnit)
            else { continue }
            var pathLength = 0.0
            for r in (a + 1)..<(n - 1) {
                pathLength += distance(pts[r - 1], pts[r]) * metersPerUnit
                if pathLength > maxPath { break }
                let chord = distance(pts[a], pts[r]) * metersPerUnit
                if chord > maxChord || chord < 1.0 { continue }
                // Fresh array: python's pts[a+1:r] is indexed from zero;
                // an ArraySlice would inherit the parent's indices and
                // interior[apexIndex] would read (or trap at) the wrong
                // vertex.
                let interior = Array(pts[(a + 1)..<r])
                if interior.isEmpty { continue }
                let depths = interior.map { point in
                    perpDistance(point, pts[a], pts[r]) * metersPerUnit
                }
                let maxDepthValue = depths.max() ?? 0
                if maxDepthValue < minDepth || maxDepthValue > maxDepth {
                    continue
                }
                let apexIndex = depths.firstIndex(of: maxDepthValue) ?? 0
                let apex = interior[apexIndex]
                if let nearestStop = stopPoints.map({ point in
                    distance(apex, point) * metersPerUnit
                }).min(), nearestStop > maxStopDistance {
                    continue
                }
                guard let hNext = headingOver(pts, r, 1, metersPerUnit)
                else { continue }
                // Street continues straight through, tested against BOTH
                // legs: the return sits on the incoming line and the anchor
                // sits on the outgoing line. The stop itself must not
                // qualify as the return.
                let dx = pts[r].x - pts[a].x
                let dy = pts[r].y - pts[a].y
                if abs(dx * hPrev.y - dy * hPrev.x) * metersPerUnit
                    > maxLineOffset { continue }
                if abs(dx * hNext.y - dy * hNext.x) * metersPerUnit
                    > maxLineOffset { continue }
                if hPrev.x * hNext.x + hPrev.y * hNext.y < minDot { continue }
                // A connector reaches its stop steeply off the street; a
                // curve's legs diverge from the chord gradually. At least
                // one leg must leave the street line by ≥ maxLegAngle.
                guard let legIn = unit(pts[a], apex),
                      let legOut = unit(apex, pts[r])
                else { continue }
                let cosMax = cos(maxLegAngleDegrees * Double.pi / 180)
                let steep = abs(
                    legIn.x * hPrev.x + legIn.y * hPrev.y
                ) <= cosMax || abs(
                    legOut.x * hPrev.x + legOut.y * hPrev.y
                ) <= cosMax
                if !steep { continue }
                return (a + 1)..<r
            }
        }
        return nil
    }

    static func perpDistance(
        _ p: ProjectedPoint,
        _ a: ProjectedPoint,
        _ b: ProjectedPoint
    ) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        if l2 == 0 { return distance(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
        return distance(p, ProjectedPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    static func distanceToPolyline(
        _ p: ProjectedPoint,
        _ pts: [ProjectedPoint]
    ) -> Double {
        guard pts.count >= 2 else { return 0 }
        var best = Double.greatestFiniteMagnitude
        for i in 0..<(pts.count - 1) {
            best = min(best, perpDistance(p, pts[i], pts[i + 1]))
        }
        return best
    }

    /// Drops a terminal vertex that is a stop reached steeply off the
    /// street line the shape was traveling. The street line is measured
    /// from OUTSIDE the connector: walk inward past vertices within
    /// `skipRadius` of the terminal vertex, and take the travel heading
    /// there — otherwise a two-point perpendicular tail would measure its
    /// own connector leg as the "street".
    static func trimTerminal(
        _ pts: [ProjectedPoint],
        _ metersPerUnit: Double,
        _ stopPoints: [ProjectedPoint],
        last: Bool,
        maxStopDistance: Double = 12.0,
        maxDepartDot: Double = 0.34,
        skipRadius: Double = 25.0,
        maxSkipSteps: Int = 8
    ) -> Bool {
        let n = pts.count
        let v = last ? pts[n - 1] : pts[0]
        var i = last ? n - 2 : 1
        let step = last ? -1 : 1
        if let nearestStop = stopPoints.map({ point in
            distance(v, point) * metersPerUnit
        }).min(), nearestStop > maxStopDistance {
            return false
        }
        // First vertex beyond the connector's neighborhood, but always
        // leave at least one vertex ahead for the heading baseline.
        var skipped = 0
        while i >= 0 && i < n
                && distance(pts[i], v) * metersPerUnit <= skipRadius
                && skipped < maxSkipSteps {
            let next = i + step
            if last && next < 1 { break }
            if !last && next > n - 2 { break }
            i = next
            skipped += 1
        }
        guard i >= 0 && i < n else { return false }
        guard let h = headingOver(pts, i, last ? -1 : 1, metersPerUnit)
        else { return false }
        guard let hv = unit(pts[last ? n - 2 : 1], v) else { return false }
        // abs(): a reversal is not a sideways departure.
        return abs(hv.x * h.x + hv.y * h.y) <= maxDepartDot
    }

    /// Remove stop-connector notches and steep terminal tails from a shape.
    public static func removingStopConnectorNotches(
        _ coordinates: [GeoCoordinate],
        _ stops: [GeoCoordinate],
        maxPasses: Int = 128
    ) -> [GeoCoordinate] {
        guard coordinates.count >= 4, !stops.isEmpty else { return coordinates }
        let metersPerUnit = GeoProjection.metersPerUnit(
            atLatitude: coordinates[0].latitude
        )
        let stopPoints = stops.map { $0.projected }
        var result = coordinates
        for _ in 0..<maxPasses {
            let pts = result.map { $0.projected }
            guard let range = firstNotch(pts, metersPerUnit, stopPoints)
            else { break }
            result.removeSubrange(range)
        }
        var pts = result.map { $0.projected }
        for _ in 0..<3 {
            if trimTerminal(pts, metersPerUnit, stopPoints, last: true) {
                result.removeLast()
                pts = result.map { $0.projected }
            } else {
                break
            }
        }
        pts = result.map { $0.projected }
        for _ in 0..<3 {
            if trimTerminal(pts, metersPerUnit, stopPoints, last: false) {
                result.removeFirst()
                pts = result.map { $0.projected }
            } else {
                break
            }
        }
        return result
    }
}
