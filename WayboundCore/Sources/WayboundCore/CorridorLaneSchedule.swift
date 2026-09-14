import Foundation

/// Constants for the anchored corridor lane scheduler — mirrored 1:1 from the
/// shipped app's `CorridorLaneScheduling` (WayboundMapView.swift) and the
/// replay harness's `lanesched.py`. One shared lane grid: `laneSpacingPoints`
/// screen points; every meter threshold below is ground meters via the
/// conformal scale (`GeoProjection.metersPerUnit`), the single-scale rule the
/// package pins with tests.
///
/// Kept in a standalone enum (not as statics of the scheduler enum) so nested
/// types can reference them explicitly — Swift nested types do not see outer
/// enum statics.
public enum LaneScheduleConstants {

    /// `RouteMapStyle.laneSpacingPoints` = standardLineWidth + separatorWidth.
    /// Public because it is the scheduler entry point's default argument.
    public static let laneSpacing: Double = 4.2

    /// Presence stretches shorter than this (ground meters) are not joins.
    static let joinMinimum: Double = 30

    /// Presence dropouts up to this hold their lane.
    static let gapBridge: Double = 150

    /// Straight-path gate for holding a lane through one dropout.
    static let gapChordRatio: Double = 0.75

    /// Meters of own geometry read for a join side.
    static let sideLookahead: Double = 45

    /// Meters walked to decide a departure side.
    static let exitLookahead: Double = 120

    /// Meters walked to spot a corridor turn at an exit.
    static let turnWindow: Double = 150

    /// Presence starting this close to run start (meters) births with the
    /// founding bundle instead of joining later.
    static let birthGrace: Double = 40

    /// A departing crowd this small (share of the run) is a stub.
    static let collapseShare: Double = 0.05

    /// Survivors must out-ride the stub crowd this much to translate back.
    static let collapseRatio: Double = 4

    /// Only translate the lattice when parked this far (lanes) off the street.
    static var collapseMinimum: Double { laneSpacing }

    /// Meters off the reference line before a side counts.
    static let sideDeadband: Double = 2

    /// A departure must also diverge faster than ~1.4 degrees: gentle
    /// same-street curvature stays a stayer however far the walk runs.
    static let exitAngle: Double = 0.025

    /// How close opposite groups may approach the spine (lanes).
    static var centreClearance: Double { laneSpacing / 4 }

    /// Offsets closer than this (lanes) to a slot collide.
    static var slotClearance: Double { 0.6 * laneSpacing }

    /// Segments a stayer rides past the bound.
    static let stableHorizon = 24

    /// Tail tolerance for riding with a route that ends here.
    static let tailSlack = 6

    /// The stretch-length a terminal stretch must exceed.
    static let terminalLookback = 8

    /// Own-index slack that recognises a route's last segments.
    static let terminalSlack = 3
}

/// The subway-style anchored lane scheduler: one pass per connected group of
/// shared runs ("corridor"). A strand's lane is chosen once, when it enters
/// the corridor, and is held while it continues; joiners enter at the outer
/// edge of their approach side; leavers keep their lane and peel away; freed
/// slots are remembered so a dropout-and-return reclaims its own lane;
/// corridor-birth order is exit-aware (the first strand to peel off on a side
/// sits outermost there, which minimises fork crossings); opposite travel
/// directions stay on opposite sides of the centreline.
///
/// This is the WayboundCore port of the shipped app's scheduler
/// (`WayboundMapView.buildCorridorLaneSchedule` / `sweepCorridorRun`) and of
/// the replay harness's executable spec (`tools/replay/lanesched.py`). It
/// consumes nothing but journey polylines and identity — the same input the
/// device has when it exports `schedule` — so the golden tests can reproduce
/// the device's schedule from the exports alone.
///
/// The schedule stores, per strand segment, the lane offset expressed against
/// the sweeping spine's travel direction plus the sticky reference journey.
/// Consumers convert into their own frame with the direction dot their held
/// direction chain supplies (the renderer's reversal hold).
///
/// Intentional divergences from the app source (documented for parity
/// reviews, behavior-preserving on the fixtures):
///  - Union members are iterated in sorted journey order and corridor groups
///    are ordered deterministically, where the app inherits hash-seed order
///    from `Set`/`Dictionary` iteration. Group membership is identical; only
///    the union-find root (a tie-break key) could differ in the app run to
///    run. Same goal, stable.
///  - Distances and laterals both convert through
///    `GeoProjection.metersPerUnit` (the conformal one-scale rule). The app
///    calibrates two runtime scales that agree with it to within a fraction
///    of a percent on the meter-based MapKit world.
public enum CorridorLaneSchedule {

    /// One (journey, flagship polyline) strand.
    public struct StrandKey: Hashable, Sendable {
        public let journeyID: Int
        public let polylineIndex: Int

        public init(journeyID: Int, polylineIndex: Int) {
            self.journeyID = journeyID
            self.polylineIndex = polylineIndex
        }
    }

    /// The scheduled lane for one strand segment: `offset` lanes against the
    /// spine's `(directionX, directionY)` travel at that segment, with the
    /// sticky reference journey the corridor anchored to.
    public struct Sample: Equatable, Sendable {
        public let offset: Double
        public let directionX: Double
        public let directionY: Double
        public let referenceID: Int

        init(
            offset: Double,
            directionX: Double,
            directionY: Double,
            referenceID: Int
        ) {
            self.offset = offset
            self.directionX = directionX
            self.directionY = directionY
            self.referenceID = referenceID
        }
    }

    // ------------------------------------------------------------------
    // Input types
    // ------------------------------------------------------------------

    /// Public route identity: what lateral order is defined by (not live
    /// utility ranking — the sheet can reorder by usefulness without making
    /// map colors swap).
    struct JourneyIdentity {
        let id: Int
        let routeNumber: String
        let agency: String
        let directionID: Int?
        let stackOrder: Int

        init(journey: LaneDiagnosticsDocument.Journey) {
            id = journey.id
            routeNumber = journey.routeNumber
            agency = journey.agency
            // The export writes -1 for a nil direction; read it back as nil
            // so both worlds sort missing directions last.
            var direction = journey.directionID
            if let value = direction, value < 0 { direction = nil }
            directionID = direction
            stackOrder = journey.stackOrder
        }

        /// Both directions of one numbered route are one visual strand.
        var publicRouteKey: String {
            "\(agency)|\(routeNumber)"
        }
    }

    /// `corridorLaneComesBefore`: route number (case-insensitive, numeric —
    /// "5" before "12X"), agency, direction (nil last), stack order, id.
    static func laneComesBefore(
        _ first: JourneyIdentity,
        _ second: JourneyIdentity
    ) -> Bool {
        let routeComparison = first.routeNumber.compare(
            second.routeNumber,
            options: [.caseInsensitive, .numeric]
        )
        if routeComparison != .orderedSame {
            return routeComparison == .orderedAscending
        }
        let agencyComparison = first.agency.compare(
            second.agency,
            options: [.caseInsensitive, .diacriticInsensitive]
        )
        if agencyComparison != .orderedSame {
            return agencyComparison == .orderedAscending
        }
        let firstDirection = first.directionID ?? Int.max
        let secondDirection = second.directionID ?? Int.max
        if firstDirection != secondDirection {
            return firstDirection < secondDirection
        }
        if first.stackOrder != second.stackOrder {
            return first.stackOrder < second.stackOrder
        }
        return first.id < second.id
    }

    /// One strand's geometry: the (already densified) polyline projected,
    /// its optional segments, the cumulative ground-meter arc, and the
    /// conformal meter scale.
    struct Strand {
        let key: StrandKey
        let points: [ProjectedPoint]
        let segments: [CorridorMembership.CorridorSegment?]
        let arc: [Double]
        let metersPerUnit: Double
    }

    /// A maximal sharing stretch on one strand.
    struct Run {
        let strand: StrandKey
        let start: Int
        let end: Int
    }

    // ------------------------------------------------------------------
    // Entry point
    // ------------------------------------------------------------------

