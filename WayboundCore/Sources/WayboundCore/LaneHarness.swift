import Foundation

/// The lane measurement harness: a verbatim WayboundCore port of the replay
/// harness's `corridor3.py` — the "main" per-sample lane source, the shared
/// downstream pipeline (with centerline-alignment deltas), the screen-space
/// ribbon, and the drawn-ribbon metrics (crossings, bundle crossings, pair
/// drift/wobble, minimum lane separation).
///
/// This exists so the lane-quality gates that used to run in Python
/// (`lane_check.py`, `lane_fuzz.py`) are plain Swift tests: same scenarios,
/// same comparative gates, no Python anywhere. It deliberately mirrors the
/// Python 1:1 (including the retired "main" lane source, which lives on only
/// as the comparative baseline) — it is NOT the production engine; the
/// production engine is `CorridorLaneSchedule` + `CorridorLaneLayoutEngine`,
/// golden-pinned to the device. Where this harness and the engine disagree,
/// reconcile before shipping.
///
/// Framing: strands live in the shared Mercator space (`ProjectedPoint`);
/// metrics work in "screen points" = map points scaled by mpm(lat)/mpp with
/// the harness convention mpp = 2.0, exactly as the Python did.
enum LaneHarness {

    static let laneSpacing = LaneScheduleConstants.laneSpacing

    typealias SpineFrame = (
        pts: [(x: Double, y: Double)],
        normals: [(x: Double, y: Double)],
        arc: [Double],
        turn: [Int]
    )

    // ------------------------------------------------------------------
    // Strands
    // ------------------------------------------------------------------

    /// One journey's flagship polyline (the harness's `G`).
    struct Strand {
        let id: String
        let num: String
        let direction: Int?
        let agency: String
        let departures: Int
        let stack: String
        let coords: [GeoCoordinate]
        let points: [ProjectedPoint]
        let segments: [CorridorMembership.CorridorSegment?]
        let metersPerUnit: Double
        let latitude: Double

        init(
            id: String,
            num: String,
            direction: Int?,
            coords: [GeoCoordinate],
            agency: String = "SBMTD",
            departures: Int = 4
        ) {
            self.id = id
            self.num = num
            self.direction = direction
            self.agency = agency
            self.departures = departures
            self.stack = id
            self.coords = coords
            self.latitude = coords[0].latitude
            self.metersPerUnit = GeoProjection.metersPerUnit(
                atLatitude: coords[0].latitude
            )
            self.points = coords.map { $0.projected }
            var segments: [CorridorMembership.CorridorSegment?] = []
            segments.reserveCapacity(points.count - 1)
            for index in 0..<(points.count - 1) {
                segments.append(CorridorMembership.CorridorSegment(
                    start: points[index],
                    end: points[index + 1]
                ))
            }
            self.segments = segments
        }

        var publicRouteKey: String {
            "\(agency)|\(num)"
        }

        var arc: [Double] {
            var arcs = [0.0]
            for index in 1..<points.count {
                arcs.append(
                    arcs.last!
                        + points[index - 1].distance(to: points[index])
                            * metersPerUnit
                )
            }
            return arcs
        }
    }

    /// `numkey`: a route number splits into numeric and lowercase-text
    /// parts; numeric parts compare numerically, text parts textually.
    static func numKey(_ num: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var currentIsDigit = false
        for character in num {
            let isDigit = character.isNumber
            if !current.isEmpty && isDigit != currentIsDigit {
                parts.append(current)
                current = ""
            }
            currentIsDigit = isDigit
            current.append(character)
        }
        if !current.isEmpty { parts.append(current) }
        return parts.map { part in
            part.allSatisfy(\.isNumber) ? String(Int(part) ?? 0) : part.lowercased()
        }
    }

    /// `seg_before`: route number parts, direction (nil last), stack, id.
    static func comesBefore(_ a: Strand, _ b: Strand) -> Bool {
        let ka = numKey(a.num)
        let kb = numKey(b.num)
        for (pa, pb) in zip(ka, kb) {
            if pa == pb { continue }
            let aInt = Int(pa)
            let bInt = Int(pb)
            if aInt != nil && bInt != nil { return aInt! < bInt! }
            if aInt != nil { return true }
            if bInt != nil { return false }
            return pa < pb
        }
        if ka.count != kb.count { return ka.count < kb.count }
        let da = a.direction ?? Int.max
        let db = b.direction ?? Int.max
        if da != db { return da < db }
        if a.stack != b.stack { return a.stack < b.stack }
        return a.id < b.id
    }

    // ------------------------------------------------------------------
    // The scan (over the already-densified harness strands)
    // ------------------------------------------------------------------

    struct Match {
        /// The candidate strand (array index) that matches.
        let strandIndex: Int
        /// The matched segment.
        let segment: CorridorMembership.CorridorSegment
        /// Where the matched segment sits on the candidate's own polyline.
        let ownIndex: Int
    }

    /// Per strand, per segment: the other strands running parallel there,
    /// each with its matched segment and that segment's own index.
    static func membershipScan(
        _ strands: [Strand]
    ) -> [[[Match]]] {
        var rows: [[[Match]]] = []
        for (index, strand) in strands.enumerated() {
            var strandRows: [[Match]] = []
            for segment in strand.segments {
                guard let segment else {
                    strandRows.append([])
                    continue
                }
                let midpoint = ProjectedPoint(
                    x: (segment.start.x + segment.end.x) / 2,
                    y: (segment.start.y + segment.end.y) / 2
                )
                var members: [Match] = []
                for (candidateIndex, candidate) in strands.enumerated()
                where candidateIndex != index {
                    guard let match = nearestParallel(
                        near: midpoint,
                        direction: segment,
                        strand: candidate,
                        strandIndex: candidateIndex
                    ) else { continue }
                    // Endpoint gates: the pairing must hold along the whole
                    // segment, not just at the midpoint.
                    guard
                        hasParallel(
                            near: segment.start,
                            direction: segment,
                            strand: candidate,
                            strandIndex: candidateIndex
                        ),
                        hasParallel(
                            near: segment.end,
                            direction: segment,
                            strand: candidate,
                            strandIndex: candidateIndex
                        )
                    else { continue }
                    members.append(match)
                }
                strandRows.append(members)
            }
            rows.append(strandRows)
        }
        return rows
    }

    static func nearestParallel(
        near point: ProjectedPoint,
        direction: CorridorMembership.CorridorSegment,
        strand: Strand,
        strandIndex: Int
    ) -> Match? {
        var best: (distance: Double, segment: CorridorMembership.CorridorSegment, index: Int)?
        for index in 0..<strand.segments.count {
            guard let candidate = strand.segments[index] else { continue }
            guard abs(
                direction.unitX * candidate.unitX
                    + direction.unitY * candidate.unitY
            ) >= 0.93 else { continue }
            let distance = point.distance(
                to: projection(of: point, onto: candidate)
            ) * strand.metersPerUnit
            if distance <= 20 && (best == nil || distance < best!.distance) {
                best = (distance, candidate, index)
            }
        }
        guard let best else { return nil }
        return Match(
            strandIndex: strandIndex,
            segment: best.segment,
            ownIndex: best.index
        )
    }

