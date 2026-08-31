import CoreLocation
import Foundation
import MapKit

/// Pure polyline cleanup, clipping, and stop-to-shape alignment. Turns raw
/// GTFS trip shapes into rider-facing approach / flagship / continuation
/// segments. No view-model state: every threshold is an explicit parameter so
/// unit tests can pin the geometry rules.
enum TripPathGeometry {

    struct Options {
        /// A downstream stop that cannot be placed this close to the shape is
        /// a data mismatch, not a rendering problem.
        var maximumShapeStopDistanceMeters: Double = 250
        /// Root-mean-squared stop-to-shape error for the whole alignment.
        var maximumShapeStopRMSMeters: Double = 100
        /// The boarding stop must sit almost exactly on the shape, otherwise
        /// the "board here" anchor would visibly float off the line.
        var maximumBoardingShapeDistanceMeters: Double = 120
    }

    /// Meters per `MKMapPoint`, calibrated at runtime against `CLLocation`'s
    /// ellipsoidal distance rather than assumed from
    /// `MKMapPointsPerMeterAtLatitude`: on the meter-based MapKit world of
    /// the Xcode 26 SDKs that legacy constant no longer describes
    /// `MKMapPoint`'s scale — it still answers ~8.1 points per meter while
    /// point distances are already true meters — which silently made every
    /// meter threshold in the app about eight times stricter than written
    /// when the two were combined. Calibrating against the projection
    /// actually in use keeps both worlds correct.
    static func metersPerMapPoint(atLatitude latitude: CLLocationDegrees) -> Double {
        let origin = CLLocationCoordinate2D(latitude: latitude, longitude: 0)
        let sample = CLLocationCoordinate2D(latitude: latitude, longitude: 0.01)
        let pointDistance = MKMapPoint(origin).distance(to: MKMapPoint(sample))
        let meterDistance = CLLocation(
            latitude: origin.latitude,
            longitude: origin.longitude
        ).distance(
            from: CLLocation(latitude: sample.latitude, longitude: sample.longitude)
        )
        guard pointDistance > 0, meterDistance > 0 else {
            return 1.0 / MKMapPointsPerMeterAtLatitude(latitude)
        }
        return meterDistance / pointDistance
    }

    /// Very large jumps are almost always malformed coordinates. These high
    /// thresholds intentionally favor retaining legitimate intercity service.
    static func maximumGeometryJump(for routeType: Int) -> CLLocationDistance {
        switch routeType {
        case 4: // ferry
            return 200_000
        case 2: // intercity or commuter rail
            return 100_000
        default:
            return 50_000
        }
    }

    /// The complete cleanup applied to every GTFS shape before it is aligned,
    /// clipped, or drawn: unmistakable one-vertex spikes first (so notch and
    /// spur detection see clean legs), then stop-connector notches, then
    /// short out-and-back spurs.
    ///
    /// Some operators publish trip shapes with a short perpendicular
    /// connector spliced in at every stop: the line runs along the street,
    /// steps sideways to the stop coordinate, and resumes on the street a few
    /// meters ahead (SBMTD route 3 carries one at nearly every stop). Rendered
    /// naively that is a comb of 90-degree jags. `nearStops` supplies the
    /// trip's stop coordinates, which is what distinguishes those connectors
    /// from genuine turns; without stops the notch stage is inert.
    static func cleanedShape(
        from coordinates: [CLLocationCoordinate2D],
        nearStops stops: [CLLocationCoordinate2D] = []
    ) -> [CLLocationCoordinate2D] {
        removingOutAndBackSpurs(
            from: removingStopConnectorNotches(
                from: removingSinglePointSpikes(from: coordinates),
                nearStops: stops
            )
        )
    }