    /// Schedule lanes for every shared segment of every strand. Runs the
    /// corridor membership scan (same gates the layout pass uses), builds
    /// maximal runs, unions runs that share members into corridors, then
    /// sweeps each corridor largest-first.
    public static func schedule(
        journeys: [LaneDiagnosticsDocument.Journey],
        laneSpacingPoints: Double = LaneScheduleConstants.laneSpacing
    ) -> [StrandKey: [Int: Sample]] {
        guard !journeys.isEmpty else { return [:] }

        var identities: [Int: JourneyIdentity] = [:]
        for journey in journeys {
            identities[journey.id] = JourneyIdentity(journey: journey)
        }

        // The membership scan is the same pass the layout uses; its rows
        // say, per strand segment, which other journeys run parallel there
        // and where on the member's own strand the match sits.
        let scanResult = CorridorMembership.scan(
            journeys: journeys,
            laneSpacingPoints: laneSpacingPoints
        )
        var scanRows: [StrandKey: [[Int: CorridorMembership.CandidateLocation]]] = [:]
        for (key, rows) in scanResult.rows {
            scanRows[StrandKey(
                journeyID: key.journeyID,
                polylineIndex: key.polylineIndex
            )] = rows
        }

        var strands: [StrandKey: Strand] = [:]
        for journey in journeys {
            for (polylineIndex, polyline) in journey.polylines.enumerated() {
                guard polyline.count >= 2 else { continue }
                // The scan rows are indexed per densified segment; the
                // sweep's arc/points must walk the same densified polyline
                // (device exports arrive pre-densified, synthetic strands
                // do not).
                let points = CorridorMembership.densify(polyline)
                    .map { $0.projected }
                let metersPerUnit = GeoProjection.metersPerUnit(
                    atLatitude: polyline[0].latitude
                )
                var segments: [CorridorMembership.CorridorSegment?] = []
                segments.reserveCapacity(points.count - 1)
                var arc: [Double] = [0]
                for index in 0..<(points.count - 1) {
                    segments.append(CorridorMembership.CorridorSegment(
                        start: points[index],
                        end: points[index + 1]
                    ))
                    arc.append(
                        arc[index]
                            + points[index]
                                .distance(to: points[index + 1])
                                * metersPerUnit
                    )
                }
                let key = StrandKey(
                    journeyID: journey.id,
                    polylineIndex: polylineIndex
                )
                strands[key] = Strand(
                    key: key,
                    points: points,
                    segments: segments,
                    arc: arc,
                    metersPerUnit: metersPerUnit
                )
            }
        }

        var schedule = buildSchedule(
            strands: strands,
            scanRows: scanRows,
            identities: identities
        )
        postFillSchedule(strands, scanRows, &schedule)
        pruneIslandScheduleEntries(&schedule)
        return schedule
    }

    // ------------------------------------------------------------------
    // Runs, corridors, sweep order
    // ------------------------------------------------------------------

    static func buildSchedule(
        strands: [StrandKey: Strand],
        scanRows: [StrandKey: [[Int: CorridorMembership.CandidateLocation]]],
        identities: [Int: JourneyIdentity]
    ) -> [StrandKey: [Int: Sample]] {
        guard !strands.isEmpty else { return [:] }

        // Entries recorded so far, keyed per strand segment. Sweeps adopt
        // from it (chained sweep starts, prior-ribbon continuation) and
        // record into it first-write-wins.
        var schedule: [StrandKey: [Int: Sample]] = [:]

        // Runs: maximal sharing stretches per strand, >= 30 m.
        var runs: [Run] = []
        for (key, strand) in strands.sorted(by: {
            if $0.key.journeyID != $1.key.journeyID {
                return $0.key.journeyID < $1.key.journeyID
            }
            return $0.key.polylineIndex < $1.key.polylineIndex
        }) {
            let rows = scanRows[key] ?? []
            var index = 0
            while index < rows.count {
                if rows[index].isEmpty {
                    index += 1
                    continue
                }
                var end = index + 1
                while end < rows.count && !rows[end].isEmpty {
                    end += 1
                }
                if strand.arc[end] - strand.arc[index]
                    >= LaneScheduleConstants.joinMinimum {
                    runs.append(Run(strand: key, start: index, end: end))
                }
                index = end
            }
        }

        // Corridor groups: union runs whose journeys share members.
        var parent = Array(runs.indices)
        func find(_ x: Int) -> Int {
            var root = x
            while parent[root] != root {
                parent[root] = parent[parent[root]]
                root = parent[root]
            }
            return root
        }
        var runsByJourney: [Int: [Int]] = [:]
        for (index, run) in runs.enumerated() {
            runsByJourney[run.strand.journeyID, default: []].append(index)
        }
        for (index, run) in runs.enumerated() {
            let key = run.strand
            let rows = scanRows[key] ?? []
            var members = Set<Int>()
            for si in run.start..<run.end {
                members.formUnion(rows[si].keys)
            }
            members.insert(key.journeyID)
            // Sorted journey order: deterministic union roots (the app
            // inherits hash-seed order here; membership is identical).
            for memberID in members.sorted() {
                for otherIndex in runsByJourney[memberID] ?? [] {
                    let rootA = find(index)
                    let rootB = find(otherIndex)
                    if rootA != rootB {
                        parent[rootA] = rootB
                    }
                }
            }
        }
        var groups: [Int: [Int]] = [:]
        for index in runs.indices {
            groups[find(index), default: []].append(index)
        }

        // Longest corridors first (most runs first, then by group root).
        for (_, runIndices) in groups.sorted(by: {
            if $0.value.count != $1.value.count {
                return $0.value.count > $1.value.count
            }
            return $0.key < $1.key
        }) {
            // Birth priority: the sweep whose spine follows the BUNDLE
            // longest (median member presence) runs first, so ladders are
            // laid by a spine with truthful presence for its members. Raw
            // run length is the wrong key: a spine that drags one express
            // partner down a freeway (long run, stub presence for everyone
            // else — the transit-center stub) would otherwise birth a
            // scrambled ladder that every later sweep adopts.
            let ordered = runIndices.sorted(by: {
                let firstCoverage = runMedianCoverage(
                    runs[$0], scanRows: scanRows
                )
                let secondCoverage = runMedianCoverage(
                    runs[$1], scanRows: scanRows
                )
                if firstCoverage != secondCoverage {
                    return firstCoverage > secondCoverage
                }
                let firstLength = runLength(runs[$0], strands: strands)
                let secondLength = runLength(runs[$1], strands: strands)
                if firstLength != secondLength {
                    return firstLength > secondLength
                }
                return $0 < $1
            })
            var memory: [String: Double] = [:]
            for runIndex in ordered {
                let outcome = Sweep(
                    run: runs[runIndex],
                    strands: strands,
                    scanRows: scanRows,
                    identities: identities,
                    schedule: schedule,
                    memory: memory
                ).execute()
                schedule = outcome.schedule
                memory = outcome.memory
            }
        }

        return schedule
    }

    static func runLength(
        _ run: Run,
        strands: [StrandKey: Strand]
    ) -> Double {
        guard let strand = strands[run.strand] else { return 0 }
        return strand.arc[run.end] - strand.arc[run.start]
    }

    /// Median member-presence length (segments) over a run: how far this
    /// run's spine travels with the typical member.
    static func runMedianCoverage(
        _ run: Run,
        scanRows: [StrandKey: [[Int: CorridorMembership.CandidateLocation]]]
    ) -> Int {
        let rows = scanRows[run.strand] ?? []
        var members = Set<Int>()
        for si in run.start..<run.end where si < rows.count {
            members.formUnion(rows[si].keys)
        }
        var lengths: [Int] = []
        for cid in members where cid != run.strand.journeyID {
            var count = 0
            for si in run.start..<run.end where si < rows.count {
                if rows[si][cid] != nil { count += 1 }
            }
            if count > 0 { lengths.append(count) }
        }
        lengths.sort()
        return lengths.isEmpty ? 0 : lengths[lengths.count / 2]
    }

    // ------------------------------------------------------------------
    // Post passes
    // ------------------------------------------------------------------

