import Foundation

/// The corridor lane layout: consumes the anchored schedule and produces,
/// per strand, the per-vertex lane offsets, shared flags, and trunk-owner
/// flags the renderer's ribbons are drawn from.
///
/// This is the WayboundCore port of the shipped app's layout stage
/// (`WayboundMapView.sharedCorridorLaneLayout` and the passes it runs:
/// short-run pruning, per-vertex averaging, run-offset stabilization,
/// short-gap bridging, end taper, hairpin decay). The stage consumes the
/// schedule and nothing else about the device state, so the golden tests
/// can reproduce the device-exported layouts from the exports alone.
///
/// Port boundary (deliberate): the app additionally threads per-vertex
/// centerline-alignment deltas through these passes (reference projection
/// with a 6 m adoption cap, street-anchored anchor shift capped at 30 m,
/// delta smoothing, alignment rate clamp). Deltas never feed the offset,
/// shared, or trunk outputs — they only shape the drawn centerline — and
/// they are not part of the lane-diagnostics export, so this port omits
/// them. The centerline-alignment machinery stays app-side until the app
/// flips to importing this package, at which point the draw path consumes
/// it directly.
///
/// Faithfulness notes (behavior-preserving on the fixtures):
///  - Membership, reference matching, and the sticky-reference selection
///    come from the same scan the scheduler runs (`CorridorMembership`),
///    golden-pinned to the device's scan.
///  - Distances and laterals both convert through the conformal
///    `GeoProjection.metersPerUnit`; the app calibrates runtime scales
///    that agree with it (the pinned schedule golden at 100.00% exercises
///    the same conversions in the scheduler's reads).
///  - `enteringOffset` is assigned in the app but never read; omitted.
public enum CorridorLaneLayoutEngine {

    /// Per-vertex lane structure of one strand, the fields the lane
    /// diagnostics export carries as `layouts`.
    public struct VertexLayout: Equatable, Sendable {
        /// Lane points per vertex (multiples of `laneSpacingPoints`),
        /// applied along the strand's own travel direction.
        public let offsets: [Double]
        /// True where the vertex carries a corridor lane (including
        /// bridged dropouts).
        public let shared: [Bool]
        /// True where the vertex's strand is the corridor's dominant
        /// public route (the consolidated trunk at far zoom).
        public let trunk: [Bool]

        init(offsets: [Double], shared: [Bool], trunk: [Bool]) {
            self.offsets = offsets
            self.shared = shared
            self.trunk = trunk
        }
    }

    /// One segment's lane assignment before per-vertex averaging: the
    /// schedule offset in the strand's own frame, the corridor reference
    /// the segment anchored to (drives the reference votes the bridge
    /// gates on), and whether the segment's strand is the trunk owner.
    struct SegmentLayout {
        let offset: Double
        let referenceID: Int
        let isTrunkOwner: Bool
    }

    /// A strand's projected geometry: densified points, optional segments,
    /// and the conformal meter scale.
    struct StrandGeometry {
        let points: [ProjectedPoint]
        let segments: [CorridorMembership.CorridorSegment?]
        let metersPerUnit: Double
    }

    // ------------------------------------------------------------------
    // Entry point
    // ------------------------------------------------------------------

