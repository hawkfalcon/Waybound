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

    /// Removes only an unmistakable one-vertex out-and-back excursion. Broader
    /// simplification could erase a legitimate route loop, so it is avoided.
    static func removingSinglePointSpikes(
        from coordinates: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count >= 3 else { return coordinates }

        var result = coordinates
        var index = 1
        while index < result.count - 1 {
            let previous = MKMapPoint(result[index - 1])
            let candidate = MKMapPoint(result[index])
            let next = MKMapPoint(result[index + 1])
            let incomingDistance = previous.distance(to: candidate)
            let outgoingDistance = candidate.distance(to: next)
            let bypassDistance = previous.distance(to: next)
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

    /// Breaks a polyline wherever a consecutive jump is implausibly large, so
    /// a single bad vertex can no longer draw a line across the map.
    static func splitPolyline(
        _ coordinates: [CLLocationCoordinate2D],
        atJumpsLongerThan maximumJump: CLLocationDistance
    ) -> [[CLLocationCoordinate2D]] {
        guard let first = coordinates.first else { return [] }

        var result: [[CLLocationCoordinate2D]] = []
        var current = [first]

        for coordinate in coordinates.dropFirst() {
            guard let previous = current.last else {
                current = [coordinate]
                continue
            }
            let distance = MKMapPoint(previous).distance(
                to: MKMapPoint(coordinate)
            )

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
            let cleanedLine = removingSinglePointSpikes(from: rawLine)
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
        let boardingShapeDistance = MKMapPoint(orderedStops[0]).distance(
            to: MKMapPoint(best.line[boardingIndex])
        )
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
    /// assignments.
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
        let stopPoints = stops.map { MKMapPoint($0) }
        let linePoints = line.map { MKMapPoint($0) }
        let requiresForwardProgress = linePoints.count >= stopPoints.count
        let infinity = Double.greatestFiniteMagnitude
        let progressPenalty = 1.0
        var cumulativeDistances = Array(repeating: 0.0, count: linePoints.count)
        for index in 1..<linePoints.count {
            cumulativeDistances[index] = cumulativeDistances[index - 1]
                + linePoints[index - 1].distance(to: linePoints[index])
        }

        var previousCosts = linePoints.map { point -> Double in
            let distance = stopPoints[0].distance(to: point)
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
                )
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
            pair.0.distance(to: linePoints[pair.1])
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