    /// One-segment lattice islands: where several corridors' sweeps overlap
    /// geographically (streets meeting at a corner, a sliver run bridged
    /// into two sweeps), the first sweep to record an own segment can plant
    /// the OTHER corridor's lattice value there — a lone entry jumping a
    /// lane and a half from both neighbours inside an otherwise constant
    /// run. Drop it and let the bridge fill the slot continuously.
    static func pruneIslandScheduleEntries(
        _ schedule: inout [StrandKey: [Int: Sample]]
    ) {
        let laneSpacing = LaneScheduleConstants.laneSpacing
        for (strandKey, entries) in schedule {
            var removals: [Int] = []
            for index in entries.keys {
                guard let before = entries[index - 1],
                      let after = entries[index + 1],
                      let island = entries[index]
                else { continue }
                let a = before.offset, b = island.offset, c = after.offset
                if abs(b - a) > 1.5 * laneSpacing
                    && abs(b - c) > 1.5 * laneSpacing
                    && abs(a - c) <= laneSpacing {
                    removals.append(index)
                }
            }
            for index in removals {
                schedule[strandKey]?.removeValue(forKey: index)
            }
        }
    }

    /// Presence stretches of one member over a sweep: dropouts up to
    /// `gapBridge` merge, stretches under `joinMinimum` drop.
    static func debouncedPresence(
        _ rows: [[Int: CorridorMembership.CandidateLocation]],
        from s0: Int,
        to s1: Int,
        member cid: Int,
        arc: [Double]
    ) -> [(Int, Int)] {
        var stretches: [(Int, Int)] = []
        var index = s0
        while index < s1 && index < rows.count {
            if rows[index][cid] != nil {
                var end = index + 1
                while end < s1 && end < rows.count
                        && rows[end][cid] != nil {
                    end += 1
                }
                stretches.append((index, end))
                index = end
            } else {
                index += 1
            }
        }
        guard !stretches.isEmpty else { return [] }
        var bridged = [stretches[0]]
        for stretch in stretches.dropFirst() {
            let previousEnd = bridged[bridged.count - 1].1
            if arc[stretch.0] - arc[previousEnd]
                <= LaneScheduleConstants.gapBridge {
                bridged[bridged.count - 1].1 =
                    max(previousEnd, stretch.1)
            } else {
                bridged.append(stretch)
            }
        }
        return bridged.filter {
            arc[$0.1] - arc[$0.0] >= LaneScheduleConstants.joinMinimum
        }
    }

    /// Hold a lane through short schedule dropouts inside a strand's shared
    /// run (same distance and straightness gates as the gap bridge
    /// downstream), but only when both anchors agree.
    static func postFillSchedule(
        _ strands: [StrandKey: Strand],
        _ scanRows: [StrandKey: [[Int: CorridorMembership.CandidateLocation]]],
        _ schedule: inout [StrandKey: [Int: Sample]]
    ) {
        for (key, strand) in strands.sorted(by: {
            if $0.key.journeyID != $1.key.journeyID {
                return $0.key.journeyID < $1.key.journeyID
            }
            return $0.key.polylineIndex < $1.key.polylineIndex
        }) {
            let rows = scanRows[key] ?? []
            var index = 0
            while index < rows.count {
                if rows[index].isEmpty {
                    index += 1
                    continue
                }
                var end = index + 1
                while end < rows.count && !rows[end].isEmpty {
                    end += 1
                }
                let entries = schedule[key] ?? [:]
                let assigned = (index..<end).filter { entries[$0] != nil }
                if let first = assigned.first, let last = assigned.last,
                   first < last {
                    for slot in (first + 1)..<last {
                        guard entries[slot] == nil else { continue }
                        let left = assigned.filter { $0 < slot }.max() ?? first
                        let right = assigned.filter { $0 > slot }.min() ?? last
                        guard let before = entries[left],
                              let after = entries[right]
                        else { continue }
                        guard abs(before.offset - after.offset) < 0.0005,
                              before.referenceID == after.referenceID
                        else { continue }
                        let path = strand.arc[slot] - strand.arc[left]
                        let chord = strand.points[left]
                            .distance(to: strand.points[slot])
                                * strand.metersPerUnit
                        if path <= LaneScheduleConstants.gapBridge,
                           chord >= LaneScheduleConstants.gapChordRatio
                                * max(path, 1e-6) {
                            schedule[key, default: [:]][slot] = before
                        }
                    }
                }
                index = end
            }
        }
    }

    // ------------------------------------------------------------------
    // The sweep
    // ------------------------------------------------------------------

    /// One corridor sweep: birth or extend a lane lattice along one run's
    /// spine, recording entries for every present member at its own matched
    /// location. `schedule` and `memory` thread across the sweeps of a
    /// corridor group.
    struct Sweep {
        let run: Run
        let strands: [StrandKey: Strand]
        let scanRows: [StrandKey: [[Int: CorridorMembership.CandidateLocation]]]
        let identities: [Int: JourneyIdentity]
        var schedule: [StrandKey: [Int: Sample]]
        var memory: [String: Double]

        let key: StrandKey
        let strand: Strand
        let rows: [[Int: CorridorMembership.CandidateLocation]]
        let s0: Int
        let s1: Int
        let snake: Bool
        var presence: [Int: [(Int, Int)]]
        var slots: [String: Double]
        var slotGroups: [String: Int]
        var stickyReferenceID: Int?

        init(
            run: Run,
            strands: [StrandKey: Strand],
            scanRows: [StrandKey: [[Int: CorridorMembership.CandidateLocation]]],
            identities: [Int: JourneyIdentity],
            schedule: [StrandKey: [Int: Sample]],
            memory: [String: Double]
        ) {
            self.run = run
            self.strands = strands
            self.scanRows = scanRows
            self.identities = identities
            self.schedule = schedule
            self.memory = memory

            key = run.strand
            strand = strands[key] ?? Strand(
                key: key,
                points: [],
                segments: [],
                arc: [0],
                metersPerUnit: 1
            )
            rows = scanRows[key] ?? []
            s0 = run.start
            s1 = run.end

            // A winding street: the spine's direction rotates across the
            // run (circulators, TC loops). "Left" and "right" then flip at
            // every bend, so per-probe exit sides cannot share one ladder
            // — the least-crossing order is a staircase by exit point.
            var sumX = 0.0
            var sumY = 0.0
            var dirCount = 0
            for si in s0..<min(s1, strand.segments.count) {
                if let segment = strand.segments[si] {
                    sumX += segment.unitX
                    sumY += segment.unitY
                    dirCount += 1
                }
            }
            snake = dirCount > 0
                && (sumX * sumX + sumY * sumY).squareRoot()
                    / Double(dirCount) < 0.7

            presence = [key.journeyID: [(s0, s1)]]
            var memberIDs = Set<Int>()
            for si in s0..<s1 {
                guard si < rows.count else { break }
                memberIDs.formUnion(rows[si].keys)
            }
            for cid in memberIDs.sorted() {
                let stretches = CorridorLaneSchedule.debouncedPresence(
                    rows, from: s0, to: s1, member: cid, arc: strand.arc
                )
                if !stretches.isEmpty {
                    presence[cid] = stretches
                }
            }

            slots = [:]
            slotGroups = [:]
            stickyReferenceID = nil
        }

        struct Outcome {
            let schedule: [StrandKey: [Int: Sample]]
            let memory: [String: Double]
        }

        func execute() -> Outcome {
            var mutableSelf = self
            mutableSelf.mainLoop()
            return Outcome(
                schedule: mutableSelf.schedule,
                memory: mutableSelf.memory
            )
        }

        // ---- lookups --------------------------------------------------

        func publicRouteKey(for journeyID: Int) -> String {
            guard let identity = identities[journeyID] else {
                return "id:\(journeyID)"
            }
            return identity.publicRouteKey
        }

        func segmentDirection(at si: Int) -> (Double, Double) {
            if si >= 0 && si < strand.segments.count,
               let segment = strand.segments[si] {
                return (segment.unitX, segment.unitY)
            }
            let fallbackIndex = max(s0, si - 1)
            if fallbackIndex >= 0 && fallbackIndex < strand.segments.count,
               let fallback = strand.segments[fallbackIndex] {
                return (fallback.unitX, fallback.unitY)
            }
            return (x: 1, y: 0)
        }

        func matched(
            _ cid: Int,
            _ si: Int
        ) -> CorridorMembership.CandidateLocation? {
            guard si >= 0 && si < rows.count else { return nil }
            return rows[si][cid]
        }