    static func hasParallel(
        near point: ProjectedPoint,
        direction: CorridorMembership.CorridorSegment,
        strand: Strand,
        strandIndex: Int
    ) -> Bool {
        nearestParallel(
            near: point,
            direction: direction,
            strand: strand,
            strandIndex: strandIndex
        ) != nil
    }

    static func projection(
        of point: ProjectedPoint,
        onto segment: CorridorMembership.CorridorSegment
    ) -> ProjectedPoint {
        let deltaX = segment.end.x - segment.start.x
        let deltaY = segment.end.y - segment.start.y
        let lengthSquared = deltaX * deltaX + deltaY * deltaY
        guard lengthSquared > 0 else { return point }
        let progress = max(
            0,
            min(
                1,
                ((point.x - segment.start.x) * deltaX
                    + (point.y - segment.start.y) * deltaY) / lengthSquared
            )
        )
        return ProjectedPoint(
            x: segment.start.x + progress * deltaX,
            y: segment.start.y + progress * deltaY
        )
    }

    /// Capped projection (the adoption): ≤ 6 m, else the point stays.
    static func adoptionProjection(
        of point: ProjectedPoint,
        onto segment: CorridorMembership.CorridorSegment,
        metersPerUnit: Double,
        cap: Double = 6.0
    ) -> ProjectedPoint {
        let hit = projection(of: point, onto: segment)
        return point.distance(to: hit) * metersPerUnit <= cap ? hit : point
    }

    // ------------------------------------------------------------------
    // Per-segment lane sources
    // ------------------------------------------------------------------

    struct SegmentLane {
        var offset: Double
        var anchorStart: ProjectedPoint
        var anchorEnd: ProjectedPoint
        var referenceID: Int
        var trunk: Bool
    }

    /// Main's lane math: sort the local member set, centre the stack (or
    /// split it by travel direction). The retired production lane source,
    /// kept as the comparative baseline.
    static func mainLane(
        strandIndex: Int,
        segmentIndex: Int,
        strands: [Strand],
        scan: [[[Match]]]
    ) -> (offset: Double, referenceID: Int, reference: CorridorMembership.CorridorSegment)? {
        let strand = strands[strandIndex]
        guard segmentIndex < strand.segments.count,
              let segment = strand.segments[segmentIndex],
              segmentIndex < scan[strandIndex].count
        else { return nil }
        let members = scan[strandIndex][segmentIndex]
        if members.isEmpty { return nil }

        // Scan rows identify members by strand array index.
        var memberMap: [Int: CorridorMembership.CorridorSegment] = [
            strandIndex: segment
        ]
        for match in members {
            memberMap[match.strandIndex] = match.segment
        }
        let memberIDs = memberMap.keys.sorted {
            comesBefore(strands[$0], strands[$1])
        }
        // Both directions of one numbered route are one visual strand.
        var claimed = Set<String>()
        var lanes: [Int] = []
        for memberID in memberIDs {
            let key = strands[memberID].publicRouteKey
            if !claimed.contains(key) {
                claimed.insert(key)
                lanes.append(memberID)
            }
        }
        let ownKey = strand.publicRouteKey
        let laneJ = lanes.first { strands[$0].publicRouteKey == ownKey }
            ?? strandIndex
        let referenceID = memberIDs.first ?? strandIndex
        guard let reference = memberMap[referenceID] else { return nil }
        let aligned = lanes.filter {
            (memberMap[$0]?.unitX ?? 0) * reference.unitX
                + (memberMap[$0]?.unitY ?? 0) * reference.unitY >= 0
        }
        let reverse = lanes.filter { !aligned.contains($0) }
        let offset: Double
        if !reverse.isEmpty {
            if let position = aligned.firstIndex(of: laneJ) {
                offset = laneSpacing / 2 + Double(position) * laneSpacing
            } else if let position = reverse.firstIndex(of: laneJ) {
                offset = -(laneSpacing / 2 + Double(position) * laneSpacing)
            } else {
                return nil
            }
        } else {
            guard let position = aligned.firstIndex(of: laneJ) else {
                return nil
            }
            offset = (Double(position) - Double(aligned.count - 1) / 2)
                * laneSpacing
        }
        let directionSign: Double =
            (segment.unitX * reference.unitX
                + segment.unitY * reference.unitY) >= 0 ? 1 : -1
        return (offset * directionSign, referenceID, reference)
    }

    /// Main's dominance vote: selection > highlight > frequency.
    static func trunkOwner(
        strandIndex: Int,
        segmentIndex: Int,
        strands: [Strand],
        scan: [[[Match]]],
        selected: Int?,
        highlighted: [Int]?
    ) -> Bool {
        guard segmentIndex < scan[strandIndex].count else { return false }
        let rows = scan[strandIndex][segmentIndex]
        if rows.isEmpty { return false }
        var memberIDs = rows.map { $0.strandIndex }
        memberIDs.append(strandIndex)
        memberIDs = memberIDs.sorted {
            comesBefore(strands[$0], strands[$1])
        }
        let candidates: [Int]
        if let selected, memberIDs.contains(selected) {
            candidates = [selected]
        } else if let highlighted {
            let inside = memberIDs.filter { highlighted.contains($0) }
            candidates = inside.isEmpty ? memberIDs : inside
        } else {
            candidates = memberIDs
        }
        let dominant = candidates.min {
            let firstKey = (-strands[$0].departures, strands[$0].stack, $0)
            let secondKey = (-strands[$1].departures, strands[$1].stack, $1)
            return firstKey < secondKey
        } ?? strandIndex
        return strands[strandIndex].publicRouteKey
            == strands[dominant].publicRouteKey
    }

    /// The observer takes a lane only where its own scan says it shares —
    /// exactly main's gate.
    static func scheduledLane(
        strandIndex: Int,
        segmentIndex: Int,
        strands: [Strand],
        scan: [[[Match]]],
        schedule: [Int: [Int: CorridorLaneSchedule.Sample]],
        heldCache: inout [Int: [(x: Double, y: Double)]]
    ) -> (offset: Double,
          referenceID: Int,
          reference: CorridorMembership.CorridorSegment?)? {
        guard segmentIndex < scan[strandIndex].count,
              !scan[strandIndex][segmentIndex].isEmpty,
              let entry = schedule[strandIndex]?[segmentIndex],
              let segment = strands[strandIndex].segments[segmentIndex]
        else { return nil }
        let held = heldDirections(
            strands[strandIndex],
            cache: &heldCache
        )
        let basis = segmentIndex < held.count
            ? held[segmentIndex]
            : (x: segment.unitX, y: segment.unitY)
        let sign: Double = basis.x * entry.directionX
            + basis.y * entry.directionY >= 0 ? 1 : -1
        let reference = scan[strandIndex][segmentIndex].first {
            $0.strandIndex == entry.referenceID
        }?.segment
        return (entry.offset * sign, entry.referenceID, reference)
    }

