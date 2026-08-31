import CoreLocation
import Foundation
import MapKit

/// Ranking and rider-facing deduplication for boardable journeys. Pure
/// functions over `RouteJourney` values, so overview ordering and the
/// duplicate-feed merge rules can be pinned with unit tests.
enum JourneyScoring {

    /// Frequency is deliberately local to the decision a rider is making now.
    /// Each additional catchable trip in the observation window offsets four
    /// minutes, capped so frequency never hides a very late bus.
    static let maximumFrequencyBonusMinutes = 18

    /// Two records from different feeds are the same rider-facing journey
    /// only when they board and arrive at the same places.
    static let duplicateBoardingDistanceMeters: Double = 200
    static let duplicateDestinationDistanceMeters: Double = 2_000

    /// Lower is better. Overview admission answers which useful service is
    /// easiest to board: how soon it leaves, how far the rider walks, and how
    /// often it returns. Do not penalize a route for reaching a farther
    /// flagship destination; complete walk + wait + ride timing remains intact
    /// in RouteJourney and the UI.
    static func utilityScore(
        _ journey: RouteJourney,
        observedDepartureCount: Int
    ) -> Int {
        let frequencyBonus = min(
            maximumFrequencyBonusMinutes,
            max(0, observedDepartureCount - 1) * 4
        )
        return journey.departureMinutesFromNow * 2
            + journey.walkMinutes * 3
            - frequencyBonus * 2
    }

    static func ranksAhead(
        _ lhs: RouteJourney,
        of rhs: RouteJourney,
        observedDepartureCounts: [Int: Int],
        origin: CLLocation
    ) -> Bool {
        let lhsScore = utilityScore(
            lhs,
            observedDepartureCount: observedDepartureCounts[lhs.tripID] ?? 0
        )
        let rhsScore = utilityScore(
            rhs,
            observedDepartureCount: observedDepartureCounts[rhs.tripID] ?? 0
        )
        if lhsScore != rhsScore { return lhsScore < rhsScore }
        if lhs.departureDate != rhs.departureDate {
            return lhs.departureDate < rhs.departureDate
        }

        let lhsDistance = origin.distance(from: CLLocation(
            latitude: lhs.boardingStop.coordinate.latitude,
            longitude: lhs.boardingStop.coordinate.longitude
        ))
        let rhsDistance = origin.distance(from: CLLocation(
            latitude: rhs.boardingStop.coordinate.latitude,
            longitude: rhs.boardingStop.coordinate.longitude
        ))
        if abs(lhsDistance - rhsDistance) > 1 {
            return lhsDistance < rhsDistance
        }
        if lhs.departureIsRealtime != rhs.departureIsRealtime {
            return lhs.departureIsRealtime
        }
        return lhs.route.fullDisplayName.localizedStandardCompare(
            rhs.route.fullDisplayName
        ) == .orderedAscending
    }

    /// Physical direction and endpoints, not Transitland source IDs, define
    /// whether two records are the same rider-facing journey.
    static func representsSamePublicJourney(
        _ first: RouteJourney,
        _ second: RouteJourney
    ) -> Bool {
        guard let firstNumber = first.route.routeNumber,
              let secondNumber = second.route.routeNumber,
              TransitText.normalizedIdentityText(firstNumber)
                == TransitText.normalizedIdentityText(secondNumber),
              TransitText.normalizedAgencyName(first.route.agencyName)
                == TransitText.normalizedAgencyName(second.route.agencyName)
        else { return false }

        // Opposite directions of one authoritative route are intentionally two
        // answers, even when their platforms and flagship stops are close.
        if first.route.transitlandID == second.route.transitlandID,
           let firstDirection = first.directionID,
           let secondDirection = second.directionID,
           firstDirection != secondDirection {
            return false
        }

        // A dot product below ~cos(44°) means the trips actually travel
        // different places, even when both feeds label them the same.
        if let firstVector = initialTravelVector(for: first),
           let secondVector = initialTravelVector(for: second),
           firstVector.x * secondVector.x + firstVector.y * secondVector.y < 0.72 {
            return false
        }

        // Map-point distances are projected units, not meters (~8.1 map
        // points per meter in Santa Barbara); convert before comparing with
        // the meter thresholds, or duplicate feeds never merge and the same
        // route draws twice with slightly different shapes.
        let metersPerMapPoint = TripPathGeometry.metersPerMapPoint(
            atLatitude: first.boardingStop.coordinate.latitude
        )
        let boardingDistance = MKMapPoint(first.boardingStop.coordinate).distance(
            to: MKMapPoint(second.boardingStop.coordinate)
        ) * metersPerMapPoint
        let destinationDistance = MKMapPoint(first.destinationCoordinate).distance(
            to: MKMapPoint(second.destinationCoordinate)
        ) * metersPerMapPoint
        return boardingDistance <= duplicateBoardingDistanceMeters
            && destinationDistance <= duplicateDestinationDistanceMeters
    }

    private static func initialTravelVector(
        for journey: RouteJourney
    ) -> (x: Double, y: Double)? {
        for polyline in journey.flagshipPolylines {
            guard let firstCoordinate = polyline.first else { continue }
            let first = MKMapPoint(firstCoordinate)
            for coordinate in polyline.dropFirst() {
                let next = MKMapPoint(coordinate)
                let deltaX = next.x - first.x
                let deltaY = next.y - first.y
                let length = hypot(deltaX, deltaY)
                if length > 2 {
                    return (deltaX / length, deltaY / length)
                }
            }
        }
        return nil
    }
}