        func ownLocation(
            _ cid: Int,
            _ si: Int
        ) -> CorridorMembership.CandidateLocation? {
            matched(cid, si)
        }

        func nearestOwnLocation(
            _ cid: Int,
            _ si: Int
        ) -> CorridorMembership.CandidateLocation? {
            var best: (distance: Int, probe: Int)?
            for probe in max(s0, si - 24)..<min(s1, si + 24) {
                guard matched(cid, probe) != nil else { continue }
                let distance = abs(probe - si)
                if best == nil || distance < best!.distance {
                    best = (distance, probe)
                }
            }
            guard let best else { return nil }
            return ownLocation(cid, best.probe)
        }

        func memberStrand(
            _ location: CorridorMembership.CandidateLocation,
            _ cid: Int
        ) -> Strand? {
            strands[StrandKey(
                journeyID: cid,
                polylineIndex: location.polylineIndex
            )]
        }

        func sideSign(
            of point: ProjectedPoint,
            from origin: ProjectedPoint,
            direction: (Double, Double)
        ) -> Int? {
            let leftX = -direction.1
            let leftY = direction.0
            let side = (point.x - origin.x) * leftX
                + (point.y - origin.y) * leftY
            if abs(side) * strand.metersPerUnit < 2 {
                return nil
            }
            return side > 0 ? 1 : -1
        }

        func joinSide(_ cid: Int, _ si: Int) -> Int? {
            guard let location = ownLocation(cid, si),
                  location.segmentIndex > 0,
                  let member = memberStrand(location, cid)
            else { return nil }
            var back = location.segmentIndex
            var travelled = 0.0
            while back > 0 && travelled
                < LaneScheduleConstants.sideLookahead {
                travelled += member.points[back - 1]
                    .distance(to: member.points[back])
                    * strand.metersPerUnit
                back -= 1
            }
            guard si > 0 || strand.segments[si] != nil else { return nil }
            let segment = strand.segments[si] ?? strand.segments[si - 1]
            guard let segment else { return nil }
            return sideSign(
                of: member.points[back],
                from: segment.start,
                direction: segmentDirection(at: si)
            )
        }

        func exitSide(_ cid: Int, _ outSi: Int) -> Int? {
            var probe: Int?
            var match: CorridorMembership.CandidateLocation?
            var index = min(outSi, s1 - 1)
            while index >= s0 {
                if let candidate = matched(cid, index) {
                    match = candidate
                    probe = index
                    break
                }
                index -= 1
            }
            guard let match, let probe else { return nil }
            guard let member = memberStrand(match, cid),
                  match.segmentIndex < member.points.count - 1
            else { return nil }
            guard let segment = strand.segments[probe] else { return nil }
            // Walk the strand's own polyline across the whole lookahead
            // window and read the NET lateral displacement at the end (see
            // departureSide for why net, not first crossing).
            let direction = segmentDirection(at: probe)
            let leftX = -direction.1
            let leftY = direction.0
            let originX = segment.start.x
            let originY = segment.start.y
            var forward = match.segmentIndex
            var travelled = 0.0
            var netSide = 0.0
            var netDistance = 0.0
            while forward < member.points.count - 1
                    && travelled < LaneScheduleConstants.exitLookahead {
                travelled += member.points[forward]
                    .distance(to: member.points[forward + 1])
                    * strand.metersPerUnit
                forward += 1
                netSide = (member.points[forward].x - originX) * leftX
                    + (member.points[forward].y - originY) * leftY
                netDistance = travelled
            }
            let threshold = max(
                LaneScheduleConstants.sideDeadband,
                LaneScheduleConstants.exitAngle * netDistance
            )
            if abs(netSide) * strand.metersPerUnit >= threshold {
                return netSide > 0 ? 1 : -1
            }
            return nil
        }

        /// Average travel direction at si of the given members' matched
        /// segments, aligned to the spine's frame. Robust to any single
        /// polyline turning: the street is what the group does.
        func consensusDirection(
            _ si: Int,
            _ members: [Int]
        ) -> (Double, Double) {
            var x = 0.0
            var y = 0.0
            let spine = segmentDirection(at: si)
            for cid in members {
                // Read the member's direction at its nearest matched probe
                // within a few spine rows: knife-edge scan rows (a member
                // matched on one row but not the next) must not flip the
                // consensus the sweep orders lanes by.
                var picked: (unitX: Double, unitY: Double)?
                for delta in [0, 1, -1, 2, -2, 3, -3] {
                    let probe = si + delta
                    guard probe >= s0, probe < rows.count,
                          let location = ownLocation(cid, probe),
                          let member = memberStrand(location, cid),
                          location.segmentIndex < member.segments.count,
                          let segment = member.segments[
                              location.segmentIndex
                          ]
                    else { continue }
                    picked = (segment.unitX, segment.unitY)
                    break
                }
                guard let picked else { continue }
                let aligned = picked.unitX * spine.0
                        + picked.unitY * spine.1 >= 0 ? 1.0 : -1.0
                x += aligned * picked.unitX
                y += aligned * picked.unitY
            }
            // The spine's own vote anchors the consensus to the street the
            // sweep is actually ordering.
            x += spine.0
            y += spine.1
            let length = (x * x + y * y).squareRoot()
            guard length >= 1e-6 else { return spine }
            return (x / length, y / length)
        }

        /// Side on which cid leaves the corridor at outSi, measured against
        /// the members that REMAIN at that point — the street continues
        /// with them, so the consensus of the remainder, not any one
        /// polyline, is the reference. Origin sits on the strand's own
        /// point at the probe (immune to the few-metre baseline offsets
        /// between matched polylines), and the walk reads the NET lateral
        /// displacement across the whole window: a gentle fork never clears
        /// the deadband; a bay excursion that returns nets to zero.
        func departureSide(_ cid: Int, _ outSi: Int) -> Int? {
            var probe = max(s0, min(outSi, s1) - 1)
            var match: CorridorMembership.CandidateLocation?
            while probe >= s0 {
                if let candidate = matched(cid, probe) {
                    match = candidate
                    break
                }
                probe -= 1
            }
            guard let match, let member = memberStrand(match, cid)
            else { return nil }
            let originIndex = match.segmentIndex
            guard originIndex < member.points.count - 1 else {
                return nil
            }
            let remaining = presentJourneys(probe).filter { other in
                other != cid
                    && (presence[other] ?? []).contains {
                        $0.0 <= probe && probe < $0.1
                    }
            }
            let direction = remaining.isEmpty
                ? segmentDirection(at: probe)
                : consensusDirection(probe, remaining)
            let leftX = -direction.1
            let leftY = direction.0
            let origin = member.points[originIndex]
            // A member whose presence runs to the run end splits at the
            // corridor's own end (the street turns away from it); give the
            // read a longer window to see that divergence.
            let lookahead = LaneScheduleConstants.exitLookahead
                * (min(outSi, s1) >= s1 ? 2.5 : 1.0)
            var forward = originIndex
            var travelled = 0.0
            var netSide = 0.0
            var netDistance = 0.0
            while forward < member.points.count - 1
                    && travelled < lookahead {
                travelled += member.points[forward]
                    .distance(to: member.points[forward + 1])
                    * strand.metersPerUnit
                forward += 1
                netSide = (member.points[forward].x - origin.x) * leftX
                    + (member.points[forward].y - origin.y) * leftY
                netDistance = travelled
            }
            // A read must clear the angle threshold by half again: a
            // polyline running a few metres off its neighbours' (drawing
            // parallax) otherwise flips the side on noise.
            let threshold = max(
                LaneScheduleConstants.sideDeadband,
                1.5 * LaneScheduleConstants.exitAngle * netDistance
            )
            if abs(netSide) * strand.metersPerUnit >= threshold {
                return netSide > 0 ? 1 : -1
            }
            return nil
        }

