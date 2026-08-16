import Foundation
import CoreLocation
import SwiftUI
import MapKit

// MARK: - Transit Stop

struct TransitStop: Identifiable, Equatable {
    let id: Int
    let name: String
    let coordinate: CLLocationCoordinate2D
    let routeNames: [String]
    let agencyNames: [String]
    /// Transitland's internal IDs for routes that actually serve this stop.
    let routeIDs: Set<Int>
    /// A logical stop may combine several operator-specific platform records.
    let sourceStopIDs: Set<Int>
    /// Preserves the physical Transitland stop record used by each route so
    /// departure lookups do not accidentally query only the cluster winner.
    let sourceStopIDsByRoute: [Int: Set<Int>]

    static func == (lhs: TransitStop, rhs: TransitStop) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Transit Route

struct TransitRoute: Identifiable, Equatable {
    let id: String
    /// Transitland's internal ID joins this route back to nearby stops.
    let transitlandID: Int
    let shortName: String
    let longName: String
    let agencyName: String
    let routeType: Int
    let color: Color
    /// One or more non-generated trip shapes that make up the route.
    let polylines: [[CLLocationCoordinate2D]]

    /// A short route code is useful as a badge only when it contains a number.
    /// Descriptive GTFS values such as "Lompoc" and "Midday" belong in the title.
    var routeNumber: String? {
        TransitRouteNaming.routeNumber(shortName: shortName)
    }

    /// Public-facing title with split GTFS names recomposed into one phrase.
    var displayName: String {
        TransitRouteNaming.displayName(
            shortName: shortName,
            longName: longName
        )
    }

    /// Includes a useful route number when one exists (for headings and VoiceOver).
    var fullDisplayName: String {
        TransitRouteNaming.fullDisplayName(
            shortName: shortName,
            longName: longName
        )
    }

    static func == (lhs: TransitRoute, rhs: TransitRoute) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Destination journeys

struct RouteJourney: Identifiable, Equatable {
    let route: TransitRoute
    let tripID: Int
    let boardingStop: TransitStop
    let sourceStopID: Int
    let destinationName: String
    let destinationCoordinate: CLLocationCoordinate2D
    let departureDate: Date
    let departureMinutesFromNow: Int
    let walkMinutes: Int
    let waitMinutes: Int
    let rideMinutes: Int
    let totalMinutes: Int
    let departureIsRealtime: Bool
    let stops: [JourneyStop]
    /// The default map answer: actual trip shape from boarding to flagship.
    let flagshipPolylines: [[CLLocationCoordinate2D]]
    /// Any downstream shape after the flagship, used only by map-ladder mode.
    let continuationPolylines: [[CLLocationCoordinate2D]]
    /// Applied by the custom renderer in screen points, not geographic meters.
    let laneOffsetPoints: Double

    var id: Int { route.transitlandID }

    var flagshipStop: JourneyStop? {
        stops.first(where: \.isFlagship)
    }

    static func == (lhs: RouteJourney, rhs: RouteJourney) -> Bool {
        lhs.id == rhs.id && lhs.tripID == rhs.tripID
    }
}

struct JourneyStop: Identifiable, Equatable {
    let id: String
    let sequence: Int
    let name: String
    let coordinate: CLLocationCoordinate2D
    let minutesFromBoarding: Int
    let isBoarding: Bool
    let isFlagship: Bool

    static func == (lhs: JourneyStop, rhs: JourneyStop) -> Bool {
        lhs.id == rhs.id
            && lhs.minutesFromBoarding == rhs.minutesFromBoarding
            && lhs.isFlagship == rhs.isFlagship
    }
}

enum WayboundPalette {
    static let cream = Color(hex: "F4F1E7")
    static let ink = Color(hex: "24312D")
    static let routeColors: [Color] = [
        Color(hex: "C97A1E"),
        Color(hex: "1E8E77"),
        Color(hex: "D5502E"),
        Color(hex: "6E5FC4"),
    ]

    static func routeColor(at index: Int) -> Color {
        routeColors[index % routeColors.count]
    }
}

enum TransitRouteNaming {
    static func routeNumber(shortName: String?) -> String? {
        guard let shortName = cleaned(shortName),
              shortName.unicodeScalars.contains(where: {
                  CharacterSet.decimalDigits.contains($0)
              })
        else { return nil }
        return shortName
    }