    /// The renderer holds the lane normal through a 180-degree doubling
    /// back. Lane offsets must be converted against the same held basis.
    static func heldDirections(
        _ strand: Strand,
        cache: inout [Int: [(x: Double, y: Double)]]
    ) -> [(x: Double, y: Double)] {
        let key = strand.identifierKey
        if let cached = cache[key] { return cached }
        var held: [(x: Double, y: Double)] = []
        var previous: (x: Double, y: Double)?
        for segment in strand.segments {
            if let segment {
                var unitX = segment.unitX
                var unitY = segment.unitY
                if let previous,
                   unitX * previous.x + unitY * previous.y < -0.8 {
                    unitX = -unitX
                    unitY = -unitY
                }
                held.append((unitX, unitY))
                previous = (unitX, unitY)
            }
        }
        cache[key] = held
        return held
    }

    // ------------------------------------------------------------------
    // Downstream pipeline (with alignment deltas) — corridor3.pipeline
    // ------------------------------------------------------------------

    struct Layout {
        var points: [ProjectedPoint]
        var aligned: [ProjectedPoint]
        var offsets: [Double]
        var stacked: [Bool]
        var deltaX: [Double]
        var deltaY: [Double]
        var metersPerUnit: Double
        var referenceIDs: [Int?]
    }

    static func traceOffsets(_ stage: String, _ offs: [Double]) {
        var runs: [(Double, Int)] = []
        for offset in offs {
            let rounded = (offset * 100).rounded() / 100
            if let last = runs.last, last.0 == rounded {
                runs[runs.count - 1].1 += 1
            } else {
                runs.append((rounded, 1))
            }
        }
        print("PIPELINE \(stage) n \(offs.count) runs \(runs.prefix(14))")
    }

    static func pipeline(
        _ strand: Strand,
        _ segmentLayouts: [SegmentLane?],
        rateClamp: Double = 0.08,
        trace: Bool = false
    ) -> Layout {
        let points = strand.points
        let m = strand.metersPerUnit
        let n = points.count
        if trace {
            var laneRuns: [(Double, Int)] = []
            var nilCount = 0
            for layout in segmentLayouts {
                guard let layout else {
                    nilCount += 1
                    continue
                }
                let rounded = (layout.offset * 100).rounded() / 100
                if let last = laneRuns.last, last.0 == rounded {
                    laneRuns[laneRuns.count - 1].1 += 1
                } else {
                    laneRuns.append((rounded, 1))
                }
            }
            print("PIPELINE input nils \(nilCount) lanes \(laneRuns)")
        }

        // removeShortCorridorRuns
        var layouts = segmentLayouts
        var i = 0
        while i < layouts.count {
            while i < layouts.count && layouts[i] == nil { i += 1 }
            if i >= layouts.count { break }
            var j = i + 1
            while j < layouts.count && layouts[j] != nil { j += 1 }
            var distance = 0.0
            for k in i..<j {
                distance += points[k].distance(to: points[k + 1]) * m
            }
            if distance < 30.0 {
                for k in i..<j { layouts[k] = nil }
            }
            i = j
        }

        var offsetSums = [Double](repeating: 0, count: n)
        var offsetCounts = [Int](repeating: 0, count: n)
        var adx = [Double](repeating: 0, count: n)
        var ady = [Double](repeating: 0, count: n)
        var trunkVotes = [Int](repeating: 0, count: n)
        var referenceVotes = [[Int: Int]](repeating: [:], count: n)
        for index in 0..<layouts.count {
            guard let layout = layouts[index] else { continue }
            offsetSums[index] += layout.offset
            offsetSums[index + 1] += layout.offset
            offsetCounts[index] += 1
            offsetCounts[index + 1] += 1
            adx[index] += layout.anchorStart.x - points[index].x
            ady[index] += layout.anchorStart.y - points[index].y
            adx[index + 1] += layout.anchorEnd.x - points[index + 1].x
            ady[index + 1] += layout.anchorEnd.y - points[index + 1].y
            referenceVotes[index][layout.referenceID, default: 0] += 1
            referenceVotes[index + 1][layout.referenceID, default: 0] += 1
            if layout.trunk {
                trunkVotes[index] += 1
                trunkVotes[index + 1] += 1
            }
        }
        var offsets: [Double] = []
        offsets.reserveCapacity(n)
        for index in 0..<n {
            if offsetCounts[index] > 0 {
                adx[index] /= Double(offsetCounts[index])
                ady[index] /= Double(offsetCounts[index])
                offsets.append(offsetSums[index] / Double(offsetCounts[index]))
            } else {
                offsets.append(0.0)
            }
        }
        if trace { traceOffsets("avg", offsets) }
        var stacked = offsetCounts.map { $0 > 0 }
        var trunk = trunkVotes.map { $0 > 0 }
        var referenceIDs: [Int?] = []
        for votes in referenceVotes {
            if votes.isEmpty {
                referenceIDs.append(nil)
                continue
            }
            // (-count, journey id) — the id is the strand array index.
            let best = votes.sorted { first, second in
                if first.value != second.value { return first.value > second.value }
                return first.key < second.key
            }.first
            referenceIDs.append(best?.key)
        }

        // stabilizeCorridorRunOffsets — 72 m blend among shared vertices
        func isShared(_ index: Int) -> Bool {
            (index < layouts.count && layouts[index] != nil)
                || (index > 0 && layouts[index - 1] != nil)
        }
        let transitionDistance = 72.0
        let original = offsets
        for index in 0..<n {
            guard isShared(index) else { continue }
            var weightedSum = original[index]
            var weightTotal = 1.0
            var distance = 0.0
            var back = index
            while back > 0 {
                distance += points[back - 1].distance(to: points[back]) * m
                if distance > transitionDistance || !isShared(back - 1) { break }
                let weight = 1 - distance / transitionDistance
                weightedSum += original[back - 1] * weight
                weightTotal += weight
                back -= 1
            }
            distance = 0
            var forward = index
            while forward < n - 1 {
                distance += points[forward].distance(to: points[forward + 1]) * m
                if distance > transitionDistance || !isShared(forward + 1) { break }
                let weight = 1 - distance / transitionDistance
                weightedSum += original[forward + 1] * weight
                weightTotal += weight
                forward += 1
            }
            offsets[index] = weightedSum / weightTotal
        }

        if trace { traceOffsets("stab72", offsets) }
        // bridgeShortCorridorGaps
        var left = 0
        while left < n - 1 {
            if !stacked[left] {
                left += 1
                continue
            }
            var right = left + 1
            var gap = 0.0
            while right < n {
                gap += points[right - 1].distance(to: points[right]) * m
                if stacked[right] { break }
                right += 1
            }
            if right >= n { break }
            if right <= left + 1 {
                left = right
                continue
            }
            let chord = points[left].distance(to: points[right]) * m
            let lo = offsets[left]
            let ro = offsets[right]
            let sameReference = referenceIDs[left] != nil
                && referenceIDs[right] == referenceIDs[left]
            if gap <= 150.0,
               chord >= 0.75 * gap,
               sameReference,
               lo * ro >= 0,
               abs(lo - ro) <= laneSpacing * 1.1 {
                let bothTrunk = trunk[left] && trunk[right]
                var distanceFromLeft = 0.0
                for k in (left + 1)..<right {
                    distanceFromLeft += points[k - 1].distance(to: points[k]) * m
                    let progress = gap > 0 ? distanceFromLeft / gap : 0
                    offsets[k] = lo + (ro - lo) * progress
                    adx[k] = adx[left] + (adx[right] - adx[left]) * progress
                    ady[k] = ady[left] + (ady[right] - ady[left]) * progress
                    stacked[k] = true
                    trunk[k] = bothTrunk
                    referenceIDs[k] = referenceIDs[left]
                }
            }
            left = right
        }

        // stabilizeSharedAlignmentTransitions — [.25 .5 .25]
        let ox = adx
        let oy = ady
        for index in 1..<(n - 1) where
            stacked[index - 1] && stacked[index] && stacked[index + 1] {
            adx[index] = 0.25 * ox[index - 1] + 0.5 * ox[index] + 0.25 * ox[index + 1]
            ady[index] = 0.25 * oy[index - 1] + 0.5 * oy[index] + 0.25 * oy[index + 1]
        }

        // tapers — 58 m before/after each stacked run (max-abs candidate)
        let taperDistance = 58.0
        i = 0
        while i < n {
            while i < n && !stacked[i] { i += 1 }
            if i >= n { break }
            let runStart = i
            while i < n && stacked[i] { i += 1 }
            let runEnd = i - 1
            var accumulated = 0.0
            if runStart - 1 >= 0 {
                var backIndex = runStart - 1
                while backIndex >= 0 {
                    if stacked[backIndex] { break }
                    accumulated += points[backIndex]
                        .distance(to: points[backIndex + 1]) * m
                    if accumulated >= taperDistance { break }
                    let factor = 1 - accumulated / taperDistance
                    let candidate = offsets[runStart] * factor
                    if abs(candidate) > abs(offsets[backIndex]) {
                        offsets[backIndex] = candidate
                    }
                    let cx = adx[runStart] * factor
                    let cy = ady[runStart] * factor
                    if (cx * cx + cy * cy)
                        > (adx[backIndex] * adx[backIndex]
                            + ady[backIndex] * ady[backIndex]) {
                        adx[backIndex] = cx
                        ady[backIndex] = cy
                    }
                    backIndex -= 1
                }
            }
            accumulated = 0
            for forwardIndex in (runEnd + 1)..<n {
                if stacked[forwardIndex] { break }
                accumulated += points[forwardIndex - 1]
                    .distance(to: points[forwardIndex]) * m
                if accumulated >= taperDistance { break }
                let factor = 1 - accumulated / taperDistance
                let candidate = offsets[runEnd] * factor
                if abs(candidate) > abs(offsets[forwardIndex]) {
                    offsets[forwardIndex] = candidate
                }
                let cx = adx[runEnd] * factor
                let cy = ady[runEnd] * factor
                if (cx * cx + cy * cy)
                    > (adx[forwardIndex] * adx[forwardIndex]
                        + ady[forwardIndex] * ady[forwardIndex]) {
                    adx[forwardIndex] = cx
                    ady[forwardIndex] = cy
                }
            }
        }

        if trace { traceOffsets("tapers", offsets) }
        // hairpin decays
        let hairpinTaper = 58.0
        if n > 2 {
            for reversal in 1..<(n - 1) {
                let u0x = points[reversal].x - points[reversal - 1].x
                let u0y = points[reversal].y - points[reversal - 1].y
                let u1x = points[reversal + 1].x - points[reversal].x
                let u1y = points[reversal + 1].y - points[reversal].y
                let l0 = (u0x * u0x + u0y * u0y).squareRoot()
                let l1 = (u1x * u1x + u1y * u1y).squareRoot()
                if l0 < 1e-6 || l1 < 1e-6 { continue }
                if (u0x / l0) * (u1x / l1) + (u0y / l0) * (u1y / l1) >= -0.6 {
                    continue
                }
                offsets[reversal] = 0
                var accumulated = 0.0
                var backIndex = reversal - 1
                while backIndex >= 0 {
                    accumulated += points[backIndex]
                        .distance(to: points[backIndex + 1]) * m
                    if accumulated >= hairpinTaper { break }
                    offsets[backIndex] *= accumulated / hairpinTaper
                    backIndex -= 1
                }
                accumulated = 0
                for forwardIndex in (reversal + 1)..<n {
                    accumulated += points[forwardIndex - 1]
                        .distance(to: points[forwardIndex]) * m
                    if accumulated >= hairpinTaper { break }
                    offsets[forwardIndex] *= accumulated / hairpinTaper
                }
            }
        }

        if trace { traceOffsets("hairpin", offsets) }
        // alignment rate clamp — two symmetric passes
        if rateClamp > 0 {
            for index in 1..<n {
                let segmentMeters = points[index - 1].distance(to: points[index]) * m
                let budget = rateClamp * segmentMeters
                let stepX = adx[index] - adx[index - 1]
                let stepY = ady[index] - ady[index - 1]
                let step = (stepX * stepX + stepY * stepY).squareRoot()
                if step > budget && budget > 0 {
                    let t = budget / step
                    adx[index] = adx[index - 1] + stepX * t
                    ady[index] = ady[index - 1] + stepY * t
                }
            }
            if n >= 2 {
                for index in stride(from: n - 2, through: 0, by: -1) {
                    let segmentMeters = points[index]
                        .distance(to: points[index + 1]) * m
                    let budget = rateClamp * segmentMeters
                    let stepX = adx[index] - adx[index + 1]
                    let stepY = ady[index] - ady[index + 1]
                    let step = (stepX * stepX + stepY * stepY).squareRoot()
                    if step > budget && budget > 0 {
                        let t = budget / step
                        adx[index] = adx[index + 1] + stepX * t
                        ady[index] = ady[index + 1] + stepY * t
                    }
                }
            }
        }

        var aligned: [ProjectedPoint] = []
        aligned.reserveCapacity(n)
        for index in 0..<n {
            aligned.append(ProjectedPoint(
                x: points[index].x + adx[index],
                y: points[index].y + ady[index]
            ))
        }
        return Layout(
            points: points,
            aligned: aligned,
            offsets: offsets,
            stacked: stacked,
            deltaX: adx,
            deltaY: ady,
            metersPerUnit: m,
            referenceIDs: referenceIDs
        )
    }