        /// Ladder side for a straight-continuer where the corridor itself
        /// turns: the spine bends off the pre-turn line while this strand
        /// stays on it (it goes straight through the junction the corridor
        /// turns at). Its ribbon belongs on the OUTSIDE of the corridor's
        /// turn — the side opposite the spine's departure — or the turning
        /// bundle sweeps its arc across the continuer's straight ribbon.
        func turnSide(_ cid: Int, _ outSi: Int) -> Int? {
            var probe = max(s0, min(outSi, s1) - 1)
            var match: CorridorMembership.CandidateLocation?
            while probe >= s0 {
                if let candidate = matched(cid, probe) {
                    match = candidate
                    break
                }
                probe -= 1
            }
            guard let match, let member = memberStrand(match, cid)
            else { return nil }
            let originIndex = match.segmentIndex
            guard originIndex < member.points.count - 1 else {
                return nil
            }
            let direction = segmentDirection(at: probe)
            let leftX = -direction.1
            let leftY = direction.0

            func netDisplacement(
                _ points: [ProjectedPoint],
                from start: Int
            ) -> Double {
                // Net displacement along the pre-turn normal over the
                // window, from this polyline's own start point (immune to
                // the few-metre baseline offsets between matched
                // polylines). Conformal scale: one conversion for both the
                // travelled sum and the lateral.
                let origin = points[start]
                var forward = start
                var travelled = 0.0
                var lateral = 0.0
                while forward < points.count - 1
                        && travelled < LaneScheduleConstants.turnWindow {
                    travelled += points[forward]
                        .distance(to: points[forward + 1])
                        * strand.metersPerUnit
                    forward += 1
                    lateral = (points[forward].x - origin.x) * leftX
                        + (points[forward].y - origin.y) * leftY
                }
                return lateral * strand.metersPerUnit
            }

            let memberSide = netDisplacement(
                member.points,
                from: originIndex
            )
            let spineSide = netDisplacement(strand.points, from: probe)
            let gate = max(
                LaneScheduleConstants.sideDeadband,
                1.5 * LaneScheduleConstants.exitAngle
                    * LaneScheduleConstants.turnWindow
            )
            guard abs(memberSide) < gate,
                  abs(spineSide) > 2 * gate else { return nil }
            return spineSide > 0 ? -1 : 1
        }

        func groupSign(_ cid: Int, _ si: Int) -> Int {
            guard let location = ownLocation(cid, si),
                  let member = memberStrand(location, cid),
                  let segment = member.segments[
                      min(location.segmentIndex,
                          member.segments.count - 1)
                  ]
            else { return 1 }
            let direction = segmentDirection(at: si)
            let dot = segment.unitX * direction.0
                + segment.unitY * direction.1
            return dot >= 0 ? 1 : -1
        }

        // ---- sweep state helpers -------------------------------------

        func presentJourneys(_ si: Int) -> [Int] {
            presence.keys
                .filter { cid in
                    (presence[cid] ?? []).contains {
                        $0.0 <= si && si < $0.1
                    }
                }
                .sorted {
                    guard let first = identities[$0],
                          let second = identities[$1]
                    else { return $0 < $1 }
                    return CorridorLaneSchedule.laneComesBefore(first, second)
                }
        }

        func presentKeys(_ si: Int) -> [String] {
            var seen = Set<String>()
            var keys: [String] = []
            for cid in presentJourneys(si) {
                let slotKey = publicRouteKey(for: cid)
                if seen.insert(slotKey).inserted {
                    keys.append(slotKey)
                }
            }
            return keys
        }

        func occupied() -> [Double] {
            Array(slots.values)
        }

        func freeSlot(_ candidate: Double, step: Double) -> Double {
            var slot = candidate
            while occupied().contains(where: { taken in
                abs(slot - taken)
                    < LaneScheduleConstants.slotClearance
            }) {
                slot += step
            }
            return slot
        }

        func crossesCentre(_ candidate: Double, gsign: Int) -> Bool {
            guard slotGroups.values.contains(-gsign) else { return false }
            return candidate * Double(gsign)
                < LaneScheduleConstants.centreClearance
        }

        func groupOffsets(_ gsign: Int) -> [Double] {
            slots.filter { slotGroups[$0.key] == gsign }.map(\.value)
        }

        func outermost(_ offsets: [Double], outward: Int) -> Double {
            outward > 0 ? offsets.max() ?? 0 : offsets.min() ?? 0
        }

        func innermost(_ offsets: [Double], outward: Int) -> Double {
            outward > 0 ? offsets.min() ?? 0 : offsets.max() ?? 0
        }

        /// True when cid stays on this spine well past si — either it rides
        /// on `stableHorizon`+ segments, or this is its terminal stretch
        /// (the route ending here, not peeling onto another street).
        /// Stayers belong beside the members they travel with; leavers sit
        /// outside however wide the momentary bundle is.
        func travelsFar(_ cid: Int, _ si: Int) -> Bool {
            let stretches = presence[cid] ?? []
            for (index, stretch) in stretches.enumerated()
            where stretch.0 <= si && si < stretch.1 {
                if stretch.1 - si
                    > LaneScheduleConstants.stableHorizon {
                    return true
                }
                if index == stretches.count - 1,
                   stretch.1 - si
                    > LaneScheduleConstants.terminalLookback {
                    guard let location = ownLocation(
                        cid,
                        stretch.1 - 1
                    ) ?? nearestOwnLocation(cid, stretch.1 - 1),
                        let member = memberStrand(location, cid)
                    else { return false }
                    return location.segmentIndex
                        >= member.segments.count
                            - LaneScheduleConstants.terminalSlack
                }
                return false
            }
            return false
        }

        /// (centre, width, count) of the lane band the members that
        /// actually travel with cid justify: those present (or joining
        /// within the horizon) whose presence runs well past si. Strands
        /// about to peel do not count — however extreme their slots, the
        /// bundle collapses the moment they leave. The centre is the stable
        /// companions' placed median (the band is relative to the bundle,
        /// not the spine zero); nil when no stable companion is placed.
        func stableBound(
            _ cid: Int,
            _ si: Int
        ) -> (centre: Double?, width: Double, count: Int) {
            var count = 1
            var comp: [Double] = []
            let stretches = presence[cid] ?? []
            let bCid = stretches.first {
                $0.0 <= si && si < $0.1
            }?.1 ?? si + LaneScheduleConstants.stableHorizon + 1
            var terminal = false
            if let location = ownLocation(cid, bCid - 1)
                ?? nearestOwnLocation(cid, bCid - 1),
                let member = memberStrand(location, cid) {
                terminal = location.segmentIndex
                    >= member.segments.count
                    - LaneScheduleConstants.terminalSlack
            }
            let horizon = si + LaneScheduleConstants.stableHorizon
            for other in presence.keys where other != cid {
                var rides = false
                for (a, b) in presence[other] ?? [] {
                    if a <= horizon
                        && (b > horizon
                            || (terminal
                                && b >= bCid
                                    - LaneScheduleConstants.tailSlack)) {
                        rides = true
                        break
                    }
                }
                if !rides { continue }
                count += 1
                if let slot = slots[publicRouteKey(for: other)] {
                    comp.append(slot)
                }
            }
            let width = LaneScheduleConstants.laneSpacing / 2
                * Double(count)
            guard !comp.isEmpty else { return (nil, width, count) }
            comp.sort()
            let mid = comp.count / 2
            let centre = comp.count % 2 == 1
                ? comp[mid]
                : (comp[mid - 1] + comp[mid]) / 2
            return (centre, width, count)
        }

        /// True when the member owning this public key stays on the spine
        /// past si (used to collect a stayer's companions).
        func staysKey(_ slotKey: String, _ si: Int) -> Bool {
            for other in presence.keys {
                if publicRouteKey(for: other) == slotKey,
                   travelsFar(other, si) {
                    return true
                }
            }
            return false
        }

        func numericRank(_ present: [Int], _ cid: Int) -> Int {
            var rank = 0
            for other in present where other != cid {
                guard slots[publicRouteKey(for: other)] == nil
                else { continue }
                guard let first = identities[other],
                      let second = identities[cid]
                else { continue }
                if CorridorLaneSchedule.laneComesBefore(first, second) {
                    rank += 1
                }
            }
            return rank
        }

        // ---- placement ------------------------------------------------