    /// Build lane layouts for every strand. `schedule` is the anchored
    /// schedule — the device's export or `CorridorLaneSchedule.schedule`'s
    /// output. `selectedJourneyID` (nil when none) pins corridor dominance
    /// to the user's selected route, exactly as the app does.
    public static func layouts(
        journeys: [LaneDiagnosticsDocument.Journey],
        schedule: [CorridorLaneSchedule.StrandKey: [Int: CorridorLaneSchedule.Sample]],
        selectedJourneyID: Int?,
        laneSpacingPoints: Double
    ) -> [CorridorLaneSchedule.StrandKey: VertexLayout] {
        guard !journeys.isEmpty else { return [:] }

        var identities: [Int: CorridorLaneSchedule.JourneyIdentity] = [:]
        var departures: [Int: Int] = [:]
        for journey in journeys {
            identities[journey.id] = CorridorLaneSchedule
                .JourneyIdentity(journey: journey)
            departures[journey.id] = journey.departures
        }

        var geometry: [CorridorLaneSchedule.StrandKey: StrandGeometry] = [:]
        var held: [CorridorLaneSchedule.StrandKey: [(x: Double, y: Double)]] = [:]
        for journey in journeys {
            for (polylineIndex, polyline) in journey.polylines.enumerated() {
                guard polyline.count >= 2 else { continue }
                let points = polyline.map { $0.projected }
                let metersPerUnit = GeoProjection.metersPerUnit(
                    atLatitude: polyline[0].latitude
                )
                var segments: [CorridorMembership.CorridorSegment?] = []
                segments.reserveCapacity(points.count - 1)
                for index in 0..<(points.count - 1) {
                    segments.append(CorridorMembership.CorridorSegment(
                        start: points[index],
                        end: points[index + 1]
                    ))
                }
                let key = CorridorLaneSchedule.StrandKey(
                    journeyID: journey.id,
                    polylineIndex: polylineIndex
                )
                geometry[key] = StrandGeometry(
                    points: points,
                    segments: segments,
                    metersPerUnit: metersPerUnit
                )

                // Held direction chain: the renderer's reversal hold.
                var directions: [(x: Double, y: Double)] = []
                var previous: (x: Double, y: Double)?
                for segment in segments {
                    if let segment {
                        var unitX = segment.unitX
                        var unitY = segment.unitY
                        if let previous,
                           unitX * previous.x + unitY * previous.y < -0.8 {
                            unitX = -unitX
                            unitY = -unitY
                        }
                        directions.append((unitX, unitY))
                        previous = (unitX, unitY)
                    } else {
                        directions.append(previous ?? (x: 1, y: 0))
                    }
                }
                held[key] = directions
            }
        }

        // The membership scan: per strand segment, which other journeys run
        // a parallel segment there and where on the candidate it matched.
        let scan = CorridorMembership.scan(
            journeys: journeys,
            laneSpacingPoints: laneSpacingPoints
        )
        var scanRows: [CorridorLaneSchedule.StrandKey:
            [[Int: CorridorMembership.CandidateLocation]]] = [:]
        for (key, rows) in scan.rows {
            scanRows[CorridorLaneSchedule.StrandKey(
                journeyID: key.journeyID,
                polylineIndex: key.polylineIndex
            )] = rows
        }

        var output: [CorridorLaneSchedule.StrandKey: VertexLayout] = [:]
        for (key, strand) in geometry {
            let rows = scanRows[key] ?? []
            let samples = schedule[key] ?? [:]
            let segmentLayouts: [SegmentLayout?] = (0..<strand.segments.count)
                .map { segmentIndex in
                    segmentLayout(
                        key: key,
                        segmentIndex: segmentIndex,
                        strand: strand,
                        rows: rows,
                        samples: samples,
                        geometry: geometry,
                        identities: identities,
                        departures: departures,
                        held: held,
                        selectedJourneyID: selectedJourneyID
                    )
                }
            output[key] = assembleLayout(
                strand: strand,
                segmentLayouts: segmentLayouts,
                identities: identities,
                laneSpacingPoints: laneSpacingPoints
            )
        }
        return output
    }

    // ------------------------------------------------------------------
    // Per-segment lane assignment
    // ------------------------------------------------------------------