    // ------------------------------------------------------------------
    // Build: main vs scheduled layouts for a scenario
    // ------------------------------------------------------------------

    /// Run main's lane source over every strand and push the result through
    /// the shared pipeline.
    static func mainLayouts(
        strands: [Strand],
        scan: [[[Match]]],
        selected: Int? = nil,
        highlighted: [Int]? = nil
    ) -> [Int: Layout] {
        var layouts: [Int: Layout] = [:]
        for index in 0..<strands.count {
            let strand = strands[index]
            var segments: [SegmentLane?] = []
            for si in 0..<strand.segments.count {
                guard let lane = mainLane(
                    strandIndex: index,
                    segmentIndex: si,
                    strands: strands,
                    scan: scan
                ) else {
                    segments.append(nil)
                    continue
                }
                let anchorStart: ProjectedPoint
                let anchorEnd: ProjectedPoint
                let reference = lane.reference
                if lane.referenceID != index {
                    anchorStart = adoptionProjection(
                        of: strand.segments[si]!.start,
                        onto: reference,
                        metersPerUnit: strand.metersPerUnit
                    )
                    anchorEnd = adoptionProjection(
                        of: strand.segments[si]!.end,
                        onto: reference,
                        metersPerUnit: strand.metersPerUnit
                    )
                } else {
                    anchorStart = strand.segments[si]!.start
                    anchorEnd = strand.segments[si]!.end
                }
                segments.append(SegmentLane(
                    offset: lane.offset,
                    anchorStart: anchorStart,
                    anchorEnd: anchorEnd,
                    referenceID: lane.referenceID,
                    trunk: trunkOwner(
                        strandIndex: index,
                        segmentIndex: si,
                        strands: strands,
                        scan: scan,
                        selected: selected,
                        highlighted: highlighted
                    )
                ))
            }
            layouts[index] = pipeline(strand, segments)
        }
        return layouts
    }