    /// Removes only an unmistakable one-vertex out-and-back excursion. Broader
    /// simplification could erase a legitimate route loop, so it is avoided.
    /// Distances are true meters: the "spike" gates require the line to return
    /// to within 75 m of where it left after traveling 300 m or more, which no
    /// legitimate street geometry does in three points.
    static func removingSinglePointSpikes(
        from coordinates: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count >= 3 else { return coordinates }
        let metersPerPoint = metersPerMapPoint(atLatitude: coordinates[0].latitude)

        var result = coordinates
        var index = 1
        while index < result.count - 1 {
            let previous = MKMapPoint(result[index - 1])
            let candidate = MKMapPoint(result[index])
            let next = MKMapPoint(result[index + 1])
            let incomingDistance = previous.distance(to: candidate) * metersPerPoint
            let outgoingDistance = candidate.distance(to: next) * metersPerPoint
            let bypassDistance = previous.distance(to: next) * metersPerPoint
            let isLargeSpike = incomingDistance > 300
                && outgoingDistance > 300
                && bypassDistance < 75
                && bypassDistance * 8 < incomingDistance + outgoingDistance
            // Some official shapes insert a stop coordinate as a tiny A→B→A
            // spur even though the vehicle remains on the street centerline.
            // Remove only an almost-exact, short reversal; do not generalize
            // this to loops, triangles, or ordinary turns. MTD shape shp-2-51
            // has exactly this seven-meter artifact at Anapamu & Santa
            // Barbara.
            let isTinyExactReversal = incomingDistance >= 2
                && outgoingDistance >= 2
                && incomingDistance <= 40
                && outgoingDistance <= 40
                && bypassDistance <= 2

            if isLargeSpike || isTinyExactReversal {
                result.remove(at: index)
                if index > 1 { index -= 1 }
            } else {
                index += 1
            }
        }
        return result
    }

    /// Removes short out-and-back spurs: a handful of vertices that leave the
    /// line, travel tens of meters, and return to almost the same place before
    /// continuing in the same direction. Feed artifacts — a misplaced stop
    /// coordinate spliced into the shape, a stray survey point — look exactly
    /// like this, and they render as a jagged detour off the street.
    ///
    /// Genuine routing never matches all the gates at once: a terminal loop
    /// around a block travels farther than these bounds, a cul-de-sac or
    /// hairpin comes back facing the other way (the heading gate rejects it),
    /// and ordinary curves never bring their endpoints back together.
    static func removingOutAndBackSpurs(
        from coordinates: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count >= 4 else { return coordinates }
        let metersPerPoint = metersPerMapPoint(atLatitude: coordinates[0].latitude)

        var result = coordinates
        var passes = 0
        while passes < 4 {
            passes += 1
            guard let spurRange = firstOutAndBackSpurRange(
                in: result,
                metersPerPoint: metersPerPoint
            ) else { break }
            result.removeSubrange(spurRange)
        }
        return result
    }

    /// Removes short lateral excursions that touch a known stop: the shape
    /// leaves the street, visits a stop coordinate, and resumes on the street
    /// — including the sparse-shape form whose re-entry vertex sits far down
    /// the street, and a terminal coordinate that is nothing but the stop
    /// itself reached sideways. The spur stage alone catches only the deepest
    /// of these; the V-shaped variant never returns to its anchor at all.
    ///
    /// The decisive gates are that the street continues straight through the
    /// span — anchor and return each sit on the other leg's line of travel —
    /// and that the excursion reaches its stop steeply off that line, the way
    /// a connector does and a gradual curve does not. The chord replacing a
    /// deleted span therefore lies on the street itself: a deletion cannot
    /// draw a diagonal across real turns, jogs, crests, hairpins, or loops,
    /// even when a stop sits exactly on that geometry.
    static func removingStopConnectorNotches(
        from coordinates: [CLLocationCoordinate2D],
        nearStops stops: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count >= 4, !stops.isEmpty else { return coordinates }
        let metersPerPoint = metersPerMapPoint(atLatitude: coordinates[0].latitude)
        let stopPoints = stops.map { MKMapPoint($0) }

        var result = coordinates
        var passes = 0
        while passes < 128 {
            passes += 1
            let points = result.map { MKMapPoint($0) }
            guard let notchRange = firstStopConnectorNotchRange(
                in: points,
                stopPoints: stopPoints,
                metersPerPoint: metersPerPoint
            ) else { break }
            result.removeSubrange(notchRange)
        }

        // A journey endpoint that is just the stop coordinate reached
        // sideways is the same artifact with no interior span to scan. A
        // connector can carry more than one baked vertex, so each end is
        // trimmed repeatedly while every gate keeps holding.
        for end in [ShapeEnd.last, .first] {
            var drops = 0
            while drops < 3, result.count >= 4 {
                let points = result.map { MKMapPoint($0) }
                guard isTerminalStopConnector(
                    in: points,
                    stopPoints: stopPoints,
                    metersPerPoint: metersPerPoint,
                    atEnd: end
                ) else { break }
                switch end {
                case .last: result.removeLast()
                case .first: result.removeFirst()
                }
                drops += 1
            }
        }
        return result
    }