        mutating func place(
            _ cid: Int,
            side: Int?,
            gsign: Int,
            rank: Int,
            si: Int
        ) -> Double {
            let offsets = groupOffsets(gsign)
            let outward = gsign >= 0 ? 1 : -1
            let stayer = travelsFar(cid, si)
            let band: (centre: Double, width: Double)?
            if stayer {
                let bound = stableBound(cid, si)
                band = (bound.centre ?? 0, bound.width)
            } else {
                band = nil
            }
            func fits(_ candidate: Double) -> Bool {
                guard let band else { return true }
                return abs(candidate - band.centre)
                    <= band.width + 1e-9
            }
            if offsets.isEmpty {
                let firstSlot = LaneScheduleConstants.laneSpacing / 2
                    * Double(gsign)
                if occupied().allSatisfy({ abs(firstSlot - $0)
                    >= LaneScheduleConstants.slotClearance }) {
                    return firstSlot
                }
                return freeSlot(
                    firstSlot,
                    step: LaneScheduleConstants.laneSpacing / 2
                        * Double(outward)
                )
            }
            if side == nil {
                if stayer {
                    // A stayer with no approach side (born on this
                    // corridor or riding it to its end) belongs NEXT to
                    // the members it actually travels with — never stacked
                    // outside strangers whose extreme slots peel off in a
                    // few segments.
                    let slotKey = publicRouteKey(for: cid)
                    let compSlots = slots.filter {
                        $0.key != slotKey && staysKey($0.key, si)
                    }.map(\.value)
                    let target: Double
                    if !compSlots.isEmpty {
                        let comps = compSlots.sorted()
                        target = comps[comps.count / 2]
                    } else {
                        target = LaneScheduleConstants.laneSpacing / 2
                            * Double(gsign)
                    }
                    let taken = occupied()
                    for step in 0..<30 {
                        let candidates: [Double] = step == 0
                            ? [target]
                            : (target >= 0
                               ? [
                                   target
                                       + LaneScheduleConstants
                                           .laneSpacing * Double(step),
                                   target
                                       - LaneScheduleConstants
                                           .laneSpacing * Double(step)
                               ]
                               : [
                                   target
                                       - LaneScheduleConstants
                                           .laneSpacing * Double(step),
                                   target
                                       + LaneScheduleConstants
                                           .laneSpacing * Double(step)
                               ])
                        for candidate in candidates {
                            if taken.contains(where: {
                                abs(candidate - $0)
                                    < LaneScheduleConstants.slotClearance
                            }) { continue }
                            if crossesCentre(candidate, gsign: gsign) {
                                continue
                            }
                            if !fits(candidate) { continue }
                            return candidate
                        }
                    }
                    return freeSlot(
                        target,
                        step: LaneScheduleConstants.laneSpacing / 2
                            * Double(outward)
                    )
                }
                // A leaver born on the corridor: prefer the slot its
                // numeric identity suggests, else step outward.
                let ordered = offsets.sorted()
                let target: Double
                if rank >= ordered.count {
                    target = outermost(offsets, outward: outward)
                        + LaneScheduleConstants.laneSpacing
                            * Double(outward)
                } else if outward > 0 {
                    target = ordered[rank]
                } else {
                    target = ordered.reversed()[rank]
                }
                if occupied().allSatisfy({ abs(target - $0)
                    >= LaneScheduleConstants.slotClearance }) {
                    return target
                }
                return freeSlot(
                    target,
                    step: LaneScheduleConstants.laneSpacing / 2
                        * Double(outward)
                )
            }
            if side == outward {
                let base = outermost(offsets, outward: outward)
                    + LaneScheduleConstants.laneSpacing * Double(outward)
                let candidate = freeSlot(
                    base,
                    step: LaneScheduleConstants.laneSpacing / 2
                        * Double(outward)
                )
                if fits(candidate) {
                    return candidate
                }
            } else {
                let innerBase = innermost(offsets, outward: outward)
                    - LaneScheduleConstants.laneSpacing
                        * Double(outward)
                if !crossesCentre(innerBase, gsign: gsign) {
                    let candidate = freeSlot(
                        innerBase,
                        step: -LaneScheduleConstants.laneSpacing / 2
                            * Double(outward)
                    )
                    if !crossesCentre(candidate, gsign: gsign),
                       fits(candidate) {
                        return candidate
                    }
                }
            }
            if let band {
                // Outside the band the stable membership justifies: take
                // the free rung nearest the band centre, stepping outward
                // within the band — the wide adopted extremes peel off
                // shortly.
                let taken = occupied()
                let signs: [Double] = band.centre >= 0 ? [1, -1] : [-1, 1]
                for step in 0..<(taken.count + 14) {
                    for sign in signs {
                        let candidate = band.centre
                            + sign
                            * LaneScheduleConstants.laneSpacing
                            * Double(step)
                        if taken.contains(where: {
                            abs(candidate - $0)
                                < LaneScheduleConstants.slotClearance
                        }) { continue }
                        if crossesCentre(candidate, gsign: gsign) {
                            continue
                        }
                        if abs(candidate - band.centre) > band.width {
                            continue
                        }
                        return candidate
                    }
                }
            }
            let outerBase = outermost(offsets, outward: outward)
                + LaneScheduleConstants.laneSpacing * Double(outward)
            return freeSlot(
                outerBase,
                step: LaneScheduleConstants.laneSpacing / 2
                    * Double(outward)
            )
        }

        mutating func nearestScheduledSample(
            _ cid: Int,
            _ location: CorridorMembership.CandidateLocation
        ) -> Sample? {
            let memberKey = StrandKey(
                journeyID: cid,
                polylineIndex: location.polylineIndex
            )
            let entries = schedule[memberKey] ?? [:]
            let si = location.segmentIndex
            for delta in 0..<12 {
                for probe in [si - delta, si + delta] where probe >= 0 {
                    if let sample = entries[probe] {
                        return sample
                    }
                }
            }
            return nil
        }

        mutating func adoptExisting(_ si: Int) {
            for cid in presentJourneys(si) {
                let slotKey = publicRouteKey(for: cid)
                guard slots[slotKey] == nil else { continue }
                let own: CorridorMembership.CandidateLocation
                if cid == key.journeyID {
                    own = CorridorMembership.CandidateLocation(
                        polylineIndex: key.polylineIndex,
                        segmentIndex: si
                    )
                } else {
                    guard let location = ownLocation(cid, si)
                        ?? nearestOwnLocation(cid, si)
                    else { continue }
                    own = location
                }
                guard let sample = nearestScheduledSample(cid, own)
                else { continue }
                let direction = segmentDirection(at: si)
                let sign: Double = sample.directionX * direction.0
                    + sample.directionY * direction.1 >= 0 ? 1 : -1
                let adopted = sample.offset * sign
                if travelsFar(cid, si) {
                    let bound = stableBound(cid, si)
                    if bound.count > 1,
                       abs(adopted - (bound.centre ?? 0)) > bound.width {
                        // Context-foreign slot: the entry was set in some
                        // other corridor's lattice (an express stub where
                        // this strand was a momentary outer leaver). A
                        // stayer here must not inherit it five lanes out
                        // — leave it for placement.
                        continue
                    }
                }
                slots[slotKey] = adopted
                slotGroups[slotKey] = groupSign(cid, si)
            }
        }

        mutating func exitAwareSide(
            for cid: Int,
            at si: Int
        ) -> Int? {
            if let side = joinSide(cid, si) {
                return side
            }
            // A strand born on the corridor (trip start / boarding stop)
            // appears in place, so any free slot is crossing free: prefer
            // the side it will peel off toward, so a fork's strands sit
            // adjacent, subway-style. Includes presence that runs to the
            // sweep end: the spine's last partner peels there too.
            let outSi = presence[cid]?
                .first { $0.0 <= si && si < $0.1 }?.1 ?? s1
            return exitSide(cid, min(outSi, s1))
        }

        // ---- birth ----------------------------------------------------

