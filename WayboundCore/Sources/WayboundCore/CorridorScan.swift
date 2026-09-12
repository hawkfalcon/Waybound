import Foundation

/// The corridor membership scan: for every strand (journey, polyline) and
/// every one of its segments, which other journeys run a parallel segment
/// within corridor tolerances at that point.
///
/// This is a pure Swift port of the same-named pass in the shipped app
/// (`WayboundMapView.corridorMembershipScan` + `CorridorSegmentIndex`) and
/// of the replay harness's `membership_scan` — same gates, same tie-breaks,
/// same grid — so all three agree by construction rather than by accident.
/// Every threshold is a shared constant with the reasoning attached.
public enum CorridorMembership {

    /// Densified polylines subdivide edges longer than this (ground
    /// metres). The app's `densifiedRouteCoordinates` and the harness's
    /// `densify` both use 18.
    public static let maximumSegmentMeters: Double = 18

    /// Two segments are corridor-mates when they stay within this ground
    /// distance at the midpoint and both endpoints.
    public static let maximumSeparationMeters: Double = 20

    /// And when their directions agree to within ~21.5 degrees
    /// (cos ~ 0.93), regardless of travel sense (either direction of a
    /// two-way street pairs with a corridor).
    public static let minimumParallelDot: Double = 0.93

    /// The candidate grid: one cell per 64 ground metres, padded 24
    /// metres beyond each segment's bounding box. Valid for the 20-metre
    /// separation query.
    static let gridCellMeters: Double = 64
    static let gridPaddingMeters: Double = 24

    // ------------------------------------------------------------------
    // Geometry
    // ------------------------------------------------------------------

    /// A directed, unit-normalized segment in the shared Mercator space.
    /// Degenerate (sub-unit) segments are nil: they carry no direction and
    /// cannot pair with anything.
    public struct CorridorSegment {
        public let start: ProjectedPoint
        public let end: ProjectedPoint
        public let unitX: Double
        public let unitY: Double

        init?(start: ProjectedPoint, end: ProjectedPoint) {
            let deltaX = end.x - start.x
            let deltaY = end.y - start.y
            let length = hypot(deltaX, deltaY)
            guard length > 0.000_001 else { return nil }
            self.start = start
            self.end = end
            self.unitX = deltaX / length
            self.unitY = deltaY / length
        }

        var midpoint: ProjectedPoint {
            ProjectedPoint(
                x: (start.x + end.x) / 2,
                y: (start.y + end.y) / 2
            )
        }

        /// Nearest point on the segment to `point`, clamped to the extent.
        func projection(of point: ProjectedPoint) -> ProjectedPoint {
            let deltaX = end.x - start.x
            let deltaY = end.y - start.y
            let lengthSquared = deltaX * deltaX + deltaY * deltaY
            guard lengthSquared > 0 else { return point }
            let progress = max(
                0,
                min(
                    1,
                    ((point.x - start.x) * deltaX
                        + (point.y - start.y) * deltaY) / lengthSquared
                )
            )
            return ProjectedPoint(
                x: start.x + progress * deltaX,
                y: start.y + progress * deltaY
            )
        }
    }

    /// Where a matched segment lives on the owning journey: which of its
    /// polylines, and which segment of that polyline.
    public struct CandidateLocation: Equatable {
        public let polylineIndex: Int
        public let segmentIndex: Int
    }

    /// A strand is one journey polyline: (journey id, polyline index).
    public struct StrandKey: Hashable, Sendable {
        public let journeyID: Int
        public let polylineIndex: Int

        public init(journeyID: Int, polylineIndex: Int) {
            self.journeyID = journeyID
            self.polylineIndex = polylineIndex
        }
    }

    // ------------------------------------------------------------------
    // Densify
    // ------------------------------------------------------------------

