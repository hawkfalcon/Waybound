import Foundation
import CoreLocation
import SwiftUI
import MapKit

// MARK: - Transit Stop

struct TransitStop: Identifiable, Equatable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    let routeNames: [String]

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

    static func == (lhs: TransitRoute, rhs: TransitRoute) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - API Response Models (Decodable)

struct StopsResponse: Decodable {
    let stops: [APIStop]
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

struct APIRouteStop: Decodable {
    let route: APIRouteRef?
}

struct APIRouteRef: Decodable {
    let routeShortName: String?
    let routeLongName: String?
    let routeType: Int?
    let routeColor: String?
    let onestopId: String?
    let agency: APIAgencyRef?

    enum CodingKeys: String, CodingKey {
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
