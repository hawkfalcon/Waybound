/// Far-zoom fan pinch.
///
/// A corridor's lanes fan out from the shared centerline at a constant
/// on-screen spacing, so the fan keeps widening as the rider zooms in while
/// the street it is drawn on does not. Where a route doubles back on itself —
/// a downtown loop, a terminal spur — the two legs of the *same* route end up
/// close together on the ground, and once the lane offset grows to roughly the
/// width of that feature the offset curve of one leg reaches across and
/// crosses the offset curve of the other. The drawn ribbon folds over itself
/// and reads as a saltire X on the map.
///
/// The pinch pulls the lane back inside its own street: it scales that run's
/// lane offsets down, uniformly, until the run's own drawn ribbon has no
/// lane-off-street self-crossing left.
///
/// Three properties matter and are all deliberate:
///
/// * **Uniform over the run.** The lane stays parallel to its corridor
///   neighbours instead of pinching locally, so the fan keeps its shape and
///   no lane braids across another.
/// * **Every vertex survives.** The pinch moves points, it never drops them,
///   so route coverage is unchanged and no sub-path splitting can open a gap.
/// * **Only real folds are touched.** A route that doubles back along the
///   corridor it just came down has a self-crossing *centerline*: its two legs
///   are the same street, no offset scale can separate them, and pinching
///   would only flatten the route onto itself. Those runs are left exactly as
///   they are.
public enum LaneRibbonPinch {

    // ------------------------------------------------------------------
    // Public entry point
    // ------------------------------------------------------------------

    /// The largest uniform scale `k <= 1` to apply to `displacement` so that
    /// the ribbon `centre[i] + k * displacement[i]` has no self-crossing
    /// between two legs of genuinely different streets.
    ///
    /// Returns `1` — "leave this run alone" — whenever the run's ribbon is
    /// already simple, whenever its centerline is not, or whenever the only
    /// folds are a route doubling back along one street.
    ///
    /// - Parameters:
    ///   - centre: the run's centerline samples, in screen points.
    ///   - displacement: how far each sample is drawn to the side of the
    ///     centerline, i.e. `offsetPoints[i] - centre[i]`.
    ///   - minimumStreetWidth: how far apart two legs have to be before they
    ///     count as different streets. Pass the stroke width plus the ink
    ///     separator; two legs closer than that are one street drawn twice.
    public static func runScale(
        centre: [(x: Double, y: Double)],
        displacement: [(x: Double, y: Double)],
        minimumStreetWidth: Double
    ) -> Double {
        let count = centre.count
        guard count >= 4, displacement.count == count else { return 1 }

        var reach = 0.0
        for d in displacement {
            reach = max(reach, (d.x * d.x + d.y * d.y).squareRoot())
        }
        guard reach > 0 else { return 1 }

        var longestSegment = 0.0
        for i in 0..<(count - 1) {
            let dx = centre[i + 1].x - centre[i].x
            let dy = centre[i + 1].y - centre[i].y
            longestSegment = max(longestSegment, (dx * dx + dy * dy).squareRoot())
        }

        let candidates = candidatePairs(
            centre: centre,
            displacement: displacement,
            reach: reach,
            longestSegment: longestSegment
        )
        guard !candidates.isEmpty else { return 1 }

        // Which candidate pairs are lane-off-street folds? Judged once, at the
        // lane's real width, for every candidate pair and not just the ones
        // that happen to cross at k == 1: as the lane shrinks the fold walks
        // along the ribbon onto neighbouring segments, so a pair that is clean
        // at k == 1 can be the one folding at k == 0.9.
        var folds: [(i: Int, j: Int)] = []
        for pair in candidates {
            var gap = Double.greatestFiniteMagnitude
            for p in [pair.i, pair.i + 1] {
                for q in [pair.j, pair.j + 1] {
                    let dx = centre[p].x - centre[q].x
                    let dy = centre[p].y - centre[q].y
                    gap = min(gap, (dx * dx + dy * dy).squareRoot())
                }
            }
            let widest = max(
                magnitude(displacement[pair.i]),
                magnitude(displacement[pair.j])
            )
            if gap >= widest, gap >= minimumStreetWidth {
                folds.append(pair)
            }
        }
        guard !folds.isEmpty else { return 1 }

        func crossing(at k: Double) -> Bool {
            for fold in folds {
                let a0 = offset(centre[fold.i], by: displacement[fold.i], scale: k)
                let a1 = offset(centre[fold.i + 1], by: displacement[fold.i + 1], scale: k)
                let b0 = offset(centre[fold.j], by: displacement[fold.j], scale: k)
                let b1 = offset(centre[fold.j + 1], by: displacement[fold.j + 1], scale: k)
                if properlyCrosses(a0, a1, b0, b1) { return true }
            }
            return false
        }

        // A run whose centerline itself folds cannot be fixed by moving its
        // lane, and pinching it would collapse the route onto the crossing.
        if crossing(at: 0) { return 1 }
        guard crossing(at: 1) else { return 1 }

        // Bisect the top of the clean band that contains k == 0. The clean
        // band is where the ribbon is simple; starting from 0 keeps the answer
        // inside it even though the band is not an interval (the fold slides
        // along the ribbon and can vanish for a stretch before reappearing).
        var low = 0.0
        var high = 1.0
        for _ in 0..<20 {
            let mid = 0.5 * (low + high)
            if crossing(at: mid) {
                high = mid
            } else {
                low = mid
            }
        }
        return low
    }

