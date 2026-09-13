import CoreLocation
import Foundation
import MapKit
import WayboundCore

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

    /// Meters per unit of MKMapPoint coordinate difference. The runtime
    /// calibration above converts `MKMapPoint.distance()` — on the
    /// meter-based MapKit world of the Xcode 26 SDKs that already returns
    /// ground-true meters — but coordinate differences themselves are still
    /// Web Mercator, so a sum of x/y deltas converted with it overcounts by
    /// ~1/cos(latitude) (21% in Santa Barbara). Lane-side reads that
    /// project geometry onto a corridor normal are exactly that
    /// arithmetic; this scale, calibrated from the coordinate differences
    /// themselves, converts them. The two agree wherever
    /// `MKMapPoint.distance` is planar.
    static func planarMetersPerMapPoint(atLatitude latitude: CLLocationDegrees) -> Double {
        let origin = CLLocationCoordinate2D(latitude: latitude, longitude: 0)
        let sample = CLLocationCoordinate2D(latitude: latitude, longitude: 0.01)
        let componentDX = abs(MKMapPoint(sample).x - MKMapPoint(origin).x)
        let meterDistance = CLLocation(
            latitude: origin.latitude,
            longitude: origin.longitude
        ).distance(
            from: CLLocation(latitude: sample.latitude, longitude: sample.longitude)
        )
        guard componentDX > 0, meterDistance > 0 else {
            return 1.0 / MKMapPointsPerMeterAtLatitude(latitude)
        }
        return meterDistance / componentDX
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
        // The stage lives in WayboundCore, where the Linux CI battery
        // (NotchBatteryTests) exercises it on every push; this wrapper
        // keeps the app call sites unchanged.
        WayboundCore.NotchStage.removingStopConnectorNotches(
            coordinates.map { GeoCoordinate($0) },
            stops.map { GeoCoordinate($0) }
        ).map { $0.cl }
    }

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
