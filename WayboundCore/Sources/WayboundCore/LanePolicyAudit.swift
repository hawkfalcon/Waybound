import Foundation

/// What one collapse-rider policy costs the drawn corridor.
///
/// The numbers come from the package's own measurement harness
/// (`LaneHarness`): the same scan, the same downstream pipeline, and the same
/// screen-space ribbon the lane gates use, over the same journeys. Since the
/// policies differ *only* in the lane order the scheduler chooses, every
/// difference here is attributable to that order — which is what makes
/// "fewest lines cross" a comparable criterion between them.
public struct LaneDrawMetrics: Codable, Equatable, Sendable {
    public let policy: String
    /// Proper crossings between the drawn ribbons of different journeys.
    public let crossings: Int
    /// Crossings between two journeys that are both stacked and both well
    /// inside their stacked runs: the ordering artifacts a subway-style
    /// corridor must not have. Stub merges at junctions are inherent and land
    /// in `crossings` only.
    public let bundleCrossings: Int
    /// The offending pairs, as `ROUTE/ROUTE×count`.
    public let bundlePairs: [String]
    /// Worst-pair relative drift across the bundle, in lanes.
    public let wobble: Double?
    /// Smallest gap between two stacked journeys on one spine, in lanes.
    public let minSeparation: Double?
    /// Worst per-vertex step of the alignment-correction vector, in metres.
    public let alignmentKink: Double
    /// Farthest any lane sits from the corridor spine, in lanes: how far off
    /// its own street the arrangement parks a route.
    public let maxAbsOffsetLanes: Double
    public let collapseEvaluations: Int
    public let collapseFires: Int
    /// Largest lattice translation a collapse ever applied, in lanes.
    public let maxShiftLanes: Double
    /// `ROUTE#journeyID@meanOffset`, innermost first. Harness journey ids
    /// (array positions), not live Transitland ids.
    public let laneOrder: [String]

    /// One grep-able line for a CI log or PR report. Crossings first, since
    /// that is the criterion; the rest is what it cost to get them.
    public func reportLine(slug: String) -> String {
        func number(_ value: Double?) -> String {
            guard let value else { return "-" }
            return String(format: "%.2f", value)
        }
        return "COLLAPSE-RIDER \(slug) \(policy) crossings=\(crossings) "
            + "bundle=\(bundleCrossings) "
            + "pairs=[\(bundlePairs.joined(separator: ","))] "
            + "wobble=\(number(wobble)) sep=\(number(minSeparation)) "
            + "kink=\(number(alignmentKink)) "
            + "maxoff=\(String(format: "%.2f", maxAbsOffsetLanes)) "
            + "fires=\(collapseFires)/\(collapseEvaluations) "
            + "shift=\(String(format: "%.2f", maxShiftLanes))"
    }
}

/// Runs the lane pipeline over a journey set once per collapse-rider policy
/// and reports the drawn-corridor metrics, so the rule that produces the
/// fewest crossings can be chosen from data instead of argument.
///
/// Verification tooling: the app never calls this, and it deliberately uses
/// `LaneHarness` (the comparative mirror) rather than the layout engine the
/// map draws with, so a policy sweep is a controlled comparison.
public enum LanePolicyAudit {