    private enum ShapeEnd {
        case first
        case last
    }

    /// True when the polyline's terminal vertex is a stop coordinate reached
    /// steeply off the street line the shape was traveling — the one-segment
    /// form of a stop connector. The street line is measured from *outside*
    /// the connector, so a tail of several baked vertices cannot supply its
    /// own direction as the street. A genuine terminal turn or a stop
    /// straight down the street is kept.
    private static func isTerminalStopConnector(
        in points: [MKMapPoint],
        stopPoints: [MKMapPoint],
        metersPerPoint: Double,
        atEnd end: ShapeEnd
    ) -> Bool {
        let maximumStopDistance: CLLocationDistance = 12
        let maximumDepartureDot = 0.34  // at least 70 degrees off the street
        let maximumConnectorNeighborhood: CLLocationDistance = 25
        let maximumSkippedVertices = 8

        guard points.count >= 3 else { return false }
        let vertex: MKMapPoint
        let approach: MKMapPoint
        let approachIndex: Int
        let step: Int
        switch end {
        case .last:
            vertex = points[points.count - 1]
            approach = points[points.count - 2]
            approachIndex = points.count - 2
            step = -1
        case .first:
            vertex = points[0]
            approach = points[1]
            approachIndex = 1
            step = 1
        }
        guard stopPoints.contains(where: { stop in
            stop.distance(to: vertex) * metersPerPoint <= maximumStopDistance
        }) else { return false }

        // Walk inward past vertices within one notch depth of the terminal
        // vertex — the connector and its baked points live in that
        // neighborhood — and measure the street at the first vertex beyond
        // it, always leaving at least one vertex ahead of the baseline: a
        // short terminal stretch can sit entirely within that neighborhood.
        var baselineIndex = approachIndex
        var skippedVertices = 0
        while baselineIndex >= 0, baselineIndex < points.count,
              points[baselineIndex].distance(to: vertex) * metersPerPoint
                <= maximumConnectorNeighborhood,
              skippedVertices < maximumSkippedVertices {
            let nextIndex = baselineIndex + step
            if end == .last, nextIndex < 1 { break }
            if end == .first, nextIndex > points.count - 2 { break }
            baselineIndex = nextIndex
            skippedVertices += 1
        }
        guard baselineIndex >= 0, baselineIndex < points.count,
              let streetHeading = travelHeading(
                in: points,
                at: baselineIndex,
                backward: end == .last,
                metersPerPoint: metersPerPoint
              ),
              let departureHeading = unitHeading(from: approach, to: vertex)
        else { return false }
        let departureDot = abs(
            departureHeading.x * streetHeading.x
                + departureHeading.y * streetHeading.y
        )
        return departureDot <= maximumDepartureDot
    }