    /// Street-anchor shift: move each shared vertex's adopted anchors
    /// laterally back onto the reference street polyline (capped at 30 m).
    static func applyPathDelta(
        _ strand: Strand,
        strandIndex: Int,
        _ segments: inout [SegmentLane?],
        strands: [Strand],
        scan: [[[Match]]]
    ) {
        let k = strand.metersPerUnit
        var heldCache: [Int: [(x: Double, y: Double)]] = [:]
        var acc = [Double](repeating: 0, count: strand.points.count)
        var cnt = [Int](repeating: 0, count: strand.points.count)
        for si in 0..<segments.count {
            guard segments[si] != nil,
                  si < strand.segments.count,
                  let segment = strand.segments[si],
                  si < scan[strandIndex].count
            else { continue }
            let referenceID = segments[si]!.referenceID
            guard referenceID >= 0, referenceID < strands.count,
                  let match = scan[strandIndex][si].first(where: {
                      $0.strandIndex == referenceID
                  })
            else { continue }
            let reference = match.segment
            let referenceStrand = strands[referenceID]
            let held = heldDirections(referenceStrand, cache: &heldCache)
            if match.ownIndex >= held.count {
                print("PATHDELTA DBG observer \(strand.id) si \(si) ref \(referenceStrand.id) ownIndex \(match.ownIndex) heldCount \(held.count) refSegs \(referenceStrand.segments.count) refPoints \(referenceStrand.points.count)")
            }
            let rh = match.ownIndex < held.count
                ? held[match.ownIndex]
                : (x: reference.unitX, y: reference.unitY)
            let frame: Double = segment.unitX * rh.x + segment.unitY * rh.y
                >= 0 ? 1.0 : -1.0
            let nx = -rh.y
            let ny = rh.x
            let spanX = reference.end.x - reference.start.x
            let spanY = reference.end.y - reference.start.y
            let norm2 = spanX * spanX + spanY * spanY
            if norm2 <= 0 { continue }
            for (vertexIndex, anchor) in [(si, segments[si]!.anchorStart),
                                          (si + 1, segments[si]!.anchorEnd)] {
                let t = max(
                    0,
                    min(
                        1,
                        ((anchor.x - reference.start.x) * spanX
                            + (anchor.y - reference.start.y) * spanY) / norm2
                    )
                )
                let hitX = reference.start.x + t * spanX
                let hitY = reference.start.y + t * spanY
                acc[vertexIndex] += ((anchor.x - hitX) * nx
                    + (anchor.y - hitY) * ny) * k * frame
                cnt[vertexIndex] += 1
            }
        }
        let cap = 30.0 / strand.metersPerUnit
        for si in 0..<segments.count {
            guard segments[si] != nil,
                  si < strand.segments.count,
                  let segment = strand.segments[si]
            else { continue }
            let lx = -segment.unitY
            let ly = segment.unitX
            var shifts: [(Double, Double)?] = [nil, nil]
            for (offset, vertexIndex) in [(0, si), (1, si + 1)] {
                if cnt[vertexIndex] > 0 {
                    var d = (acc[vertexIndex] / Double(cnt[vertexIndex])) / k
                    d = max(-cap, min(cap, d))
                    shifts[offset] = (d * lx, d * ly)
                }
            }
            if let shift = shifts[0] {
                segments[si]!.anchorStart = ProjectedPoint(
                    x: segments[si]!.anchorStart.x - shift.0,
                    y: segments[si]!.anchorStart.y - shift.1
                )
            }
            if let shift = shifts[1] {
                segments[si]!.anchorEnd = ProjectedPoint(
                    x: segments[si]!.anchorEnd.x - shift.0,
                    y: segments[si]!.anchorEnd.y - shift.1
                )
            }
        }
    }

    /// Run the anchored scheduler's lanes over every strand (the "sched"
    /// side of the comparative gates). The schedule comes from
    /// `CorridorLaneSchedule.schedule` over the same strands.
    static func scheduledLayouts(
        strands: [Strand],
        scan: [[[Match]]],
        schedule: [Int: [Int: CorridorLaneSchedule.Sample]],
        selected: Int? = nil,
        highlighted: [Int]? = nil,
        traceStrand: Int? = nil
    ) -> [Int: Layout] {
        var layouts: [Int: Layout] = [:]
        var heldCache: [Int: [(x: Double, y: Double)]] = [:]
        for index in 0..<strands.count {
            let strand = strands[index]
            var segments: [SegmentLane?] = []
            for si in 0..<strand.segments.count {
                guard let lane = scheduledLane(
                    strandIndex: index,
                    segmentIndex: si,
                    strands: strands,
                    scan: scan,
                    schedule: schedule,
                    heldCache: &heldCache
                ) else {
                    segments.append(nil)
                    continue
                }
                let anchorStart: ProjectedPoint
                let anchorEnd: ProjectedPoint
                if let reference = lane.reference, lane.referenceID != index {
                    anchorStart = adoptionProjection(
                        of: strand.segments[si]!.start,
                        onto: reference,
                        metersPerUnit: strand.metersPerUnit
                    )
                    anchorEnd = adoptionProjection(
                        of: strand.segments[si]!.end,
                        onto: reference,
                        metersPerUnit: strand.metersPerUnit
                    )
                } else {
                    anchorStart = strand.segments[si]!.start
                    anchorEnd = strand.segments[si]!.end
                }
                segments.append(SegmentLane(
                    offset: lane.offset,
                    anchorStart: anchorStart,
                    anchorEnd: anchorEnd,
                    referenceID: lane.referenceID,
                    trunk: trunkOwner(
                        strandIndex: index,
                        segmentIndex: si,
                        strands: strands,
                        scan: scan,
                        selected: selected,
                        highlighted: highlighted
                    )
                ))
            }
            applyPathDelta(
                strand,
                strandIndex: index,
                &segments,
                strands: strands,
                scan: scan
            )
            layouts[index] = pipeline(
                strand,
                segments,
                trace: index == traceStrand
            )
        }
        return layouts
    }

    /// The schedule from `CorridorLaneSchedule.schedule` re-keyed onto the
    /// harness's strand indices (harness journey id == array index).
    static func rekeySchedule(
        _ schedule: [CorridorLaneSchedule.StrandKey: [Int: CorridorLaneSchedule.Sample]]
    ) -> [Int: [Int: CorridorLaneSchedule.Sample]] {
        var out: [Int: [Int: CorridorLaneSchedule.Sample]] = [:]
        for (key, entries) in schedule where key.polylineIndex == 0 {
            out[key.journeyID] = entries
        }
        return out
    }



    // ------------------------------------------------------------------
    // Screen-space ribbon — stableRouteOffsetPoints verbatim
    // ------------------------------------------------------------------