    /// Subdivide edges longer than `maximumSegmentMeters` (interpolating in
    /// projected space, as MapKit and the harness both do). Edges at or
    /// under the maximum pass through untouched.
    public static func densify(_ coordinates: [GeoCoordinate]) -> [GeoCoordinate] {
        guard coordinates.count >= 2 else { return coordinates }
        var out: [GeoCoordinate] = [coordinates[0]]
        for index in 0..<(coordinates.count - 1) {
            let start = coordinates[index].projected
            let end = coordinates[index + 1].projected
            let scale = GeoProjection.metersPerUnit(
                atLatitude: coordinates[index].latitude
            )
            let groundDistance = start.distance(to: end) * scale
            let subdivisions = max(1, Int(ceil(groundDistance / maximumSegmentMeters)))
            for step in 1...subdivisions {
                let progress = Double(step) / Double(subdivisions)
                let point = ProjectedPoint(
                    x: start.x + (end.x - start.x) * progress,
                    y: start.y + (end.y - start.y) * progress
                )
                out.append(GeoCoordinate.fromProjected(point))
            }
        }
        return out
    }

    // ------------------------------------------------------------------
    // The per-journey candidate index
    // ------------------------------------------------------------------

    /// Grid index over ONE journey's densified flagship polylines (all of
    /// them, together — a match anywhere on the journey's network counts,
    /// with the location saying exactly which polyline and segment).
    struct JourneyIndex {
        let segments: [CorridorSegment]
        let locations: [CandidateLocation]
        private let cellSize: Double
        private var segmentIndicesByCell: [UInt64: [Int]] = [:]

        init(journey: LaneDiagnosticsDocument.Journey, latitude: Double) {
            var segments: [CorridorSegment] = []
            var locations: [CandidateLocation] = []
            for (polylineIndex, polyline) in journey.polylines.enumerated() {
                guard polyline.count >= 2 else { continue }
                let densified = densify(polyline)
                for segmentIndex in 0..<(densified.count - 1) {
                    guard let segment = CorridorSegment(
                        start: densified[segmentIndex].projected,
                        end: densified[segmentIndex + 1].projected
                    ) else { continue }
                    segments.append(segment)
                    locations.append(
                        CandidateLocation(
                            polylineIndex: polylineIndex,
                            segmentIndex: segmentIndex
                        )
                    )
                }
            }
            self.segments = segments
            self.locations = locations

            let pointsPerUnit = 1 / GeoProjection.metersPerUnit(atLatitude: latitude)
            cellSize = max(1, gridCellMeters * pointsPerUnit)
            let padding = gridPaddingMeters * pointsPerUnit

            for (index, segment) in segments.enumerated() {
                let minX = Int(((min(segment.start.x, segment.end.x) - padding) / cellSize).rounded(.down))
                let maxX = Int(((max(segment.start.x, segment.end.x) + padding) / cellSize).rounded(.down))
                let minY = Int(((min(segment.start.y, segment.end.y) - padding) / cellSize).rounded(.down))
                let maxY = Int(((max(segment.start.y, segment.end.y) + padding) / cellSize).rounded(.down))
                for cellX in minX...maxX {
                    for cellY in minY...maxY {
                        segmentIndicesByCell[cellKey(cellX, cellY), default: []]
                            .append(index)
                    }
                }
            }
        }

        private func cellKey(_ x: Int, _ y: Int) -> Int64 {
            (Int64(x) << 32) ^ Int64(bitPattern: Int64(y))
        }

        func candidateIndices(near point: ProjectedPoint) -> [Int] {
            let x = Int((point.x / cellSize).rounded(.down))
            let y = Int((point.y / cellSize).rounded(.down))
            return segmentIndicesByCell[cellKey(x, y)] ?? []
        }
    }

    // ------------------------------------------------------------------
    // The scan
    // ------------------------------------------------------------------

    /// The scan result: per strand, per own segment index, the candidate
    /// journeys matched there (with where on the candidate they matched).
    public struct Result {
        public let rows: [StrandKey: [[Int: CandidateLocation]]]
        public let laneSpacingPoints: Double

        /// True when the strand's `segmentIndex` has at least one member.
        public func isShared(
            _ key: StrandKey,
            _ segmentIndex: Int
        ) -> Bool {
            guard let strandRows = rows[key],
                  segmentIndex >= 0, segmentIndex < strandRows.count
            else { return false }
            return !strandRows[segmentIndex].isEmpty
        }
    }