    static func displayName(shortName: String?, longName: String?) -> String {
        let shortName = cleaned(shortName)
        let longName = cleaned(longName)

        if routeNumber(shortName: shortName) != nil {
            guard let longName else { return shortName ?? "Unknown Route" }
            if let shortName,
               longName.compare(shortName, options: [.caseInsensitive, .diacriticInsensitive])
                == .orderedSame {
                return shortName
            }
            return normalizedDashes(in: longName)
        }

        switch (shortName, longName) {
        case let (shortName?, longName?):
            if longName.compare(
                shortName,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame {
                return normalizedDashes(in: longName)
            }

            let continuation = longName.trimmingCharacters(
                in: CharacterSet(charactersIn: "-–— ")
            )
            let separator = longName.first.map { "-–—".contains($0) } == true
                ? " – " : " "
            return normalizedDashes(in: shortName + separator + continuation)

        case let (shortName?, nil):
            return normalizedDashes(in: shortName)
        case let (nil, longName?):
            return normalizedDashes(in: longName)
        case (nil, nil):
            return "Unknown Route"
        }
    }

    static func fullDisplayName(shortName: String?, longName: String?) -> String {
        let displayName = displayName(shortName: shortName, longName: longName)
        guard let routeNumber = routeNumber(shortName: shortName),
              displayName.compare(
                routeNumber,
                options: [.caseInsensitive, .diacriticInsensitive]
              ) != .orderedSame
        else { return displayName }
        return "\(routeNumber) — \(displayName)"
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              cleaned != "?",
              cleaned.caseInsensitiveCompare("Unknown Route") != .orderedSame
        else { return nil }
        return cleaned
    }

    private static func normalizedDashes(in value: String) -> String {
        value
            .replacingOccurrences(of: " - ", with: " – ")
            .replacingOccurrences(of: " — ", with: " – ")
    }
}

// MARK: - API Response Models (Decodable)

struct StopsResponse: Decodable {
    let stops: [APIStop]
}

struct StopDeparturesResponse: Decodable {
    let stops: [APIStopDepartures]
}

struct APIStopDepartures: Decodable {
    let id: Int
    let departures: [APIDeparture]
}

struct APIDeparture: Decodable {
    let stopSequence: Int?
    let serviceDate: String?
    let arrivalTime: String?
    let departureTime: String?
    let arrival: APIStopTimeEvent?
    let departure: APIStopTimeEvent?
    let trip: APITrip?

    enum CodingKeys: String, CodingKey {
        case stopSequence = "stop_sequence"
        case serviceDate = "service_date"
        case arrivalTime = "arrival_time"
        case departureTime = "departure_time"
        case arrival
        case departure
        case trip
    }
}

struct APIStopTimeEvent: Decodable {
    let scheduledUTC: String?
    let estimatedUTC: String?
    let scheduledLocal: String?
    let estimatedLocal: String?
    let estimatedDelay: Int?

    enum CodingKeys: String, CodingKey {
        case scheduledUTC = "scheduled_utc"
        case estimatedUTC = "estimated_utc"
        case scheduledLocal = "scheduled_local"
        case estimatedLocal = "estimated_local"
        case estimatedDelay = "estimated_delay"
    }

    var effectiveDate: Date? {
        TransitTime.date(from: estimatedUTC ?? scheduledUTC)
    }

    var isRealtime: Bool {
        estimatedUTC != nil || estimatedDelay != nil
    }
}

struct APIStop: Decodable {
    let id: Int
    let stopName: String?
    let geometry: GeoJSONPoint
    let routeStops: [APIRouteStop]?

    enum CodingKeys: String, CodingKey {
        case id
        case stopName = "stop_name"
        case geometry
        case routeStops = "route_stops"
    }
}

struct GeoJSONPoint: Decodable {
    let type: String
    let coordinates: [Double] // [lon, lat]
}

/// Transitland route geometry can be either a GeoJSON LineString or
/// MultiLineString. Normalize both forms into an array of coordinate arrays.
struct GeoJSONRouteGeometry: Decodable {
    let coordinateLines: [[CLLocationCoordinate2D]]

    private enum CodingKeys: String, CodingKey {
        case type
        case coordinates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let rawLines: [[[Double]]]

        switch type {
        case "LineString":
            rawLines = [try container.decode([[Double]].self, forKey: .coordinates)]
        case "MultiLineString":
            rawLines = try container.decode([[[Double]]].self, forKey: .coordinates)
        default:
            rawLines = []
        }