    struct Ribbon {
        var points: [(x: Double, y: Double)]
        var lateral: [Double]
    }

    /// stableRouteOffsetPoints: apply lane offsets along the averaged
    /// normal, with the miter limit and reversal side-hold, in screen
    /// points (map points scaled by mpm/mpp with the harness convention
    /// mpp = 2.0).
    static func ribbon(
        _ layout: Layout,
        screenPointsPerMapPoint mpp: Double = 2.0
    ) -> Ribbon {
        let k = layout.metersPerUnit / mpp
        let pts = layout.aligned.map { (x: $0.x * k, y: $0.y * k) }
        let offsets = layout.offsets
        let n = pts.count
        guard n >= 2 else {
            return Ribbon(points: pts, lateral: offsets)
        }
        var directions: [(x: Double, y: Double)] = []
        var previous: (x: Double, y: Double)?
        directions.reserveCapacity(n - 1)
        for i in 0..<(n - 1) {
            let dx = pts[i + 1].x - pts[i].x
            let dy = pts[i + 1].y - pts[i].y
            let length = max(1e-4, (dx * dx + dy * dy).squareRoot())
            var ux = dx / length
            var uy = dy / length
            if let previous, ux * previous.x + uy * previous.y < -0.8 {
                ux = -ux
                uy = -uy
            }
            directions.append((ux, uy))
            previous = (ux, uy)
        }
        var out: [(x: Double, y: Double)] = []
        var lateral: [Double] = []
        out.reserveCapacity(n)
        lateral.reserveCapacity(n)
        for i in 0..<n {
            let pd = directions[i > 0 ? i - 1 : 0]
            let nd = directions[i < n - 1 ? i : n - 2]
            let pn = (x: -pd.y, y: pd.x)
            let nn = (x: -nd.y, y: nd.x)
            let sx = pn.x + nn.x
            let sy = pn.y + nn.y
            let sl = (sx * sx + sy * sy).squareRoot()
            let local = offsets[i]
            var normal = nn
            var scale = Double(local)
            if sl > 0.001 {
                normal = (sx / sl, sy / sl)
                let denom = normal.x * nn.x + normal.y * nn.y
                if denom > 0.25 {
                    scale = local / denom
                }
            }
            let maximumMiter = abs(local) * 1.75
            scale = local >= 0
                ? max(0, min(maximumMiter, scale))
                : min(0, max(-maximumMiter, scale))
            out.append((pts[i].x + normal.x * scale, pts[i].y + normal.y * scale))
            lateral.append(scale * (normal.x * nn.x + normal.y * nn.y))
        }
        return Ribbon(points: out, lateral: lateral)
    }

    // ------------------------------------------------------------------
    // Metrics
    // ------------------------------------------------------------------

    /// Proper crossing: intersection strictly interior on both segments.
    static func segmentsCross(
        _ a1: (x: Double, y: Double),
        _ a2: (x: Double, y: Double),
        _ b1: (x: Double, y: Double),
        _ b2: (x: Double, y: Double),
        eps: Double = 0.02
    ) -> Bool {
        let d1x = a2.x - a1.x
        let d1y = a2.y - a1.y
        let d2x = b2.x - b1.x
        let d2y = b2.y - b1.y
        let den = d1x * d2y - d1y * d2x
        if abs(den) < 1e-12 { return false }
        let t = ((b1.x - a1.x) * d2y - (b1.y - a1.y) * d2x) / den
        let u = ((b1.x - a1.x) * d1y - (b1.y - a1.y) * d1x) / den
        return eps < t && t < 1 - eps && eps < u && u < 1 - eps
    }

    /// Pairwise proper crossings between different strands' ribbons.
    static func countCrossings(_ ribbons: [Int: Ribbon]) -> Int {
        var total = 0
        let ids = ribbons.keys.sorted()
        for ii in 0..<ids.count {
            for jj in (ii + 1)..<ids.count {
                let a = ribbons[ids[ii]]!.points
                let b = ribbons[ids[jj]]!.points
                for i in 0..<(a.count - 1) {
                    for k in 0..<(b.count - 1) where
                        segmentsCross(a[i], a[i + 1], b[k], b[k + 1]) {
                        total += 1
                    }
                }
            }
        }
        return total
    }

    /// Crossings between two strands that are BOTH stacked and both well
    /// inside their stacked runs — the ordering artifacts a subway-style
    /// corridor must not have; stub merges at junctions are inherent.
    static func countBundleCrossings(
        _ layouts: [Int: Layout],
        _ ribbons: [Int: Ribbon],
        guardSegments: Int = 4
    ) -> (total: Int, pairs: [(Int, Int, Int)]) {
        var total = 0
        var pairs: [(Int, Int, Int)] = []
        let ids = layouts.keys.sorted()
        for ii in 0..<ids.count {
            for jj in (ii + 1)..<ids.count {
                let la = layouts[ids[ii]]!
                let lb = layouts[ids[jj]]!
                let ra = ribbons[ids[ii]]!.points
                let rb = ribbons[ids[jj]]!.points
                let sa = la.stacked
                let sb = lb.stacked

                func inside(_ stacked: [Bool], _ i: Int) -> Bool {
                    if !stacked[i] { return false }
                    var lo = i
                    while lo > 0 && stacked[lo - 1] { lo -= 1 }
                    var hi = i
                    while hi < stacked.count - 1 && stacked[hi + 1] { hi += 1 }
                    return i - lo >= guardSegments && hi - i >= guardSegments
                }

                var hit = 0
                for i in 0..<(ra.count - 1) {
                    guard sa[i] && sa[i + 1] && inside(sa, i) else { continue }
                    for k in 0..<(rb.count - 1) {
                        guard sb[k] && sb[k + 1] && inside(sb, k) else { continue }
                        if segmentsCross(ra[i], ra[i + 1], rb[k], rb[k + 1]) {
                            hit += 1
                        }
                    }
                }
                if hit > 0 {
                    pairs.append((ids[ii], ids[jj], hit))
                }
                total += hit
            }
        }
        return (total, pairs)
    }

    /// Nearest point of a polyline to p, searching a moving window around
    /// the last hit (full search when window is nil). With reanchorDistance,
    /// a windowed hit farther than that triggers one full re-search.
    static func nearestOnPolyline(
        _ pts: [(x: Double, y: Double)],
        _ p: (x: Double, y: Double),
        start: Int = 0,
        window: Int? = nil,
        reanchorDistance: Double? = nil
    ) -> (segmentIndex: Int, t: Double, hit: (x: Double, y: Double)) {
        let n = pts.count
        var best: (distanceSquared: Double, segmentIndex: Int, t: Double, hit: (x: Double, y: Double))?
        let lo = window == nil ? 0 : max(0, start - window!)
        let hi = window == nil ? n - 1 : min(n - 1, start + window!)
        for i in lo..<hi {
            let ax = pts[i].x
            let ay = pts[i].y
            let dx = pts[i + 1].x - ax
            let dy = pts[i + 1].y - ay
            let l2 = dx * dx + dy * dy
            var t = l2 < 1e-12 ? 0.0 : ((p.x - ax) * dx + (p.y - ay) * dy) / l2
            t = max(0, min(1, t))
            let hx = ax + dx * t
            let hy = ay + dy * t
            let d = (p.x - hx) * (p.x - hx) + (p.y - hy) * (p.y - hy)
            if best == nil || d < best!.distanceSquared {
                best = (d, i, t, (hx, hy))
            }
        }
        if let window, let reanchorDistance,
           let best, best.distanceSquared > reanchorDistance * reanchorDistance {
            return nearestOnPolyline(pts, p, start: 0, window: nil)
        }
        guard let best else {
            return (0, 0, pts.first ?? (0, 0))
        }
        return (best.segmentIndex, best.t, best.hit)
    }