    // ------------------------------------------------------------------
    // Run-level convenience
    // ------------------------------------------------------------------

    /// Apply `runScale` to every maximal shared run of a drawn ribbon.
    ///
    /// - Parameters:
    ///   - centre: the deduplicated centerline samples, in screen points.
    ///   - ribbon: the same samples after the lane offset has been applied.
    ///   - sharedSegments: `sharedSegments[i]` is true when segment `i` (from
    ///     sample `i` to sample `i + 1`) is interlined corridor geometry.
    ///   - minimumStreetWidth: stroke width plus ink separator.
    /// - Returns: the ribbon with each folding run's lane pulled back inside
    ///   its own street. Same point count, same order, no gaps.
    public static func pinchedRibbon(
        centre: [(x: Double, y: Double)],
        ribbon: [(x: Double, y: Double)],
        sharedSegments: [Bool],
        minimumStreetWidth: Double
    ) -> [(x: Double, y: Double)] {
        let count = min(centre.count, ribbon.count)
        guard count >= 2 else { return ribbon }
        var displacement: [(x: Double, y: Double)] = []
        displacement.reserveCapacity(count)
        for i in 0..<count {
            displacement.append(
                (ribbon[i].x - centre[i].x, ribbon[i].y - centre[i].y)
            )
        }

        // A maximal run of shared segments [a, b] covers samples a...b + 1, so
        // walk the segment flags and close each run as it ends.
        let segmentCount = min(count - 1, sharedSegments.count)
        var result = ribbon
        var runStart = 0
        var inRun = false
        for index in 0...segmentCount {
            let shared = index < segmentCount && sharedSegments[index]
            if shared {
                if !inRun {
                    inRun = true
                    runStart = index
                }
            } else if inRun {
                let first = runStart
                let lastSample = index          // samples first...lastSample
                inRun = false
                guard lastSample - first + 1 >= 4 else { continue }
                pinchRun(
                    centre: centre,
                    displacement: &displacement,
                    result: &result,
                    from: first,
                    to: lastSample,
                    minimumStreetWidth: minimumStreetWidth
                )
            }
        }
        return result
    }

    private static func pinchRun(
        centre: [(x: Double, y: Double)],
        displacement: inout [(x: Double, y: Double)],
        result: inout [(x: Double, y: Double)],
        from start: Int,
        to end: Int,
        minimumStreetWidth: Double
    ) {
        var runCentre: [(x: Double, y: Double)] = []
        var runDisplacement: [(x: Double, y: Double)] = []
        runCentre.reserveCapacity(end - start + 1)
        runDisplacement.reserveCapacity(end - start + 1)
        for i in start...end {
            runCentre.append(centre[i])
            runDisplacement.append(displacement[i])
        }
        let scale = runScale(
            centre: runCentre,
            displacement: runDisplacement,
            minimumStreetWidth: minimumStreetWidth
        )
        guard scale < 1 else { return }
        for i in start...end {
            displacement[i] = (
                displacement[i].x * scale,
                displacement[i].y * scale
            )
            result[i] = (
                centre[i].x + displacement[i].x,
                centre[i].y + displacement[i].y
            )
        }
    }