        mutating func birth(_ si: Int) {
            if !slots.isEmpty {
                // Chained sweep start where earlier lanes exist.
                let spineKey = key
                for cid in presentJourneys(si) {
                    let slotKey = publicRouteKey(for: cid)
                    guard slots[slotKey] == nil else { continue }
                    let gsign = groupSign(cid, si)
                    slotGroups[slotKey] = gsign
                    // Continue this strand's prior ribbon when it has one:
                    // the nearest existing entry, converted into this
                    // spine's frame (see adoptExisting). A leaver always
                    // continues it. A stayer continues it when the entry's
                    // reference journey rides this sweep: the entry was
                    // then recorded against a street this sweep covers,
                    // and re-deriving the slot from this spine's reads can
                    // pick the opposite side at the record seam, swinging
                    // the ribbon across its companions at the boundary. A
                    // context-foreign entry — its reference not present
                    // here — still falls through to placement.
                    let own: CorridorMembership.CandidateLocation?
                    if cid == spineKey.journeyID {
                        own = CorridorMembership.CandidateLocation(
                            polylineIndex: spineKey.polylineIndex,
                            segmentIndex: si
                        )
                    } else {
                        own = ownLocation(cid, si)
                            ?? nearestOwnLocation(cid, si)
                    }
                    if let own,
                       let sample = nearestScheduledSample(cid, own) {
                        let direction = segmentDirection(at: si)
                        let sign: Double = sample.directionX
                            * direction.0 + sample.directionY
                            * direction.1 >= 0 ? 1 : -1
                        let candidate = sample.offset * sign
                        let clear = occupied().allSatisfy {
                            abs(candidate - $0)
                                >= LaneScheduleConstants.slotClearance
                        }
                        if clear {
                            if !travelsFar(cid, si)
                                    || presence[
                                        sample.referenceID
                                    ] != nil {
                                slots[slotKey] = candidate
                                continue
                            }
                        }
                    }
                    let rank = numericRank(presentJourneys(si), cid)
                    var side = exitAwareSide(for: cid, at: si)
                    if snake, side != nil {
                        // Winding street: joiners join the staircase side
                        // — ordered by where they leave, not by which side
                        // of this particular bend they arrived from.
                        side = gsign >= 0 ? 1 : -1
                    }
                    slots[slotKey] = place(
                        cid,
                        side: side,
                        gsign: gsign,
                        rank: rank,
                        si: si
                    )
                }
                return
            }
            struct CohortMember {
                let journeyID: Int
                let slotKey: String
                let gsign: Int
                let outSi: Int
            }
            var cohort: [CohortMember] = []
            // Run-start grace: presence that begins within a few tens of
            // metres of the birth sample is a founding member whose first
            // segment simply has no stable scan match (polyline starts,
            // stop driveways) — not a mid-run joiner. It belongs in the
            // fork walk with the rest of the founding bundle, or it lands
            // on the outer edge a sample later and the ladder is
            // backwards.
            var founders: [Int: Int] = [:]
            for cid in presentJourneys(si) {
                founders[cid] = si
            }
            for (cid, stretches) in presence {
                guard founders[cid] == nil else { continue }
                guard let start = stretches
                    .first(where: { s0 <= $0.0 && $0.0 <= s1 })?.0
                else { continue }
                guard strand.arc[start] - strand.arc[si] > 0,
                      strand.arc[start] - strand.arc[si]
                          <= LaneScheduleConstants.birthGrace
                else { continue }
                founders[cid] = start
            }
            for cid in founders.keys.sorted(by: {
                guard let first = identities[$0],
                      let second = identities[$1]
                else { return $0 < $1 }
                return CorridorLaneSchedule.laneComesBefore(first, second)
            }) {
                let slotKey = publicRouteKey(for: cid)
                guard slots[slotKey] == nil else { continue }
                guard let start = founders[cid] else { continue }
                let gsign = groupSign(cid, start)
                let outSi = presence[cid]?
                    .first { $0.0 <= start && start < $0.1 }?.1
                    ?? s1
                cohort.append(CohortMember(
                    journeyID: cid,
                    slotKey: slotKey,
                    gsign: gsign,
                    outSi: outSi
                ))
                slotGroups[slotKey] = gsign
            }
            let withGroup = cohort.filter { $0.gsign >= 0 }
            let against = cohort.filter { $0.gsign < 0 }
            let both = !withGroup.isEmpty && !against.isEmpty

            func ordered(
                _ group: [CohortMember],
                sign: Int
            ) -> [CohortMember] {
                // Fork walk, innermost -> outermost on this group's
                // lattice. Departures run in street order; the first to
                // leave on a side sits outermost there. The spine itself
                // always stays; any OTHER strand's presence running to the
                // sweep end is that strand leaving as the last partner
                // (the run ended because sharing ended), so it departs at
                // s1. A nil continuation side means the strand genuinely
                // carries on along the street — a stayer.
                let spineID = key.journeyID
                var stayers = group.filter { $0.journeyID == spineID }
                let leaving = group
                    .filter { $0.journeyID != spineID }
                    .sorted {
                        let firstOut = min($0.outSi, s1)
                        let secondOut = min($1.outSi, s1)
                        if firstOut != secondOut {
                            return firstOut < secondOut
                        }
                        guard let first = identities[$0.journeyID],
                              let second = identities[$1.journeyID]
                        else {
                            return $0.journeyID < $1.journeyID
                        }
                        return CorridorLaneSchedule.laneComesBefore(
                            first,
                            second
                        )
                    }
                var lefts: [CohortMember] = []
                var rights: [CohortMember] = []
                for member in leaving {
                    let turn = turnSide(
                        member.journeyID,
                        min(member.outSi, s1)
                    )
                    if snake {
                        // Staircase: every exit takes the same side of the
                        // ladder, ordered by exit point -- first-out
                        // outermost. The local side only separates ties at
                        // one point — except a continuer the corridor
                        // turns AWAY from (turnSide -1): it takes the
                        // opposite side, or the turning bundle sweeps
                        // across its straight ribbon.
                        if turn == -1 {
                            rights.append(member)
                        } else {
                            lefts.append(member)
                        }
                        continue
                    }
                    var side = departureSide(
                        member.journeyID,
                        min(member.outSi, s1)
                    )
                    if let turn {
                        // A straight-continuer at a corridor turn: its
                        // side is the outside of the turn, not the local
                        // peel side.
                        side = turn
                    }
                    switch side {
                    case 1: lefts.append(member)
                    case -1: rights.append(member)
                    default: stayers.append(member)
                    }
                }
                let middles = stayers.sorted {
                    guard let first = identities[$0.journeyID],
                          let second = identities[$1.journeyID]
                    else {
                        return $0.journeyID < $1.journeyID
                    }
                    return CorridorLaneSchedule.laneComesBefore(first, second)
                }
                return sign >= 0
                    ? rights + middles + lefts.reversed()
                    : lefts + middles + rights.reversed()
            }

            for (group, sign) in [(withGroup, 1), (against, -1)] {
                let sequence = ordered(group, sign: sign)
                guard !sequence.isEmpty else { continue }
                if !both {
                    let count = sequence.count
                    for (index, member) in sequence.enumerated() {
                        slots[member.slotKey] =
                            (Double(index) - Double(count - 1) / 2)
                                * LaneScheduleConstants.laneSpacing
                                * (sign >= 0 ? 1 : -1)
                    }
                    continue
                }
                var slot = LaneScheduleConstants.laneSpacing / 2
                    * Double(sign)
                for member in sequence {
                    slots[member.slotKey] = slot
                    slot += LaneScheduleConstants.laneSpacing
                        * Double(sign)
                }
            }
        }

        // ---- record ---------------------------------------------------

        mutating func record(_ bstart: Int, _ bend: Int, _ siRef: Int) {
            let present = presentJourneys(siRef)
            let referenceKeys = Set(
                present.map { publicRouteKey(for: $0) }
            )
            if let current = stickyReferenceID,
               referenceKeys.contains(publicRouteKey(for: current)) {
                stickyReferenceID = current
            } else {
                stickyReferenceID = present.first
            }
            guard let referenceID = stickyReferenceID else { return }
            for si in bstart..<bend {
                let direction = segmentDirection(at: si)
                let spineSlotKey = publicRouteKey(for: key.journeyID)
                if let spineSlot = slots[spineSlotKey],
                   schedule[key]?[si] == nil {
                    schedule[key, default: [:]][si] = Sample(
                        offset: spineSlot,
                        directionX: direction.0,
                        directionY: direction.1,
                        referenceID: referenceID
                    )
                }
                for cid in present {
                    guard let offset = slots[
                        publicRouteKey(for: cid)
                    ] else { continue }
                    guard let location = ownLocation(cid, si)
                    else { continue }
                    let memberKey = StrandKey(
                        journeyID: cid,
                        polylineIndex: location.polylineIndex
                    )
                    guard schedule[memberKey]?[location.segmentIndex]
                        == nil else { continue }
                    schedule[memberKey, default: [:]][
                        location.segmentIndex
                    ] = Sample(
                        offset: offset,
                        directionX: direction.0,
                        directionY: direction.1,
                        referenceID: referenceID
                    )
                }
            }
        }