    /// Finds the first interior excursion that enters a stop connector-side
    /// and returns to the same street. All gates are true meters. The
    /// excursion is bounded by how far it travels (260 m — a sparsely
    /// sampled shape's re-entry vertex can be two hundred meters ahead) and
    /// how deep it goes (3–25 m); its apex must sit within 12 m of a trip
    /// stop. The street must continue straight: the return vertex
    /// stays within 8 m of the incoming line, the anchor within 8 m of the
    /// outgoing line, and travel keeps its heading (dot ≥ 0.9) — feed
    /// sampling noise between those vertices is tolerated, a jogged or
    /// curving street is not. Finally the excursion must reach its stop
    /// steeply (at least one leg ≥ 40° off the street), which is what
    /// separates a connector from a gradual crest that happens to peak at a
    /// stop. The 240 m chord is a backstop, not the load-bearing gate: with
    /// both span ends gated onto the street's lines, a long chord is the
    /// street itself, and a street that curves inside the span fails the
    /// depth or heading gates first. Every deletion is street-aligned by
    /// construction; redundant collinear street vertices inside a deleted
    /// span go with it, leaving the drawn line unchanged.
    private static func firstStopConnectorNotchRange(
        in points: [MKMapPoint],
        stopPoints: [MKMapPoint],
        metersPerPoint: Double
    ) -> Range<Int>? {
        let maximumNotchPathDistance: CLLocationDistance = 260
        let maximumNotchChordDistance: CLLocationDistance = 240
        let minimumNotchDepth: CLLocationDistance = 3
        let maximumNotchDepth: CLLocationDistance = 25
        let maximumStopDistance: CLLocationDistance = 12
        let maximumStreetLineOffset: CLLocationDistance = 8
        let minimumStraightThroughDot = 0.9
        let maximumLegAlongStreetDot = 0.766  // cos(40°)

        for anchorIndex in 1..<(points.count - 1) {
            guard let incomingHeading = travelHeading(
                in: points,
                at: anchorIndex,
                backward: true,
                metersPerPoint: metersPerPoint
            ) else { continue }
            var pathDistance: CLLocationDistance = 0
            for returnIndex in (anchorIndex + 1)..<(points.count - 1) {
                pathDistance += points[returnIndex - 1].distance(
                    to: points[returnIndex]
                ) * metersPerPoint
                if pathDistance > maximumNotchPathDistance { break }

                let chordDistance = points[anchorIndex].distance(
                    to: points[returnIndex]
                ) * metersPerPoint
                guard chordDistance >= 1, chordDistance <= maximumNotchChordDistance
                else { continue }

                var notchDepth: CLLocationDistance = 0
                var apexIndex = anchorIndex + 1
                for index in (anchorIndex + 1)..<returnIndex {
                    let depth = perpendicularDistance(
                        of: points[index],
                        from: points[anchorIndex],
                        to: points[returnIndex]
                    ) * metersPerPoint
                    if depth > notchDepth {
                        notchDepth = depth
                        apexIndex = index
                    }
                }
                guard notchDepth >= minimumNotchDepth,
                      notchDepth <= maximumNotchDepth
                else { continue }
                guard stopPoints.contains(where: { stop in
                    stop.distance(to: points[apexIndex]) * metersPerPoint
                        <= maximumStopDistance
                }) else { continue }

                guard let outgoingHeading = travelHeading(
                    in: points,
                    at: returnIndex,
                    backward: false,
                    metersPerPoint: metersPerPoint
                ) else { continue }

                // The street itself continues straight through the span,
                // tested against both legs: the return sits on the incoming
                // line and the anchor sits on the outgoing line. The stop
                // itself cannot qualify as the return point.
                let returnDeltaX = points[returnIndex].x - points[anchorIndex].x
                let returnDeltaY = points[returnIndex].y - points[anchorIndex].y
                guard abs(
                    returnDeltaX * incomingHeading.y
                        - returnDeltaY * incomingHeading.x
                ) * metersPerPoint <= maximumStreetLineOffset else { continue }
                guard abs(
                    returnDeltaX * outgoingHeading.y
                        - returnDeltaY * outgoingHeading.x
                ) * metersPerPoint <= maximumStreetLineOffset else { continue }
                guard incomingHeading.x * outgoingHeading.x
                    + incomingHeading.y * outgoingHeading.y
                    >= minimumStraightThroughDot
                else { continue }

                // A connector reaches its stop steeply off the street; a
                // curve's legs diverge from the chord gradually.
                guard let inboundLeg = unitHeading(
                    from: points[anchorIndex],
                    to: points[apexIndex]
                ),
                    let outboundLeg = unitHeading(
                        from: points[apexIndex],
                        to: points[returnIndex]
                    )
                else { continue }
                let inboundAlongStreet = abs(
                    inboundLeg.x * incomingHeading.x
                        + inboundLeg.y * incomingHeading.y
                )
                let outboundAlongStreet = abs(
                    outboundLeg.x * incomingHeading.x
                        + outboundLeg.y * incomingHeading.y
                )
                guard inboundAlongStreet <= maximumLegAlongStreetDot
                    || outboundAlongStreet <= maximumLegAlongStreetDot
                else { continue }

                return (anchorIndex + 1)..<returnIndex
            }
        }
        return nil
    }