    /// The app's `sharedCorridorSegmentLayout`, reduced to the fields the
    /// exported lane structure consumes. Members come from the scan rows
    /// (same midpoint + endpoint gates); the lane comes from the schedule
    /// converted into the strand's own held-direction frame; dominance and
    /// trunk ownership come from public identity and observed departures.
    static func segmentLayout(
        key: CorridorLaneSchedule.StrandKey,
        segmentIndex: Int,
        strand: StrandGeometry,
        rows: [[Int: CorridorMembership.CandidateLocation]],
        samples: [Int: CorridorLaneSchedule.Sample],
        geometry: [CorridorLaneSchedule.StrandKey: StrandGeometry],
        identities: [Int: CorridorLaneSchedule.JourneyIdentity],
        departures: [Int: Int],
        held: [CorridorLaneSchedule.StrandKey: [(x: Double, y: Double)]],
        selectedJourneyID: Int?
    ) -> SegmentLayout? {
        guard segmentIndex < strand.segments.count,
              let segment = strand.segments[segmentIndex],
              segmentIndex < rows.count
        else { return nil }

        // Members: the strand's own segment plus each candidate's matched
        // segment (the nearest midpoint match the scan recorded).
        var memberSegments: [Int: CorridorMembership.CorridorSegment] = [
            key.journeyID: segment
        ]
        for (candidateID, location) in rows[segmentIndex] {
            guard
                let candidate = geometry[CorridorLaneSchedule.StrandKey(
                    journeyID: candidateID,
                    polylineIndex: location.polylineIndex
                )],
                location.segmentIndex + 1 < candidate.points.count,
                let matched = CorridorMembership.CorridorSegment(
                    start: candidate.points[location.segmentIndex],
                    end: candidate.points[location.segmentIndex + 1]
                )
            else { continue }
            memberSegments[candidateID] = matched
        }
        guard memberSegments.count > 1 else { return nil }

        // Public route identity — not live utility ranking — defines the
        // lateral order.
        let memberIDs = memberSegments.keys.sorted {
            guard let first = identities[$0],
                  let second = identities[$1]
            else { return $0 < $1 }
            return CorridorLaneSchedule.laneComesBefore(first, second)
        }

        // Dominance: a user-selected member wins outright; otherwise (the
        // app's highlight set is not part of the export and is nil in the
        // export flow) every member is a candidate. Most observed
        // departures wins, then stack order, then id.
        let dominanceCandidates: [Int]
        if let selectedID = selectedJourneyID,
           memberIDs.contains(selectedID) {
            dominanceCandidates = [selectedID]
        } else {
            dominanceCandidates = memberIDs
        }
        guard let dominantID = dominanceCandidates.min(by: {
            let firstDepartures = departures[$0] ?? 0
            let secondDepartures = departures[$1] ?? 0
            if firstDepartures != secondDepartures {
                return firstDepartures > secondDepartures
            }
            let firstOrder = identities[$0]?.stackOrder ?? Int.max
            let secondOrder = identities[$1]?.stackOrder ?? Int.max
            if firstOrder != secondOrder { return firstOrder < secondOrder }
            return $0 < $1
        }) else { return nil }

        // Anchored lane: this segment's lane comes from the schedule,
        // chosen once when the strand entered this corridor and held while
        // it continues. Convert into the strand's own frame via the held
        // direction chain (the renderer's reversal hold), so hairpins keep
        // the physical side.
        guard let sample = samples[segmentIndex] else { return nil }
        let heldDirection = held[key]?[segmentIndex]
            ?? (x: segment.unitX, y: segment.unitY)
        let frameSign: Double = heldDirection.x * sample.directionX
            + heldDirection.y * sample.directionY >= 0 ? 1 : -1
        let localOffset = sample.offset * frameSign

        // Alignment anchors follow the schedule's sticky corridor reference
        // when it is locally matched; a reference not visible from this
        // sample falls back to the first member by public identity.
        let referenceID: Int
        if memberSegments[sample.referenceID] != nil {
            referenceID = sample.referenceID
        } else {
            referenceID = memberIDs.first ?? key.journeyID
        }

        // Trunk ownership belongs to the dominant public route, not to one
        // journey of it.
        let journeyIdentity = identities[key.journeyID]
        let dominantIdentity = identities[dominantID]
        let isTrunkOwner = journeyIdentity?.publicRouteKey
            == dominantIdentity?.publicRouteKey

        return SegmentLayout(
            offset: localOffset,
            referenceID: referenceID,
            isTrunkOwner: isTrunkOwner
        )
    }

    // ------------------------------------------------------------------
    // Per-strand passes
    // ------------------------------------------------------------------