        coordinateLines = rawLines.compactMap { rawLine in
            let line = rawLine.compactMap { position -> CLLocationCoordinate2D? in
                guard position.count >= 2,
                      position[0] >= -180, position[0] <= 180,
                      position[1] >= -90, position[1] <= 90
                else { return nil }

                return CLLocationCoordinate2D(
                    latitude: position[1],
                    longitude: position[0]
                )
            }
            return line.count >= 2 ? line : nil
        }
    }
}

struct APIRouteStop: Decodable {
    let route: APIRouteRef?
}

struct APIRouteRef: Decodable {
    let id: Int?
    let routeShortName: String?
    let routeLongName: String?
    let routeType: Int?
    let routeColor: String?
    let onestopId: String?
    let agency: APIAgencyRef?

    enum CodingKeys: String, CodingKey {
        case id
        case routeShortName = "route_short_name"
        case routeLongName  = "route_long_name"
        case routeType      = "route_type"
        case routeColor     = "route_color"
        case onestopId      = "onestop_id"
        case agency
    }
}

struct APIAgencyRef: Decodable {
    let agencyName: String?

    enum CodingKeys: String, CodingKey {
        case agencyName = "agency_name"
    }
}

struct RoutesResponse: Decodable {
    let routes: [APIRoute]
}

struct TripsResponse: Decodable {
    let trips: [APITrip]
}

struct APITrip: Decodable {
    let id: Int
    let tripHeadsign: String?
    let directionID: Int?
    let route: APIRouteRef?
    let shape: APITripShape?
    let stopTimes: [APITripStopTime]?

    enum CodingKeys: String, CodingKey {
        case id
        case tripHeadsign = "trip_headsign"
        case directionID = "direction_id"
        case route
        case shape
        case stopTimes = "stop_times"
    }
}

struct APITripStopTime: Decodable {
    let arrivalTime: String?
    let departureTime: String?
    let stopSequence: Int
    let stopHeadsign: String?
    let stop: APITripStop

    enum CodingKeys: String, CodingKey {
        case arrivalTime = "arrival_time"
        case departureTime = "departure_time"
        case stopSequence = "stop_sequence"
        case stopHeadsign = "stop_headsign"
        case stop
    }
}

struct APITripStop: Decodable {
    let id: Int
    let stopName: String?
    let geometry: GeoJSONPoint

    enum CodingKeys: String, CodingKey {
        case id
        case stopName = "stop_name"
        case geometry
    }
}

struct APITripShape: Decodable {
    let shapeID: String?
    let geometry: GeoJSONRouteGeometry?
    let generated: Bool?

    enum CodingKeys: String, CodingKey {
        case shapeID = "shape_id"
        case geometry
        case generated
    }
}

struct APIRoute: Decodable {
    let id: Int
    let routeShortName: String?
    let routeLongName: String?
    let routeType: Int?
    let routeColor: String?
    let onestopId: String?
    let agency: APIAgencyRef?
    let geometry: GeoJSONRouteGeometry?

    enum CodingKeys: String, CodingKey {
        case id
        case routeShortName = "route_short_name"
        case routeLongName  = "route_long_name"
        case routeType      = "route_type"
        case routeColor     = "route_color"
        case onestopId      = "onestop_id"
        case agency
        case geometry
    }
}

// MARK: - Helpers

enum TransitTime {
    private static let internetDateTime = ISO8601DateFormatter()
    private static let fractionalInternetDateTime: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func date(from value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return fractionalInternetDateTime.date(from: value)
            ?? internetDateTime.date(from: value)
    }

    /// Converts GTFS times, including after-midnight values such as 25:10:00,
    /// into minutes from the service day's midnight.
    static func serviceMinutes(from value: String?) -> Int? {
        guard let value else { return nil }
        let components = value.split(separator: ":").compactMap { Int($0) }
        guard components.count >= 2 else { return nil }
        return components[0] * 60 + components[1]
            + (components.count > 2 && components[2] >= 30 ? 1 : 0)
    }
}

extension Color {
    /// Create a Color from a hex string like "FF5500"
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        switch hex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8)  & 0xFF) / 255
            b = Double(int         & 0xFF) / 255
        default:
            r = 0; g = 0; b = 0
        }
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - MKCoordinateRegion + Equatable
// Needed so .onChange(of: viewModel.targetRegion) compiles.

extension MKCoordinateRegion: @retroactive Equatable {
    public static func == (lhs: MKCoordinateRegion, rhs: MKCoordinateRegion) -> Bool {
        lhs.center.latitude == rhs.center.latitude
            && lhs.center.longitude == rhs.center.longitude
            && lhs.span.latitudeDelta == rhs.span.latitudeDelta
            && lhs.span.longitudeDelta == rhs.span.longitudeDelta
    }
}