    /// Direction of travel at a vertex, measured over up to three vertices
    /// and 60 meters so a single duplicated survey point or lane-shift jog
    /// cannot flip it. `backward` looks upstream, but the returned heading
    /// always points in the direction of travel.
    private static func travelHeading(
        in points: [MKMapPoint],
        at index: Int,
        backward: Bool,
        metersPerPoint: Double
    ) -> (x: Double, y: Double)? {
        let step = backward ? -1 : 1
        var farIndex = index
        var traveled: CLLocationDistance = 0
        var stepsTaken = 0
        while stepsTaken < 3 {
            let nextIndex = farIndex + step
            guard nextIndex >= 0, nextIndex < points.count else { break }
            let segment = points[farIndex].distance(to: points[nextIndex])
                * metersPerPoint
            if traveled > 0, traveled + segment > 60 { break }
            traveled += segment
            farIndex = nextIndex
            stepsTaken += 1
        }
        guard farIndex != index else { return nil }
        return backward
            ? unitHeading(from: points[farIndex], to: points[index])
            : unitHeading(from: points[index], to: points[farIndex])
    }

    /// Finds the first interior sub-path that leaves a vertex and returns to
    /// it. Returns the interior index range to delete, keeping both anchor
    /// vertices (they are a few meters apart at most, and later stages
    /// deduplicate near-coincident samples).
    private static func firstOutAndBackSpurRange(
        in coordinates: [CLLocationCoordinate2D],
        metersPerPoint: Double
    ) -> Range<Int>? {
        let points = coordinates.map { MKMapPoint($0) }
        // Below ~20 m a wobble is invisible; above ~150 m a returning path is
        // far more likely a legitimate loop around a small block.
        let minimumSpurLength: CLLocationDistance = 20
        let maximumSpurLength: CLLocationDistance = 150
        // The spur must actually leave the street it belongs to.
        let minimumSpurDepth: CLLocationDistance = 12

        for anchorIndex in 1..<(points.count - 1) {
            var spurLength: CLLocationDistance = 0
            for returnIndex in (anchorIndex + 1)..<points.count - 1 {
                spurLength += points[returnIndex - 1].distance(
                    to: points[returnIndex]
                ) * metersPerPoint
                if spurLength > maximumSpurLength { break }
                guard spurLength >= minimumSpurLength else { continue }

                // The path must come back to almost exactly where it left.
                let returnDistance = points[anchorIndex].distance(
                    to: points[returnIndex]
                ) * metersPerPoint
                guard returnDistance <= min(12, max(6, spurLength * 0.08))
                else { continue }

                // …and then continue onward in the same direction it arrived.
                // A turnaround that comes back facing the other way is real
                // service, not an artifact.
                guard let incomingHeading = unitHeading(
                    from: points[anchorIndex - 1],
                    to: points[anchorIndex]
                ),
                    let outgoingHeading = unitHeading(
                        from: points[returnIndex],
                        to: points[returnIndex + 1]
                    ),
                    incomingHeading.x * outgoingHeading.x
                        + incomingHeading.y * outgoingHeading.y >= 0.5
                else { continue }

                var spurDepth: CLLocationDistance = 0
                for index in (anchorIndex + 1)..<returnIndex {
                    spurDepth = max(
                        spurDepth,
                        perpendicularDistance(
                            of: points[index],
                            from: points[anchorIndex],
                            to: points[returnIndex]
                        ) * metersPerPoint
                    )
                }
                guard spurDepth >= minimumSpurDepth else { continue }

                return (anchorIndex + 1)..<returnIndex
            }
        }
        return nil
    }

    private static func unitHeading(
        from start: MKMapPoint,
        to end: MKMapPoint
    ) -> (x: Double, y: Double)? {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let length = hypot(deltaX, deltaY)
        guard length > 0.000_001 else { return nil }
        return (deltaX / length, deltaY / length)
    }

    private static func perpendicularDistance(
        of point: MKMapPoint,
        from start: MKMapPoint,
        to end: MKMapPoint
    ) -> Double {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let lengthSquared = deltaX * deltaX + deltaY * deltaY
        guard lengthSquared > 0 else {
            return point.distance(to: start)
        }
        let progress = max(
            0,
            min(1, ((point.x - start.x) * deltaX
                + (point.y - start.y) * deltaY) / lengthSquared)
        )
        let projection = MKMapPoint(
            x: start.x + progress * deltaX,
            y: start.y + progress * deltaY
        )
        return point.distance(to: projection)
    }