    public static func scan(
        journeys: [LaneDiagnosticsDocument.Journey],
        laneSpacingPoints: Double = 4.2
    ) -> Result {
        // Per journey: densified strand segments (kept for row structure)
        // and the aggregated candidate index.
        struct PreparedJourney {
            let journey: LaneDiagnosticsDocument.Journey
            let strands: [[CorridorSegment?]]
            let index: JourneyIndex
            let metersPerUnit: Double
        }

        var prepared: [PreparedJourney] = []
        for journey in journeys {
            guard let firstLatitude = journey.polylines.first?.first?.latitude
            else { continue }
            let metersPerUnit = GeoProjection.metersPerUnit(
                atLatitude: firstLatitude
            )
            var strands: [[CorridorSegment?]] = []
            for polyline in journey.polylines {
                guard polyline.count >= 2 else {
                    strands.append([])
                    continue
                }
                let densified = densify(polyline)
                var segments: [CorridorSegment?] = []
                segments.reserveCapacity(densified.count - 1)
                for segmentIndex in 0..<(densified.count - 1) {
                    segments.append(
                        CorridorSegment(
                            start: densified[segmentIndex].projected,
                            end: densified[segmentIndex + 1].projected
                        )
                    )
                }
                strands.append(segments)
            }
            prepared.append(
                PreparedJourney(
                    journey: journey,
                    strands: strands,
                    index: JourneyIndex(journey: journey, latitude: firstLatitude),
                    metersPerUnit: metersPerUnit
                )
            )
        }

        func hasParallel(
            near point: ProjectedPoint,
            direction: CorridorSegment,
            index: JourneyIndex,
            metersPerUnit: Double
        ) -> Bool {
            for candidateIndex in index.candidateIndices(near: point) {
                let candidate = index.segments[candidateIndex]
                guard abs(
                    direction.unitX * candidate.unitX
                        + direction.unitY * candidate.unitY
                ) >= minimumParallelDot else { continue }
                let distance = point.distance(
                    to: candidate.projection(of: point)
                ) * metersPerUnit
                if distance <= maximumSeparationMeters {
                    return true
                }
            }
            return false
        }

        func nearestParallel(
            near point: ProjectedPoint,
            direction: CorridorSegment,
            journey: PreparedJourney
        ) -> CandidateLocation? {
            var best: (distance: Double, location: CandidateLocation)?
            for candidateIndex in journey.index.candidateIndices(near: point) {
                let candidate = journey.index.segments[candidateIndex]
                guard abs(
                    direction.unitX * candidate.unitX
                        + direction.unitY * candidate.unitY
                ) >= minimumParallelDot else { continue }
                let distance = point.distance(
                    to: candidate.projection(of: point)
                ) * journey.metersPerUnit
                guard distance <= maximumSeparationMeters else { continue }
                if best == nil || distance < best!.distance {
                    best = (distance, journey.index.locations[candidateIndex])
                }
            }
            return best?.location
        }

        var rows: [StrandKey: [[Int: CandidateLocation]]] = [:]
        for observer in prepared {
            for (polylineIndex, strandSegments) in observer.strands.enumerated() {
                let key = StrandKey(
                    journeyID: observer.journey.id,
                    polylineIndex: polylineIndex
                )
                var strandRows: [[Int: CandidateLocation]] = []
                strandRows.reserveCapacity(strandSegments.count)
                for segment in strandSegments {
                    guard let segment else {
                        strandRows.append([:])
                        continue
                    }
                    var members: [Int: CandidateLocation] = [:]
                    for candidate in prepared where candidate.journey.id
                        != observer.journey.id {
                        guard let location = nearestParallel(
                            near: segment.midpoint,
                            direction: segment,
                            journey: candidate
                        ) else { continue }
                        // Endpoint gates: the pairing must hold along the
                        // whole segment, not just at the midpoint.
                        guard hasParallel(
                            near: segment.start,
                            direction: segment,
                            index: candidate.index,
                            metersPerUnit: candidate.metersPerUnit
                        ), hasParallel(
                            near: segment.end,
                            direction: segment,
                            index: candidate.index,
                            metersPerUnit: candidate.metersPerUnit
                        ) else { continue }
                        members[candidate.journey.id] = location
                    }
                    strandRows.append(members)
                }
                rows[key] = strandRows
            }
        }

        return Result(rows: rows, laneSpacingPoints: laneSpacingPoints)
    }
}