    /// Screen-space frame of a spine journey: polyline scaled to screen
    /// points, held-normal chain (stable across the spine's own 180-degree
    /// reversals), cumulative arc, and per-vertex turn flags.
    static func spineFrame(
        _ spineIndex: Int,
        strands: [Strand],
        screenPointsPerMapPoint mpp: Double
    ) -> SpineFrame {
        let g = strands[spineIndex]
        let k = g.metersPerUnit / mpp
        let pts = g.points.map { (x: $0.x * k, y: $0.y * k) }
        var heldCache: [Int: [(x: Double, y: Double)]] = [:]
        let held = heldDirections(g, cache: &heldCache)
        var dirs: [(x: Double, y: Double)] = []
        var last = (x: 1.0, y: 0.0)
        for i in 0..<g.segments.count {
            let segment = g.segments[i]
            let d = held.count > i ? held[i]
                : (segment != nil ? (x: segment!.unitX, y: segment!.unitY) : last)
            last = d
            dirs.append((-d.y, d.x))
        }
        var arc = [0.0]
        for i in 0..<(pts.count - 1) {
            arc.append(arc.last! + ((pts[i + 1].x - pts[i].x) * (pts[i + 1].x - pts[i].x)
                + (pts[i + 1].y - pts[i].y) * (pts[i + 1].y - pts[i].y)).squareRoot())
        }
        var turn = [Int](repeating: 0, count: pts.count)
        let cos8 = cos(8.0 * Double.pi / 180)
        for i in 1..<(pts.count - 1) {
            let d0 = dirs[i - 1]
            let d1 = dirs[i]
            if d0.x * d1.x + d0.y * d1.y < cos8 { turn[i] = 1 }
        }
        return (pts, dirs, arc, turn)
    }

    /// Project the DRAWN ribbon of a layout onto one fixed spine, walking a
    /// cursor (full search for the first sample, re-anchoring when the
    /// windowed hit is implausibly far). Returns per-vertex (spine arc,
    /// lateral, on-corner) — lateral in screen points against the spine's
    /// held-normal chain, so corners and reversals cannot flip its sign.
    static func projectOntoSpine(
        _ layout: Layout,
        spineFrame: SpineFrame,
        screenPointsPerMapPoint mpp: Double = 2.0
    ) -> [(Double, Double, Bool)?] {
        let ribbonValue = ribbon(layout, screenPointsPerMapPoint: mpp)
        let pts = ribbonValue.points
        let stacked = layout.stacked
        var out = [(Double, Double, Bool)?](repeating: nil, count: pts.count)
        var cursor: Int?
        for i in 0..<pts.count {
            guard stacked[i] else { continue }
            let hit: (segmentIndex: Int, t: Double, hit: (x: Double, y: Double))
            if let cursor {
                hit = nearestOnPolyline(
                    spineFrame.pts,
                    pts[i],
                    start: cursor,
                    window: 16,
                    reanchorDistance: 40.0
                )
            } else {
                hit = nearestOnPolyline(spineFrame.pts, pts[i], start: 0)
            }
            cursor = hit.segmentIndex
            let normal = spineFrame.normals[hit.segmentIndex]
            let lat = (pts[i].x - hit.hit.x) * normal.x
                + (pts[i].y - hit.hit.y) * normal.y
            let corner = spineFrame.turn[hit.segmentIndex] == 1
                || (hit.segmentIndex + 1 < spineFrame.turn.count
                    && spineFrame.turn[hit.segmentIndex + 1] == 1)
            let arcValue = spineFrame.arc[hit.segmentIndex]
                + hit.t * (spineFrame.arc[hit.segmentIndex + 1]
                    - spineFrame.arc[hit.segmentIndex])
            out[i] = (arcValue, lat, corner)
        }
        return out
    }

    struct PairMetrics {
        var drift: Double?
        var gap: Double?
        var spine: Int
        var pairs: Int
    }

    /// Relative drift and minimum gap between two stacked strands on ONE
    /// common spine (a's dominant reference). Samples are paired by spine
    /// arc; excluded: spine corners (miter pinch), samples far off the
    /// spine (another street), and samples within `edge` of a stacked or
    /// reference boundary on either side (tapered joins and leaves).
    static func pairMetricsOne(
        _ a: Layout,
        _ b: Layout,
        strands: [Strand],
        strandIndexA: Int,
        spineFrames: inout [Int: SpineFrame],
        screenPointsPerMapPoint mpp: Double = 2.0,
        edge: Int = 3
    ) -> PairMetrics? {
        let votes = a.referenceIDs.enumerated().compactMap { index, reference -> Int? in
            guard a.stacked[index], let reference, reference < strands.count else {
                return nil
            }
            return reference
        }
        var counts: [Int: Int] = [:]
        for reference in votes { counts[reference, default: 0] += 1 }
        guard let spine = counts.max(by: {
            $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key
        })?.key else { return nil }

        let frameKey = spine
        if spineFrames[frameKey] == nil {
            spineFrames[frameKey] = spineFrame(spine, strands: strands, screenPointsPerMapPoint: mpp)
        }
        let frame = spineFrames[frameKey]!
        let pa = projectOntoSpine(a, spineFrame: frame, screenPointsPerMapPoint: mpp)
        let pb = projectOntoSpine(b, spineFrame: frame, screenPointsPerMapPoint: mpp)
        let sa = a.stacked
        let sb = b.stacked
        let n = pa.count
        let mCount = pb.count
        var border: [(Double, Int)] = []
        for (k, sample) in pb.enumerated() {
            if let sample { border.append((sample.0, k)) }
        }
        guard !border.isEmpty else { return nil }
        border.sort { $0.0 < $1.0 }
        let barcs = border.map { $0.0 }
        var good: [(drift: Double, i: Int, k: Int, arcA: Double, arcB: Double)] = []
        for i in 0..<n {
            guard let sampleA = pa[i] else { continue }
            let ai = sampleA.0
            // bisect_left
            var pos = barcs.firstIndex(where: { $0 >= ai }) ?? barcs.count
            pos = max(0, pos)
            var candidates: [Int] = []
            if pos - 1 >= 0 && pos - 1 < border.count { candidates.append(pos - 1) }
            if pos >= 0 && pos < border.count { candidates.append(pos) }
            guard let best = candidates.min(by: {
                abs(border[$0].0 - ai) < abs(border[$1].0 - ai)
            }) else { continue }
            let arcB = border[best].0
            let k = border[best].1
            if abs(arcB - ai) > 6.0 { continue }
            if sampleA.2 || pb[k]!.2 { continue }
            if abs(sampleA.1) > 50.0 || abs(pb[k]!.1) > 50.0 { continue }
            var ok = true
            for j in max(0, i - edge)..<min(n, i + edge + 1) {
                guard sa[j], a.referenceIDs[j] == spine else {
                    ok = false
                    break
                }
            }
            if ok {
                for j in max(0, k - edge)..<min(mCount, k + edge + 1) {
                    guard sb[j] else {
                        ok = false
                        break
                    }
                }
            }
            if ok {
                good.append((sampleA.1 - pb[k]!.1, i, k, ai, arcB))
            }
        }
        if good.count < 4 {
            return PairMetrics(drift: nil, gap: nil, spine: spine, pairs: good.count)
        }
        // Split into monotone passes: a U-turn route passes the same street
        // twice, and its two legs must never be compared.
        var passes: [[(drift: Double, i: Int, k: Int, arcA: Double, arcB: Double)]] = []
        var current = [good[0]]
        for index in 1..<good.count {
            let previous = good[index - 1]
            let next = good[index]
            let da = next.arcA - previous.arcA
            let db = next.arcB - previous.arcB
            var flip = false
            if current.count > 1 {
                let aDir = current[current.count - 1].arcA - current[current.count - 2].arcA
                let bDir = current[current.count - 1].arcB - current[current.count - 2].arcB
                if (da > 0) != (aDir > 0) || (db > 0) != (bDir > 0) { flip = true }
            }
            if abs(da) > 50 || abs(db) > 50 || flip {
                passes.append(current)
                current = [next]
            } else {
                current.append(next)
            }
        }
        passes.append(current)
        var drift: Double?
        for pass in passes where pass.count >= 4 {
            // a merge from an adjacent lane sweeps while it converges: a
            // join, not mid-run drift — trim both ends of the pass.
            let trim = max(1, pass.count / 5)
            let core = pass.count > 2 * trim
                ? Array(pass[trim..<(pass.count - trim)])
                : pass
            let ds = core.map { $0.drift }.sorted()
            let lo = ds[Int(0.05 * Double(ds.count - 1))]
            let hi = ds[Int(0.95 * Double(ds.count - 1))]
            let nd = (hi - lo) / laneSpacing
            if drift == nil || nd > drift! { drift = nd }
        }
        let absLat = good.map { abs($0.drift) }.sorted()
        let gapIndex = min(
            absLat.count - 1,
            max(0, Int((0.05 * Double(absLat.count - 1)).rounded(.toNearestOrEven)))
        )
        let gap = absLat[gapIndex] / laneSpacing
        return PairMetrics(drift: drift, gap: gap, spine: spine, pairs: good.count)
    }