        // ---- the event loop -------------------------------------------

        mutating func mainLoop() {
            guard strand.points.count >= 2 else { return }
            // Event bounds: run ends plus every presence stretch edge.
            var bounds = Set([s0, s1])
            for stretches in presence.values {
                for (start, end) in stretches {
                    if s0 <= start && start <= s1 {
                        bounds.insert(start)
                    }
                    if s0 <= end && end <= s1 {
                        bounds.insert(end)
                    }
                }
            }
            let orderedBounds = bounds.sorted()

            var previous: Int?
            for index in 0..<(orderedBounds.count - 1) {
                let bstart = orderedBounds[index]
                let bend = orderedBounds[index + 1]
                guard bend > bstart else { continue }
                let si = bstart
                adoptExisting(si)
                if previous == nil {
                    birth(si)
                } else {
                    let before = presentKeys(previous!)
                    let after = presentKeys(si)
                    for slotKey in before
                    where !after.contains(slotKey) && slots[slotKey] != nil {
                        memory[slotKey] = slots.removeValue(forKey: slotKey)
                        slotGroups.removeValue(forKey: slotKey)
                    }
                    // Momentary-crowd collapse: a stub of pass-throughs (a
                    // transit center, a ramp share) holds the founding
                    // ladder's outer rungs and parks the corridor's own
                    // long riders off their street -- displaced to draw a
                    // parallel stripe, then never returned. When that
                    // crowd peels, translate the whole surviving lattice
                    // back onto the street (median slot -> 0). One rigid
                    // shift per departure: order and spacing are
                    // untouched, and corridors whose leavers are real
                    // bundle members (a twentieth of the run or more)
                    // never fire.
                    let departedKeys = before.filter { !after.contains($0) }
                    if !departedKeys.isEmpty, !slots.isEmpty {
                        let runLengthValue = strand.arc[s1] - strand.arc[s0]
                        var memberIDByKey: [String: Int] = [:]
                        // KNOWN NONDETERMINISM, DELIBERATELY LEFT ALONE.
                        //
                        // Both directions of one route collapse onto a single
                        // public key, so several journeys claim it and the last
                        // writer wins. `presence` is a Dictionary and Swift
                        // reseeds its hasher per process, so a different member
                        // wins on each launch, which moves departedLength below
                        // and can flip the collapse test.
                        //
                        // Picking a canonical member here (highest-ranked under
                        // laneComesBefore) was tried and reverted: an A/B over
                        // the cached 2026-09-14 downtown snapshot showed it
                        // suppresses a collapse that should fire, pushing the
                        // outer rungs far off the street -- route 11 from -28.83
                        // to -39.90 lanes, route 6 from -24.96 to -35.70, route
                        // 5 from 10.71 to 2.02, and it reordered 14/24X and
                        // crossed GR Route 10 onto the other side of the spine
                        // in Carpinteria. The journey set was identical, so this
                        // was pure lane geometry, and the pre-existing behaviour
                        // is the one that has been visually validated.
                        //
                        // Fixing it properly needs a decision about which member
                        // a departed public key should be measured by -- the
                        // longest rider that just left, the shortest, or the one
                        // whose stretch actually ends here -- and that is domain
                        // knowledge, not a determinism question. Until then the
                        // audit's scheduledSegmentCount and trunkVertexCount
                        // carry a small run-to-run variance; every other metric,
                        // including the lateral lane order, is reproducible.
                        for (cid, _) in presence {
                            memberIDByKey[publicRouteKey(for: cid)] = cid
                        }
                        func endStretchLength(_ cid: Int) -> Double {
                            // The stretch that just ended -- a member with
                            // a long stretch elsewhere (it returns further
                            // down the run) is not a long rider leaving.
                            guard let stretches = presence[cid] else {
                                return 0
                            }
                            for (start, end) in stretches
                            where start <= previous!
                                && previous! < end {
                                return strand.arc[end] - strand.arc[start]
                            }
                            return 0
                        }
                        func longestStretch(_ cid: Int) -> Double {
                            guard let stretches = presence[cid] else {
                                return 0
                            }
                            return stretches
                                .map {
                                    strand.arc[$0.1] - strand.arc[$0.0]
                                }
                                .max() ?? 0
                        }
                        let departedLength = departedKeys
                            .compactMap { memberIDByKey[$0] }
                            .map { endStretchLength($0) }
                            .max() ?? 0
                        let survivorLength = presence
                            .filter {
                                slots[
                                    publicRouteKey(for: $0.key)
                                ] != nil
                            }
                            .map { longestStretch($0.key) }
                            .max() ?? 0
                        if departedLength
                                < LaneScheduleConstants.collapseShare
                                    * runLengthValue,
                           survivorLength
                                >= LaneScheduleConstants.collapseRatio
                                    * departedLength {
                            let sortedValues = slots.values.sorted()
                            let count = sortedValues.count
                            let median: Double = count % 2 == 1
                                ? sortedValues[count / 2]
                                : (sortedValues[count / 2 - 1]
                                   + sortedValues[count / 2]) / 2
                            if abs(median)
                                    > LaneScheduleConstants
                                        .collapseMinimum {
                                for slotKey in slots.keys {
                                    slots[slotKey]! -= median
                                }
                            }
                        }
                    }
                    for cid in presentJourneys(si) {
                        let slotKey = publicRouteKey(for: cid)
                        guard slots[slotKey] == nil else { continue }
                        slotGroups[slotKey] = groupSign(cid, si)
                        if let remembered = memory[slotKey],
                           occupied().allSatisfy({
                               abs(remembered - $0)
                                   >= LaneScheduleConstants.slotClearance
                           }) {
                            if !travelsFar(cid, si) {
                                slots[slotKey] = remembered
                                continue
                            }
                            let bound = stableBound(cid, si)
                            if bound.count == 1
                                || abs(
                                    remembered - (bound.centre ?? 0)
                                ) <= bound.width {
                                slots[slotKey] = remembered
                                continue
                            }
                        }
                        // A leaver rejoining (or memory unusable):
                        // continue its own prior ribbon — the nearest
                        // existing entry, converted into this spine's
                        // frame — rather than a fresh lattice slot that
                        // jumps the drawn lane at the record seam.
                        if !travelsFar(cid, si) {
                            let own: CorridorMembership.CandidateLocation?
                            if cid == key.journeyID {
                                own = CorridorMembership.CandidateLocation(
                                    polylineIndex: key.polylineIndex,
                                    segmentIndex: si
                                )
                            } else {
                                own = ownLocation(cid, si)
                                    ?? nearestOwnLocation(cid, si)
                            }
                            if let own,
                               let sample = nearestScheduledSample(
                                   cid,
                                   own
                               ) {
                                let direction = segmentDirection(at: si)
                                let sign: Double =
                                    sample.directionX * direction.0
                                    + sample.directionY * direction.1 >= 0
                                    ? 1 : -1
                                let candidate = sample.offset * sign
                                if occupied().allSatisfy({
                                    abs(candidate - $0)
                                        >= LaneScheduleConstants
                                            .slotClearance
                                }) {
                                    slots[slotKey] = candidate
                                    continue
                                }
                            }
                        }
                        let rank = numericRank(presentJourneys(si), cid)
                        var side = exitAwareSide(for: cid, at: si)
                        if snake, side != nil {
                            // Winding street: joiners join the staircase
                            // side -- ordered by where they leave, not by
                            // which side of this particular bend they
                            // arrived from.
                            side = (slotGroups[slotKey] ?? 1) >= 0
                                ? 1 : -1
                        }
                        slots[slotKey] = place(
                            cid,
                            side: side,
                            gsign: slotGroups[slotKey] ?? 1,
                            rank: rank,
                            si: si
                        )
                    }
                }
                record(bstart, bend, si)
                previous = si
            }
        }
    }
}
