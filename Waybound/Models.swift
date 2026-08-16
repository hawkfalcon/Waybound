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
    /// Transitland's internal IDs for routes that actually serve this stop.
    let routeIDs: Set<Int>

    static func == (lhs: TransitStop, rhs: TransitStop) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Transit Route

struct TransitRoute: Identifiable, Equatable {
    let id: String
    let shortName: String
    let longName: String
    let agencyName: String
    let routeType: Int
    let color: Color
    /// One or more GeoJSON line strings that make up the route.
    let polylines: [[CLLocationCoordinate2D]]

    static func == (lhs: TransitRoute, rhs: TransitRoute) -> Bool {
        lhs.id == rhs.id
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

/// Only the number of departures is needed when choosing between duplicate
/// stops, so individual departure payloads can be discarded while decoding.
struct APIDeparture: Decodable {
    init(from decoder: Decoder) throws {}
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