    /// The app's `sharedCorridorLaneLayout`, minus delta bookkeeping.
    static func assembleLayout(
        strand: StrandGeometry,
        segmentLayouts: [SegmentLayout?],
        identities: [Int: CorridorLaneSchedule.JourneyIdentity],
        laneSpacingPoints: Double
    ) -> VertexLayout {
        let points = strand.points
        let metersPerUnit = strand.metersPerUnit
        guard points.count >= 2 else {
            return VertexLayout(offsets: [], shared: [], trunk: [])
        }

        // A parallel shape seen for only a few meters is normally an
        // intersection, a terminal bay, or a near-parallel turn — not a
        // shared road. Refusing those tiny runs removes one-vertex
        // side-steps without deleting any authoritative route geometry.
        var layouts = segmentLayouts
        removeShortCorridorRuns(
            points: points,
            layouts: &layouts,
            metersPerUnit: metersPerUnit
        )

        var offsetSums = Array(repeating: 0.0, count: points.count)
        var offsetCounts = Array(repeating: 0, count: points.count)
        var trunkOwnerVotes = Array(repeating: 0, count: points.count)
        var referenceVotes = Array(
            repeating: [Int: Int](),
            count: points.count
        )
        for (index, layout) in layouts.enumerated() {
            guard let layout else { continue }
            offsetSums[index] += layout.offset
            offsetSums[index + 1] += layout.offset
            offsetCounts[index] += 1
            offsetCounts[index + 1] += 1
            referenceVotes[index][layout.referenceID, default: 0] += 1
            referenceVotes[index + 1][layout.referenceID, default: 0] += 1
            if layout.isTrunkOwner {
                trunkOwnerVotes[index] += 1
                trunkOwnerVotes[index + 1] += 1
            }
        }

        var offsets = offsetSums.indices.map { index in
            offsetCounts[index] > 0
                ? offsetSums[index] / Double(offsetCounts[index])
                : 0.0
        }
        var explicitlyStacked = offsetCounts.map { $0 > 0 }
        var trunkOwnerVertices = trunkOwnerVotes.map { $0 > 0 }
        var corridorReferenceIDs = referenceVotes.map { votes -> Int? in
            votes.keys.sorted { firstID, secondID in
                let firstVotes = votes[firstID] ?? 0
                let secondVotes = votes[secondID] ?? 0
                if firstVotes != secondVotes {
                    return firstVotes > secondVotes
                }
                guard let first = identities[firstID],
                      let second = identities[secondID]
                else { return firstID < secondID }
                return CorridorLaneSchedule.laneComesBefore(first, second)
            }.first
        }

        // The first shared section establishes this strand's lane. Hold
        // that lane for the whole contiguous corridor: another route
        // entering or leaving is not allowed to recenter continuing
        // strands.
        stabilizeCorridorRunOffsets(
            points: points,
            layouts: layouts,
            offsets: &offsets,
            metersPerUnit: metersPerUnit
        )

        // Fill only small misses that return to the same physical spine
        // and nearly the same lane.
        bridgeShortCorridorGaps(
            points: points,
            explicitlyStacked: &explicitlyStacked,
            trunkOwnerVertices: &trunkOwnerVertices,
            corridorReferenceIDs: &corridorReferenceIDs,
            offsets: &offsets,
            metersPerUnit: metersPerUnit,
            laneSpacingPoints: laneSpacingPoints
        )

        // Fade the lane back to the route's own shape at the ends of every
        // shared run: branches peel away gradually instead of gaining a
        // diagonal connector where a shared corridor starts or ends.
        let taperDistance = 58.0
        if offsets.count > 1 {
            var i = 0
            while i < offsets.count {
                while i < offsets.count && !explicitlyStacked[i] {
                    i += 1
                }
                guard i < offsets.count else { break }
                let runStart = i
                while i < offsets.count && explicitlyStacked[i] {
                    i += 1
                }
                let runEnd = i - 1

                // Backward taper before runStart
                var backwardAccumulated = 0.0
                let startOffset = offsets[runStart]
                for backIndex in stride(from: runStart - 1, through: 0, by: -1) {
                    if explicitlyStacked[backIndex] { break }
                    backwardAccumulated += points[backIndex]
                        .distance(to: points[backIndex + 1]) * metersPerUnit
                    if backwardAccumulated >= taperDistance { break }
                    let factor = 1.0 - (backwardAccumulated / taperDistance)
                    let candidateOffset = startOffset * factor
                    if abs(candidateOffset) > abs(offsets[backIndex]) {
                        offsets[backIndex] = candidateOffset
                    }
                }

                // Forward taper after runEnd
                var forwardAccumulated = 0.0
                let endOffset = offsets[runEnd]
                for forwardIndex in (runEnd + 1)..<offsets.count {
                    if explicitlyStacked[forwardIndex] { break }
                    forwardAccumulated += points[forwardIndex - 1]
                        .distance(to: points[forwardIndex]) * metersPerUnit
                    if forwardAccumulated >= taperDistance { break }
                    let factor = 1.0 - (forwardAccumulated / taperDistance)
                    let candidateOffset = endOffset * factor
                    if abs(candidateOffset) > abs(offsets[forwardIndex]) {
                        offsets[forwardIndex] = candidateOffset
                    }
                }
            }
        }

        // Hairpin decays — a ribbon holding lanes through a ~180° turn of
        // its own street loops off the road: the lane offset exceeds the
        // turn radius, so the innermost arc inverts. Bring the offset to
        // zero at the reversal vertex and let it regrow on the far side.
        if points.count > 2 {
            let hairpinTaper = 58.0
            for reversal in 1..<(points.count - 1) {
                let u0x = points[reversal].x - points[reversal - 1].x
                let u0y = points[reversal].y - points[reversal - 1].y
                let u1x = points[reversal + 1].x - points[reversal].x
                let u1y = points[reversal + 1].y - points[reversal].y
                let l0 = (u0x * u0x + u0y * u0y).squareRoot()
                let l1 = (u1x * u1x + u1y * u1y).squareRoot()
                guard l0 > 1e-6, l1 > 1e-6 else { continue }
                if (u0x / l0) * (u1x / l1) + (u0y / l0) * (u1y / l1) >= -0.6 {
                    continue  // not a reversal
                }
                offsets[reversal] = 0
                var accumulated = 0.0
                for backIndex in stride(
                    from: reversal - 1,
                    through: 0,
                    by: -1
                ) {
                    accumulated += points[backIndex]
                        .distance(to: points[backIndex + 1]) * metersPerUnit
                    if accumulated >= hairpinTaper { break }
                    offsets[backIndex] *= accumulated / hairpinTaper
                }
                accumulated = 0
                for forwardIndex in (reversal + 1)..<points.count {
                    accumulated += points[forwardIndex - 1]
                        .distance(to: points[forwardIndex]) * metersPerUnit
                    if accumulated >= hairpinTaper { break }
                    offsets[forwardIndex] *= accumulated / hairpinTaper
                }
            }
        }

        return VertexLayout(
            offsets: offsets,
            shared: explicitlyStacked,
            trunk: trunkOwnerVertices
        )
    }