    /// Orientation-stable: measure both directions (each observer's
    /// dominant spine can differ) and keep the one with more matched
    /// interior pairs, so pm(a,b) == pm(b,a).
    static func pairMetrics(
        _ a: Layout,
        _ b: Layout,
        strands: [Strand],
        strandIndexA: Int,
        strandIndexB: Int,
        spineFrames: inout [Int: SpineFrame],
        screenPointsPerMapPoint mpp: Double = 2.0,
        edge: Int = 3
    ) -> PairMetrics? {
        let r1 = pairMetricsOne(
            a, b,
            strands: strands,
            strandIndexA: strandIndexA,
            spineFrames: &spineFrames,
            screenPointsPerMapPoint: mpp,
            edge: edge
        )
        let r2 = pairMetricsOne(
            b, a,
            strands: strands,
            strandIndexA: strandIndexB,
            spineFrames: &spineFrames,
            screenPointsPerMapPoint: mpp,
            edge: edge
        )
        if r1 == nil { return r2 }
        if r2 == nil { return r1 }
        if r1!.pairs > r2!.pairs || (r1!.pairs == r2!.pairs && r1!.spine <= r2!.spine) {
            return r1
        }
        return r2
    }

    static func shareCorridor(
        _ a: Int,
        _ b: Int,
        strands: [Strand],
        scan: [[[Match]]]
    ) -> Bool {
        guard a < scan.count else { return false }
        let differentKey = strands[a].publicRouteKey != strands[b].publicRouteKey
        guard differentKey else { return false }
        return scan[a].contains { row in
            row.contains { $0.strandIndex == b }
        }
    }

    /// Worst-pair relative drift across the bundle, in lanes.
    static func bundleWobble(
        _ layouts: [Int: Layout],
        strands: [Strand],
        scan: [[[Match]]],
        spineFrames: inout [Int: SpineFrame],
        screenPointsPerMapPoint mpp: Double = 2.0
    ) -> Double {
        var worst: Double?
        let ids = layouts.keys.sorted()
        for ii in 0..<ids.count {
            for jj in (ii + 1)..<ids.count {
                guard shareCorridor(ids[ii], ids[jj], strands: strands, scan: scan)
                else { continue }
                let pm = pairMetrics(
                    layouts[ids[ii]]!,
                    layouts[ids[jj]]!,
                    strands: strands,
                    strandIndexA: ids[ii],
                    strandIndexB: ids[jj],
                    spineFrames: &spineFrames,
                    screenPointsPerMapPoint: mpp
                )
                if let drift = pm?.drift {
                    if worst == nil || drift > worst! { worst = drift }
                }
            }
        }
        return worst ?? 0.0
    }

    /// Smallest gap between two stacked strands sharing a corridor, in
    /// lanes, measured on a common spine (frame-free).
    static func minLaneSeparation(
        _ layouts: [Int: Layout],
        strands: [Strand],
        scan: [[[Match]]],
        spineFrames: inout [Int: SpineFrame],
        screenPointsPerMapPoint mpp: Double = 2.0
    ) -> Double? {
        var worst: Double?
        let ids = layouts.keys.sorted()
        for ii in 0..<ids.count {
            for jj in (ii + 1)..<ids.count {
                guard shareCorridor(ids[ii], ids[jj], strands: strands, scan: scan)
                else { continue }
                let pm = pairMetrics(
                    layouts[ids[ii]]!,
                    layouts[ids[jj]]!,
                    strands: strands,
                    strandIndexA: ids[ii],
                    strandIndexB: ids[jj],
                    spineFrames: &spineFrames,
                    screenPointsPerMapPoint: mpp
                )
                if let gap = pm?.gap {
                    if worst == nil || gap < worst! { worst = gap }
                }
            }
        }
        return worst
    }

    /// Worst per-vertex step of the alignment-correction vector, in metres,
    /// over consecutive vertices inside a stacked run.
    static func alignmentKink(_ layout: Layout) -> Double {
        var worst = 0.0
        for i in 0..<(layout.deltaX.count - 1)
        where layout.stacked[i] && layout.stacked[i + 1] {
            let dx = layout.deltaX[i + 1] - layout.deltaX[i]
            let dy = layout.deltaY[i + 1] - layout.deltaY[i]
            worst = max(
                worst,
                (dx * dx + dy * dy).squareRoot() * layout.metersPerUnit
            )
        }
        return worst
    }
}

extension LaneHarness.Strand {
    var identifierKey: Int {
        // Deterministic per-strand key for the held-direction cache
        // (djb2 over the id's UTF-8; Hasher's seed is random per process,
        // which once let two ids collide on one run and not the next).
        var hash: UInt64 = 5381
        for byte in id.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return Int(truncatingIfNeeded: hash >> 1)
    }
}