    /// Breaks a polyline wherever a consecutive jump is implausibly large, so
    /// a single bad vertex can no longer draw a line across the map.
    static func splitPolyline(
        _ coordinates: [CLLocationCoordinate2D],
        atJumpsLongerThan maximumJump: CLLocationDistance
    ) -> [[CLLocationCoordinate2D]] {
        guard let first = coordinates.first else { return [] }
        let metersPerPoint = metersPerMapPoint(atLatitude: first.latitude)

        var result: [[CLLocationCoordinate2D]] = []
        var current = [first]

        for coordinate in coordinates.dropFirst() {
            guard let previous = current.last else {
                current = [coordinate]
                continue
            }
            let distance = MKMapPoint(previous).distance(
                to: MKMapPoint(coordinate)
            ) * metersPerPoint

            if distance < 0.05 {
                continue
            } else if distance > maximumJump {
                if current.count >= 2 {
                    result.append(current)
                }
                current = [coordinate]
            } else {
                current.append(coordinate)
            }
        }

        if current.count >= 2 {
            result.append(current)
        }
        return result
    }

    /// Clips a polyline to a display radius around the origin, splitting it
    /// into the visible runs.
    static func clipPolyline(
        _ coordinates: [CLLocationCoordinate2D],
        toRadius radius: CLLocationDistance,
        around origin: CLLocationCoordinate2D
    ) -> [[CLLocationCoordinate2D]] {
        guard coordinates.count >= 2 else { return [] }

        var result: [[CLLocationCoordinate2D]] = []
        var current: [CLLocationCoordinate2D] = []

        func finishCurrentSegment() {
            if current.count >= 2 {
                result.append(current)
            }
            current = []
        }

        for index in 0..<(coordinates.count - 1) {
            guard let clipped = clipLineSegment(
                from: coordinates[index],
                to: coordinates[index + 1],
                toRadius: radius,
                around: origin
            ) else {
                finishCurrentSegment()
                continue
            }

            if let previous = current.last {
                let gap = MKMapPoint(previous).distance(
                    to: MKMapPoint(clipped.start)
                )
                if gap > 0.5 {
                    finishCurrentSegment()
                    current = [clipped.start, clipped.end]
                } else {
                    let segmentLength = MKMapPoint(previous).distance(
                        to: MKMapPoint(clipped.end)
                    )
                    if segmentLength > 0.05 {
                        current.append(clipped.end)
                    }
                }
            } else {
                current = [clipped.start, clipped.end]
            }
        }

        finishCurrentSegment()
        return result
    }

    /// Planar intersection of one line segment with the display-radius circle.
    /// Returns the portion of the segment inside the radius, if any.
    private static func clipLineSegment(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        toRadius radius: CLLocationDistance,
        around origin: CLLocationCoordinate2D
    ) -> (start: CLLocationCoordinate2D, end: CLLocationCoordinate2D)? {
        let earthRadius = 6_371_008.8
        let radiansPerDegree = Double.pi / 180
        let longitudeScale = cos(origin.latitude * radiansPerDegree)

        func localPoint(for coordinate: CLLocationCoordinate2D) -> (x: Double, y: Double) {
            var longitudeDelta = coordinate.longitude - origin.longitude
            if longitudeDelta > 180 { longitudeDelta -= 360 }
            if longitudeDelta < -180 { longitudeDelta += 360 }
            return (
                x: longitudeDelta * radiansPerDegree * earthRadius * longitudeScale,
                y: (coordinate.latitude - origin.latitude)
                    * radiansPerDegree * earthRadius
            )
        }

        let localStart = localPoint(for: start)
        let localEnd = localPoint(for: end)
        let deltaX = localEnd.x - localStart.x
        let deltaY = localEnd.y - localStart.y
        let quadraticA = deltaX * deltaX + deltaY * deltaY
        guard quadraticA > 0 else { return nil }

        let quadraticB = 2 * (localStart.x * deltaX + localStart.y * deltaY)
        let quadraticC = localStart.x * localStart.x
            + localStart.y * localStart.y
            - radius * radius
        let discriminant = quadraticB * quadraticB - 4 * quadraticA * quadraticC
        guard discriminant >= 0 else { return nil }

        let squareRoot = sqrt(discriminant)
        let firstRoot = (-quadraticB - squareRoot) / (2 * quadraticA)
        let secondRoot = (-quadraticB + squareRoot) / (2 * quadraticA)
        let lowerBound = max(0, min(firstRoot, secondRoot))
        let upperBound = min(1, max(firstRoot, secondRoot))
        guard upperBound - lowerBound > 0.000_000_001 else { return nil }

        func coordinate(at progress: Double) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(
                latitude: start.latitude
                    + (end.latitude - start.latitude) * progress,
                longitude: start.longitude
                    + (end.longitude - start.longitude) * progress
            )
        }