    /// Runs of non-nil segment layouts shorter than 30 m become nil.
    static func removeShortCorridorRuns(
        points: [ProjectedPoint],
        layouts: inout [SegmentLayout?],
        metersPerUnit: Double
    ) {
        let minimumSharedDistance = 30.0
        guard layouts.count == points.count - 1 else { return }
        var runStart = 0

        while runStart < layouts.count {
            while runStart < layouts.count, layouts[runStart] == nil {
                runStart += 1
            }
            guard runStart < layouts.count else { break }
            var runEnd = runStart + 1
            while runEnd < layouts.count, layouts[runEnd] != nil {
                runEnd += 1
            }
            var runDistance = 0.0
            for index in runStart..<runEnd {
                runDistance += points[index]
                    .distance(to: points[index + 1]) * metersPerUnit
            }
            if runDistance < minimumSharedDistance {
                for index in runStart..<runEnd {
                    layouts[index] = nil
                }
            }
            runStart = runEnd
        }
    }

    /// Blend only among still-shared vertices within 72 m, so a shrinking
    /// stack slides onto the street while run edges still hand off to the
    /// centerline taper.
    static func stabilizeCorridorRunOffsets(
        points: [ProjectedPoint],
        layouts: [SegmentLayout?],
        offsets: inout [Double],
        metersPerUnit: Double
    ) {
        guard offsets.count == layouts.count + 1,
              points.count == offsets.count,
              points.count > 1
        else { return }

        func vertexIsShared(_ index: Int) -> Bool {
            (index < layouts.count && layouts[index] != nil)
                || (index > 0 && layouts[index - 1] != nil)
        }

        let transitionDistance = 72.0
        let original = offsets
        for index in original.indices {
            guard vertexIsShared(index) else { continue }
            var weightedSum = original[index]
            var weightTotal = 1.0

            var distance = 0.0
            var back = index
            while back > 0 {
                distance += points[back - 1].distance(to: points[back])
                    * metersPerUnit
                if distance > transitionDistance { break }
                guard vertexIsShared(back - 1) else { break }
                let weight = 1.0 - distance / transitionDistance
                weightedSum += original[back - 1] * weight
                weightTotal += weight
                back -= 1
            }

            distance = 0
            var forward = index
            while forward < original.count - 1 {
                distance += points[forward].distance(to: points[forward + 1])
                    * metersPerUnit
                if distance > transitionDistance { break }
                guard vertexIsShared(forward + 1) else { break }
                let weight = 1.0 - distance / transitionDistance
                weightedSum += original[forward + 1] * weight
                weightTotal += weight
                forward += 1
            }

            offsets[index] = weightedSum / weightTotal
        }
    }

