import Foundation
import Combine
import CoreLocation
import MapKit
import SwiftUI

@MainActor
final class TransitViewModel: NSObject, ObservableObject {

    // MARK: - Default / fallback location (San Francisco)

    static let defaultCoordinate = CLLocationCoordinate2D(
        latitude: 37.7749, longitude: -122.4194
    )
    static let defaultRegion = MKCoordinateRegion(
        center: defaultCoordinate,
        span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
    )

    // MARK: - Published state

    /// Set by the ViewModel to tell the View where to move the camera.
    /// The View observes this via .onChange and updates its own @State cameraPosition.
    @Published var targetRegion: MKCoordinateRegion?
    @Published var stops: [TransitStop] = []
    @Published var routes: [TransitRoute] = []
    @Published var isLoading = false
    @Published var showError = false
    @Published var errorMessage = ""

    // MARK: - Private

    private let locationManager = CLLocationManager()
    private var lastLocation: CLLocation?
    private var hasFetchedOnce = false

    private let apiKey = Config.transitLandAPIKey
    private let radiusMeters: Double = 1609.34 // 1 mile

    // MARK: - Init

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()

        // Fetch with default location after a short delay
        // so the user sees data even before location is granted
        Task {
            try? await Task.sleep(for: .seconds(2))
            if !hasFetchedOnce {
                fetchTransitData(
                    lat: Self.defaultCoordinate.latitude,
                    lon: Self.defaultCoordinate.longitude
                )
            }
        }
    }

    // MARK: - Public

    func recenter() {
        let coordinate = lastLocation?.coordinate ?? Self.defaultCoordinate
        targetRegion = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
        )
        fetchTransitData(lat: coordinate.latitude, lon: coordinate.longitude)
    }

    // MARK: - Fetch data

    func fetchTransitData(lat: Double, lon: Double) {
        isLoading = true
        stops = []
        routes = []

        Task {
            async let stopsResult = fetchStops(lat: lat, lon: lon)
            async let routesResult = fetchRoutes(lat: lat, lon: lon)

            do {
                let (fetchedStops, fetchedRoutes) = try await (stopsResult, routesResult)
                self.stops = fetchedStops
                self.routes = fetchedRoutes
            } catch {
                self.errorMessage = error.localizedDescription
                self.showError = true
            }

            self.isLoading = false
        }
    }

    // MARK: - API Calls

    private func fetchStops(lat: Double, lon: Double) async throws -> [TransitStop] {
        var components = URLComponents(string: "https://transit.land/api/v2/rest/stops")!
        components.queryItems = [
            URLQueryItem(name: "lat", value: "\(lat)"),
            URLQueryItem(name: "lon", value: "\(lon)"),
            URLQueryItem(name: "radius", value: "\(radiusMeters)"),
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "apikey", value: apiKey),
        ]
        guard let url = components.url else { throw URLError(.badURL) }

        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(StopsResponse.self, from: data)

        return response.stops.map { apiStop in
            let coord = CLLocationCoordinate2D(
                latitude: apiStop.geometry.coordinates[1],
                longitude: apiStop.geometry.coordinates[0]
            )
            let routeNames = apiStop.routeStops?
                .compactMap { $0.route?.routeShortName ?? $0.route?.routeLongName }
                ?? []

            return TransitStop(
                id: "\(apiStop.id)",
                name: apiStop.stopName ?? "Unknown Stop",
                coordinate: coord,
                routeNames: Array(Set(routeNames)).sorted()
            )
        }
    }

    private func fetchRoutes(lat: Double, lon: Double) async throws -> [TransitRoute] {
        var components = URLComponents(string: "https://transit.land/api/v2/rest/routes")!
        components.queryItems = [
            URLQueryItem(name: "lat", value: "\(lat)"),
            URLQueryItem(name: "lon", value: "\(lon)"),
            URLQueryItem(name: "radius", value: "\(radiusMeters)"),
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "apikey", value: apiKey),
        ]
        guard let url = components.url else { throw URLError(.badURL) }

        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(RoutesResponse.self, from: data)

        return response.routes.map { apiRoute in
            let color: Color = {
                if let hex = apiRoute.routeColor, !hex.isEmpty {
                    return Color(hex: hex)
                }
                return .blue
            }()

            return TransitRoute(
                id: apiRoute.onestopId ?? "\(apiRoute.id)",
                shortName: apiRoute.routeShortName ?? "?",
                longName: apiRoute.routeLongName ?? "Unknown Route",
                agencyName: apiRoute.agency?.agencyName ?? "Unknown Agency",
                routeType: apiRoute.routeType ?? 3,
                color: color
            )
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension TransitViewModel: CLLocationManagerDelegate {

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            let isFirstFix = lastLocation == nil
            lastLocation = location

            // On first real GPS fix, pan the map and fetch data
            if isFirstFix {
                targetRegion = MKCoordinateRegion(
                    center: location.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
                )
                hasFetchedOnce = true
                fetchTransitData(
                    lat: location.coordinate.latitude,
                    lon: location.coordinate.longitude
                )
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        Task { @MainActor in
            errorMessage = "Could not get your location: \(error.localizedDescription)"
            showError = true
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(
        _ manager: CLLocationManager
    ) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            Task { @MainActor in
                errorMessage = "Location access denied. Please enable it in Settings."
                showError = true
            }
        default:
            break
        }
    }
}