    /// Measure one policy. Returns nil when there is nothing to measure.
    public static func metrics(
        journeys: [LaneDiagnosticsDocument.Journey],
        rider: LaneCollapseRider,
        laneSpacingPoints: Double = LaneScheduleConstants.laneSpacing,
        includeMotion: Bool = true
    ) -> LaneDrawMetrics? {
        // One strand per journey: its flagship (longest) polyline, densified
        // exactly as the scheduler densifies it. The harness reads a strand's
        // segments directly, while the scheduler densifies internally, so
        // passing raw traffic shapes here would compare different geometry.
        var strands: [LaneHarness.Strand] = []
        var harnessJourneys: [LaneDiagnosticsDocument.Journey] = []
        for journey in journeys {
            guard let flagship = journey.polylines
                .filter({ $0.count >= 2 })
                .max(by: { $0.count < $1.count })
            else { continue }
            let index = strands.count
            let coordinates = CorridorMembership.densify(flagship)
            var direction = journey.directionID
            if let value = direction, value < 0 { direction = nil }
            strands.append(LaneHarness.Strand(
                id: "\(journey.id)",
                num: journey.routeNumber,
                direction: direction,
                coords: coordinates,
                agency: journey.agency,
                departures: journey.departures
            ))
            harnessJourneys.append(LaneDiagnosticsDocument.Journey(
                id: index,
                routeNumber: journey.routeNumber,
                agency: journey.agency,
                directionID: direction,
                stackOrder: journey.stackOrder,
                departures: journey.departures,
                polylines: [coordinates]
            ))
        }
        guard !strands.isEmpty else { return nil }

        let scan = LaneHarness.membershipScan(strands)
        let audit = LaneScheduleAudit()
        let schedule = CorridorLaneSchedule.schedule(
            journeys: harnessJourneys,
            laneSpacingPoints: laneSpacingPoints,
            collapseRider: rider,
            audit: audit
        )
        let layouts = LaneHarness.scheduledLayouts(
            strands: strands,
            scan: scan,
            schedule: LaneHarness.rekeySchedule(schedule)
        )
        let ribbons = layouts.mapValues { LaneHarness.ribbon($0) }
        let crossings = LaneHarness.countCrossings(ribbons)
        let (bundleCrossings, pairs) = LaneHarness.countBundleCrossings(
            layouts,
            ribbons
        )
        let bundlePairs = pairs.map { pair in
            "\(strands[pair.0].num)/\(strands[pair.1].num)×\(pair.2)"
        }
        var wobble: Double?
        var separation: Double?
        if includeMotion {
            var frames: [Int: LaneHarness.SpineFrame] = [:]
            wobble = LaneHarness.bundleWobble(
                layouts,
                strands: strands,
                scan: scan,
                spineFrames: &frames
            )
            separation = LaneHarness.minLaneSeparation(
                layouts,
                strands: strands,
                scan: scan,
                spineFrames: &frames
            )
        }
        let kink = layouts.values
            .map { LaneHarness.alignmentKink($0) }
            .max() ?? 0
        let maxOffset = layouts.values
            .flatMap { $0.offsets }
            .map { abs($0) }
            .max() ?? 0
        let order = LiveLaneVerification.lateralOrder(
            journeys: harnessJourneys,
            laneSpacingPoints: laneSpacingPoints,
            collapseRider: rider
        )
        return LaneDrawMetrics(
            policy: rider.description,
            crossings: crossings,
            bundleCrossings: bundleCrossings,
            bundlePairs: bundlePairs,
            wobble: includeMotion ? wobble : nil,
            minSeparation: includeMotion ? separation : nil,
            alignmentKink: kink,
            maxAbsOffsetLanes: laneSpacingPoints > 0
                ? maxOffset / laneSpacingPoints
                : 0,
            collapseEvaluations: audit.collapseEvaluations,
            collapseFires: audit.collapseFires,
            maxShiftLanes: audit.maxShiftLanes,
            laneOrder: order
        )
    }

    /// Measure every candidate on one journey set, in `auditSet` order.
    /// Motion metrics (wobble, separation) cost a pairwise spine walk each,
    /// so they run only for the semantic candidates, not the draw samples.
    public static func sweep(
        journeys: [LaneDiagnosticsDocument.Journey],
        riders: [LaneCollapseRider] = LaneCollapseRider.auditSet(),
        laneSpacingPoints: Double = LaneScheduleConstants.laneSpacing
    ) -> [LaneDrawMetrics] {
        riders.compactMap { rider in
            var motion = false
            switch rider {
            case .longestLeaver, .shortestLeaver, .rankedLeaver: motion = true
            case .drawOrder: motion = false
            }
            return metrics(
                journeys: journeys,
                rider: rider,
                laneSpacingPoints: laneSpacingPoints,
                includeMotion: motion
            )
        }
    }
}