    // ------------------------------------------------------------------
    // Geometry
    // ------------------------------------------------------------------

    private static func magnitude(_ v: (x: Double, y: Double)) -> Double {
        (v.x * v.x + v.y * v.y).squareRoot()
    }

    private static func offset(
        _ point: (x: Double, y: Double),
        by displacement: (x: Double, y: Double),
        scale: Double
    ) -> (x: Double, y: Double) {
        (point.x + displacement.x * scale, point.y + displacement.y * scale)
    }

    /// Strictly-inside crossing test: the two segments have to cross at a
    /// point interior to both, so touching at a shared endpoint or grazing
    /// along a parallel edge does not count as a fold.
    private static func properlyCrosses(
        _ a0: (x: Double, y: Double),
        _ a1: (x: Double, y: Double),
        _ b0: (x: Double, y: Double),
        _ b1: (x: Double, y: Double)
    ) -> Bool {
        let d1x = a1.x - a0.x
        let d1y = a1.y - a0.y
        let d2x = b1.x - b0.x
        let d2y = b1.y - b0.y
        let denominator = d1x * d2y - d1y * d2x
        guard abs(denominator) > 1e-12 else { return false }
        let ex = b0.x - a0.x
        let ey = b0.y - a0.y
        let t = (ex * d2y - ey * d2x) / denominator
        let u = (ex * d1y - ey * d1x) / denominator
        // A fold only shows up in the ink when it is comfortably inside both
        // segments; a crossing that lands on an endpoint is the polyline
        // touching itself, which round caps already render as one stroke.
        let margin = 1e-6
        return t > margin && t < 1 - margin && u > margin && u < 1 - margin
    }

    /// Pairs of segments of the same run whose offset ribbons can possibly
    /// meet, found with a uniform grid so the cost stays linear in the run
    /// length. `reach` bounds how far either ribbon can be from its own
    /// centerline, so two segments further apart than `2 * reach` cannot
    /// interact at any scale.
    private static func candidatePairs(
        centre: [(x: Double, y: Double)],
        displacement: [(x: Double, y: Double)],
        reach: Double,
        longestSegment: Double
    ) -> [(i: Int, j: Int)] {
        let segmentCount = centre.count - 1
        let cell = max(2 * reach + longestSegment, 1e-9)
        var grid: [GridKey: [Int]] = [:]
        var boxes: [(minX: Double, minY: Double, maxX: Double, maxY: Double)] = []
        boxes.reserveCapacity(segmentCount)

        for i in 0..<segmentCount {
            let p0 = offset(centre[i], by: displacement[i], scale: 1)
            let p1 = offset(centre[i + 1], by: displacement[i + 1], scale: 1)
            let box = (
                minX: min(p0.x, p1.x), minY: min(p0.y, p1.y),
                maxX: max(p0.x, p1.x), maxY: max(p0.y, p1.y)
            )
            boxes.append(box)
            grid[GridKey(Int(box.minX / cell), Int(box.minY / cell)), default: []].append(i)
        }

        var seen = Set<OrderedPair>()
        var pairs: [(i: Int, j: Int)] = []
        for i in 0..<segmentCount {
            let box = boxes[i]
            let cx = Int(box.minX / cell)
            let cy = Int(box.minY / cell)
            for dx in -1...1 {
                for dy in -1...1 {
                    guard let bucket = grid[GridKey(cx + dx, cy + dy)] else { continue }
                    for j in bucket where j > i {
                        // Adjacent segments share a vertex by construction; a
                        // fold needs the ribbon to come back on itself.
                        if j < i + 2 { continue }
                        let other = boxes[j]
                        guard box.maxX >= other.minX, other.maxX >= box.minX,
                              box.maxY >= other.minY, other.maxY >= box.minY
                        else { continue }
                        if seen.insert(OrderedPair(i, j)).inserted {
                            pairs.append((i, j))
                        }
                    }
                }
            }
        }
        return pairs
    }

    private struct GridKey: Hashable {
        let x: Int
        let y: Int
        init(_ x: Int, _ y: Int) {
            self.x = x
            self.y = y
        }
    }

    private struct OrderedPair: Hashable {
        let first: Int
        let second: Int
        init(_ first: Int, _ second: Int) {
            self.first = first
            self.second = second
        }
    }
}