    /// Fill small misses that return to the same spine, the same
    /// reference, and nearly the same lane, over a straight-enough path.
    static func bridgeShortCorridorGaps(
        points: [ProjectedPoint],
        explicitlyStacked: inout [Bool],
        trunkOwnerVertices: inout [Bool],
        corridorReferenceIDs: inout [Int?],
        offsets: inout [Double],
        metersPerUnit: Double,
        laneSpacingPoints: Double
    ) {
        // Matches the corridor-continuation distance used when stabilizing
        // run offsets: a dropout short enough to hold its lane through is
        // also short enough to bridge.
        let maximumGapDistance = 150.0
        let maximumLaneChange = laneSpacingPoints * 1.1
        guard points.count > 2,
              points.count == explicitlyStacked.count,
              points.count == trunkOwnerVertices.count,
              points.count == corridorReferenceIDs.count
        else { return }

        var leftIndex = 0
        while leftIndex < points.count - 1 {
            guard explicitlyStacked[leftIndex] else {
                leftIndex += 1
                continue
            }

            var rightIndex = leftIndex + 1
            var gapDistance = 0.0
            while rightIndex < points.count {
                gapDistance += points[rightIndex - 1]
                    .distance(to: points[rightIndex]) * metersPerUnit
                if explicitlyStacked[rightIndex] { break }
                rightIndex += 1
            }

            guard rightIndex < points.count else { break }
            let advanceTo = rightIndex
            defer { leftIndex = advanceTo }
            // A dropout the strand never leaves runs nearly straight along
            // the shared street; when the path is much longer than the
            // chord between the stacked anchors the strand swung away — a
            // real detour — and holding the lane through it would draw the
            // ribbon off the bus's street.
            let gapChordDistance = points[leftIndex]
                .distance(to: points[rightIndex]) * metersPerUnit
            guard rightIndex > leftIndex + 1,
                  gapDistance <= maximumGapDistance,
                  gapChordDistance >= 0.75 * gapDistance,
                  let leftReferenceID = corridorReferenceIDs[leftIndex],
                  corridorReferenceIDs[rightIndex] == leftReferenceID
            else { continue }

            let leftOffset = offsets[leftIndex]
            let rightOffset = offsets[rightIndex]
            guard leftOffset * rightOffset >= 0,
                  abs(leftOffset - rightOffset) <= maximumLaneChange
            else { continue }

            let bridgesSameTrunkOwner = trunkOwnerVertices[leftIndex]
                && trunkOwnerVertices[rightIndex]
            var distanceFromLeft = 0.0
            for index in (leftIndex + 1)..<rightIndex {
                distanceFromLeft += points[index - 1]
                    .distance(to: points[index]) * metersPerUnit
                let progress = gapDistance > 0
                    ? distanceFromLeft / gapDistance : 0
                offsets[index] = leftOffset
                    + (rightOffset - leftOffset) * progress
                explicitlyStacked[index] = true
                trunkOwnerVertices[index] = bridgesSameTrunkOwner
                corridorReferenceIDs[index] = leftReferenceID
            }
        }
    }
}
