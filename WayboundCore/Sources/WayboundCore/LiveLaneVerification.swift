import Foundation

/// A small, machine-readable audit of the same lane pipeline the app and
/// `waybound-lanelab` use. Live verification deliberately does not invent a
/// second lane algorithm: the command turns live trip shapes into
/// `LaneDiagnosticsDocument.Journey` values and this type runs the package's
/// scan, anchored schedule, and layout stages in that order.
public struct LaneVerificationResult: Codable, Equatable, Sendable {
    public let status: String
    public let passed: Bool
    public let journeyCount: Int
    public let polylineCount: Int
    public let sharedSegmentCount: Int
    public let scheduledSegmentCount: Int
    public let layoutVertexCount: Int
    public let trunkVertexCount: Int
    public let issues: [String]

    public init(
        status: String,
        passed: Bool,
        journeyCount: Int,
        polylineCount: Int,
        sharedSegmentCount: Int,
        scheduledSegmentCount: Int,
        layoutVertexCount: Int,
        trunkVertexCount: Int,
        issues: [String]
    ) {
        self.status = status
        self.passed = passed
        self.journeyCount = journeyCount
        self.polylineCount = polylineCount
        self.sharedSegmentCount = sharedSegmentCount
        self.scheduledSegmentCount = scheduledSegmentCount
        self.layoutVertexCount = layoutVertexCount
        self.trunkVertexCount = trunkVertexCount
        self.issues = issues
    }
}

public enum LiveLaneVerification {

    /// Runs the production package pipeline over live or fixture-derived
    /// journeys. A missing journey is a useful result rather than a false
    /// green: the report says `skipped` so an area with no usable live shapes
    /// cannot be mistaken for an audited corridor.
    public static func verify(
        journeys: [LaneDiagnosticsDocument.Journey],
        selectedJourneyID: Int? = nil,
        laneSpacingPoints: Double = LaneScheduleConstants.laneSpacing
    ) -> LaneVerificationResult {
        let usableJourneys = journeys.filter { journey in
            journey.polylines.contains { $0.count >= 2 }
        }
        let polylineCount = usableJourneys.reduce(0) { partial, journey in
            partial + journey.polylines.filter { $0.count >= 2 }.count
        }

        guard !usableJourneys.isEmpty else {
            return LaneVerificationResult(
                status: "skipped",
                passed: false,
                journeyCount: journeys.count,
                polylineCount: 0,
                sharedSegmentCount: 0,
                scheduledSegmentCount: 0,
                layoutVertexCount: 0,
                trunkVertexCount: 0,
                issues: ["no usable trip shape was available for the lane pipeline"]
            )
        }

        // These are intentionally the same three package stages consumed by
        // the app's map renderer and replayed by the lanelab/golden tests.
        let scan = CorridorMembership.scan(
            journeys: usableJourneys,
            laneSpacingPoints: laneSpacingPoints
        )
        let schedule = CorridorLaneSchedule.schedule(
            journeys: usableJourneys,
            laneSpacingPoints: laneSpacingPoints
        )
        let layouts = CorridorLaneLayoutEngine.layouts(
            journeys: usableJourneys,
            schedule: schedule,
            selectedJourneyID: selectedJourneyID,
            laneSpacingPoints: laneSpacingPoints
        )

        var sharedSegmentCount = 0
        for rows in scan.rows.values {
            sharedSegmentCount += rows.reduce(0) { partial, members in
                partial + (members.isEmpty ? 0 : 1)
            }
        }
        let scheduledSegmentCount = schedule.values.reduce(0) {
            $0 + $1.count
        }

        var layoutVertexCount = 0
        var trunkVertexCount = 0
        var issues: [String] = []

        for journey in usableJourneys {
            for (polylineIndex, polyline) in journey.polylines.enumerated()
            where polyline.count >= 2 {
                let key = CorridorLaneSchedule.StrandKey(
                    journeyID: journey.id,
                    polylineIndex: polylineIndex
                )
                guard let layout = layouts[key] else {
                    issues.append(
                        "missing layout for journey \(journey.id) "
                            + "polyline \(polylineIndex)"
                    )
                    continue
                }

                guard layout.offsets.count == polyline.count,
                      layout.shared.count == polyline.count,
                      layout.trunk.count == polyline.count
                else {
                    issues.append(
                        "layout length mismatch for journey \(journey.id) "
                            + "polyline \(polylineIndex)"
                    )
                    continue
                }

                layoutVertexCount += layout.offsets.count
                trunkVertexCount += layout.trunk.filter { $0 }.count
                if layout.offsets.contains(where: { !$0.isFinite }) {
                    issues.append(
                        "non-finite lane offset for journey \(journey.id) "
                            + "polyline \(polylineIndex)"
                    )
                }
            }
        }

        return LaneVerificationResult(
            status: issues.isEmpty ? "passed" : "failed",
            passed: issues.isEmpty,
            journeyCount: usableJourneys.count,
            polylineCount: polylineCount,
            sharedSegmentCount: sharedSegmentCount,
            scheduledSegmentCount: scheduledSegmentCount,
            layoutVertexCount: layoutVertexCount,
            trunkVertexCount: trunkVertexCount,
            issues: issues
        )
    }
}
