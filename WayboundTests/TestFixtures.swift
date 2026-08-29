import CoreLocation
import Foundation
import SwiftUI
@testable import Waybound

enum TestFixtures {
    static let baseLatitude = 34.4208
    static let baseLongitude = -119.7000

    static func coordinate(
        north metersNorth: Double,
        east metersEast: Double
    ) -> CLLocationCoordinate2D {
        let metersPerDegreeLatitude = 111_320.0
        let metersPerDegreeLongitude =
            111_320.0 * cos(baseLatitude * .pi / 180)
        return CLLocationCoordinate2D(
            latitude: baseLatitude + metersNorth / metersPerDegreeLatitude,
            longitude: baseLongitude + metersEast / metersPerDegreeLongitude
        )
    }

    static func makeStop(
        id: Int,
        name: String,
        agencies: [String],
        north: Double = 0,
        east: Double = 0
    ) -> TransitStop {
        let coordinate = coordinate(north: north, east: east)
        return TransitStop(
            id: id,
            name: name,
            coordinate: coordinate,
            routeNames: [],
            agencyNames: agencies,
            routeIDs: [],
            sourceStopIDs: [id],
            sourceStopIDsByRoute: [:],
            sourceStopCoordinates: [id: coordinate]
        )
    }

    static func makeRoute(
        id: String = "r6",
        transitlandID: Int = 6,
        shortName: String = "6",
        longName: String = "Pismo Beach",
        agencyName: String = "MTD (Santa Barbara)",
        color: Color = .red
    ) -> TransitRoute {
        TransitRoute(
            id: id,
            transitlandID: transitlandID,
            shortName: shortName,
            longName: longName,
            agencyName: agencyName,
            routeType: 3,
            officialColorHex: nil,
            color: color,
            polylines: []
        )
    }

    static func makeJourney(
        route: TransitRoute? = nil,
        tripID: Int,
        directionID: Int? = nil,
        boarding: CLLocationCoordinate2D? = nil,
        destination: CLLocationCoordinate2D? = nil,
        departureMinutesFromNow: Int = 10,
        walkMinutes: Int = 5,
        observedDepartureCount: Int = 1,
        flagshipPolylines: [[CLLocationCoordinate2D]] = []
    ) -> RouteJourney {
        let route = route ?? makeRoute()
        let boardingCoordinate = boarding ?? coordinate(north: 0, east: 0)
        let destinationCoordinate = destination ?? coordinate(north: 0, east: 400)
        let boardingStop = TransitStop(
            id: tripID,
            name: "Boarding",
            coordinate: boardingCoordinate,
            routeNames: [],
            agencyNames: [route.agencyName],
            routeIDs: [route.transitlandID],
            sourceStopIDs: [tripID],
            sourceStopIDsByRoute: [route.transitlandID: [tripID]],
            sourceStopCoordinates: [tripID: boardingCoordinate]
        )
        return RouteJourney(
            route: route,
            tripID: tripID,
            directionID: directionID,
            boardingStop: boardingStop,
            sourceStopID: tripID,
            destinationName: "Destination",
            destinationCoordinate: destinationCoordinate,
            departureDate: Date(timeIntervalSince1970: 1_000_000),
            departureMinutesFromNow: departureMinutesFromNow,
            observedDepartureCount: observedDepartureCount,
            walkMinutes: walkMinutes,
            waitMinutes: max(0, departureMinutesFromNow - walkMinutes),
            rideMinutes: 20,
            totalMinutes: walkMinutes
                + max(0, departureMinutesFromNow - walkMinutes)
                + 20,
            departureIsRealtime: true,
            stops: [],
            approachPolylines: [],
            flagshipPolylines: flagshipPolylines,
            continuationPolylines: []
        )
    }
}