        return (
            start: coordinate(at: lowerBound),
            end: coordinate(at: upperBound)
        )
    }

    /// Align every downstream stop to one monotonic occurrence on the trip
    /// shape. Matching only the boarding and destination coordinates is
    /// ambiguous on a loop or repeated corridor and can select endpoints from
    /// different passes, which produces a plausible-looking but
    /// rider-impossible local diagonal.
    static func tripPath(
        in coordinateLines: [[CLLocationCoordinate2D]],
        alignedTo orderedStops: [CLLocationCoordinate2D],
        flagshipStopIndex: Int,
        options: Options = Options()
    ) -> (
        approach: [[CLLocationCoordinate2D]],
        flagship: [[CLLocationCoordinate2D]],
        continuation: [[CLLocationCoordinate2D]]
    )? {
        guard orderedStops.count >= 2,
              flagshipStopIndex > 0,
              flagshipStopIndex < orderedStops.count
        else { return nil }

        var best: (
            line: [CLLocationCoordinate2D],
            indices: [Int],
            objective: Double,
            fitScore: Double,
            maximumDistance: Double
        )?

        for rawLine in coordinateLines {
            // The trip's own stops identify the perpendicular stop-connector
            // notches baked into several feeds' shapes.
            let cleanedLine = cleanedShape(
                from: rawLine,
                nearStops: orderedStops
            )
            guard cleanedLine.count >= 2 else { continue }

            // GTFS shapes should already follow trip order, but evaluating
            // both orientations lets stop progression—not endpoint
            // proximity—decide.
            for line in [cleanedLine, Array(cleanedLine.reversed())] {
                guard let alignment = monotonicShapeAlignment(
                    stops: orderedStops,
                    line: line
                ) else { continue }
                if best.map({ alignment.objective < $0.objective }) ?? true {
                    best = (
                        line,
                        alignment.indices,
                        alignment.objective,
                        alignment.fitScore,
                        alignment.maximumDistance
                    )
                }
            }
        }

        guard let best,
              best.maximumDistance <= options.maximumShapeStopDistanceMeters,
              best.fitScore <= options.maximumShapeStopRMSMeters,
              let boardingIndex = best.indices.first,
              let finalIndex = best.indices.last
        else { return nil }
        let metersPerPoint = metersPerMapPoint(
            atLatitude: orderedStops[0].latitude
        )
        let boardingShapeDistance = MKMapPoint(orderedStops[0]).distance(
            to: MKMapPoint(best.line[boardingIndex])
        ) * metersPerPoint
        let flagshipIndex = best.indices[flagshipStopIndex]
        guard boardingShapeDistance <= options.maximumBoardingShapeDistanceMeters,
              flagshipIndex > boardingIndex,
              finalIndex >= flagshipIndex
        else { return nil }

        let approachLine = boardingIndex > 0
            ? Array(best.line[...boardingIndex]) : []
        let flagshipLine = Array(best.line[boardingIndex...flagshipIndex])
        let continuationLine = finalIndex > flagshipIndex
            ? Array(best.line[flagshipIndex...finalIndex]) : []
        let maximumJump = maximumGeometryJump(for: 3)
        let approachSegments = approachLine.count >= 2
            ? splitPolyline(approachLine, atJumpsLongerThan: maximumJump) : []
        let flagshipSegments = splitPolyline(
            flagshipLine,
            atJumpsLongerThan: maximumJump
        )
        let continuationSegments = finalIndex > flagshipIndex
            ? splitPolyline(continuationLine, atJumpsLongerThan: maximumJump) : []
        guard !flagshipSegments.isEmpty else { return nil }
        return (approachSegments, flagshipSegments, continuationSegments)
    }

    /// Dynamic programming finds the lowest-error stop-to-shape assignment
    /// while preserving stop order. Shapes with enough samples require forward
    /// progress at every stop; sparse shapes fall back to nondecreasing
    /// assignments. All distances are true meters: the objective is the sum of
    /// squared stop-to-shape errors (m²) plus one unit of shape length per
    /// meter of separation between consecutive stops, so a detour always has
    /// to pay for itself in improved stop fit.
    static func monotonicShapeAlignment(
        stops: [CLLocationCoordinate2D],
        line: [CLLocationCoordinate2D]
    ) -> (
        indices: [Int],
        objective: Double,
        fitScore: Double,
        maximumDistance: Double
    )? {
        guard stops.count >= 2, line.count >= 2 else { return nil }
        let metersPerPoint = metersPerMapPoint(atLatitude: stops[0].latitude)
        let stopPoints = stops.map { MKMapPoint($0) }
        let linePoints = line.map { MKMapPoint($0) }
        let requiresForwardProgress = linePoints.count >= stopPoints.count
        let infinity = Double.greatestFiniteMagnitude
        let progressPenalty = 1.0
        var cumulativeDistances = Array(repeating: 0.0, count: linePoints.count)
        for index in 1..<linePoints.count {
            cumulativeDistances[index] = cumulativeDistances[index - 1]
                + linePoints[index - 1].distance(to: linePoints[index])
                    * metersPerPoint
        }

        var previousCosts = linePoints.map { point -> Double in
            let distance = stopPoints[0].distance(to: point) * metersPerPoint
            return distance * distance
        }
        var backPointers = Array(
            repeating: Array(repeating: -1, count: linePoints.count),
            count: stopPoints.count
        )

        for stopIndex in 1..<stopPoints.count {
            var currentCosts = Array(repeating: infinity, count: linePoints.count)
            var bestPreviousCost = infinity
            var bestPreviousIndex = -1

            for lineIndex in linePoints.indices {
                let eligibleIndex = requiresForwardProgress
                    ? lineIndex - 1 : lineIndex
                if eligibleIndex >= 0 {
                    let adjustedCost = previousCosts[eligibleIndex]
                        - progressPenalty * cumulativeDistances[eligibleIndex]
                    if adjustedCost < bestPreviousCost {
                        bestPreviousCost = adjustedCost
                        bestPreviousIndex = eligibleIndex
                    }
                }
                guard bestPreviousIndex >= 0 else { continue }

                let distance = stopPoints[stopIndex].distance(
                    to: linePoints[lineIndex]
                ) * metersPerPoint
                currentCosts[lineIndex] = bestPreviousCost
                    + progressPenalty * cumulativeDistances[lineIndex]
                    + distance * distance
                backPointers[stopIndex][lineIndex] = bestPreviousIndex
            }
            previousCosts = currentCosts
        }

        guard let finalIndex = previousCosts.indices.min(by: {
            previousCosts[$0] < previousCosts[$1]
        }),
              previousCosts[finalIndex] < infinity
        else { return nil }

        var indices = Array(repeating: 0, count: stopPoints.count)
        indices[indices.count - 1] = finalIndex
        if indices.count > 1 {
            for stopIndex in stride(
                from: indices.count - 1,
                through: 1,
                by: -1
            ) {
                let previousIndex = backPointers[stopIndex][indices[stopIndex]]
                guard previousIndex >= 0 else { return nil }
                indices[stopIndex - 1] = previousIndex
            }
        }

        let distances = zip(stopPoints, indices).map { pair in
            pair.0.distance(to: linePoints[pair.1]) * metersPerPoint
        }
        let squaredError = distances.reduce(0) { $0 + $1 * $1 }
        return (
            indices,
            previousCosts[finalIndex],
            sqrt(squaredError / Double(distances.count)),
            distances.max() ?? infinity
        )
    }
}
