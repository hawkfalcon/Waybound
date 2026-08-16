import Foundation
import Combine
import CoreLocation
import MapKit
import SwiftUI

private func transitData(for request: URLRequest) async throws -> Data {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
          (200...299).contains(httpResponse.statusCode)
    else {
        throw URLError(.badServerResponse)
    }
    return data
}

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
    /// Full route geometry is cached so recentering does not download it again.
    private var routeCache: [Int: TransitRoute] = [:]

    private let apiKey = Config.transitLandAPIKey
    private let radiusMeters: Double = 1609.34 // 1 mile
    private let maximumDisplayedStops = 30
    // Transitland's REST endpoint filters by radius but does not guarantee
    // distance ordering. Search outward in stages, then sort locally.
    private var stopSearchRadii: [Double] { [400, 800, radiusMeters] }
    private let stopCandidateLimit = 1_000

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
        showError = false
        stops = []
        routes = []

        Task {
            var errors: [String] = []

            do {
                // Routes depend on the final stop set, so load the filtered
                // stops first instead of downloading every route in a mile.
                let fetchedStops = try await fetchStops(lat: lat, lon: lon)
                self.stops = fetchedStops

                do {
                    self.routes = try await fetchRoutes(serving: fetchedStops)
                } catch {
                    errors.append("Routes: \(error.localizedDescription)")
                }
            } catch {
                errors.append("Stops: \(error.localizedDescription)")
            }

            if !errors.isEmpty {
                self.errorMessage = errors.joined(separator: "\n")
                self.showError = true
            }
            self.isLoading = false
        }
    }

    // MARK: - API Calls

    private func fetchStops(lat: Double, lon: Double) async throws -> [TransitStop] {
        var candidates: [TransitStop] = []

        // Most places find 30 useful stops well before a mile. Starting with a
        // small radius avoids downloading a full mile of stop records every time.
        for searchRadius in stopSearchRadii {
            candidates = try await fetchStopCandidates(
                lat: lat,
                lon: lon,
                radius: searchRadius
            )
            if candidates.count >= maximumDisplayedStops {
                break
            }
        }

        let origin = CLLocation(latitude: lat, longitude: lon)
        let stopsWithDistance = candidates.map { stop in
            let location = CLLocation(
                latitude: stop.coordinate.latitude,
                longitude: stop.coordinate.longitude
            )
            return (stop: stop, distance: origin.distance(from: location))
        }

        return stopsWithDistance
            .sorted { $0.distance < $1.distance }
            .prefix(maximumDisplayedStops)
            .map { $0.stop }
    }

    private func fetchStopCandidates(
        lat: Double,
        lon: Double,
        radius: Double
    ) async throws -> [TransitStop] {
        var components = URLComponents(string: "https://transit.land/api/v2/rest/stops")!
        components.queryItems = [
            URLQueryItem(name: "lat", value: "\(lat)"),
            URLQueryItem(name: "lon", value: "\(lon)"),
            URLQueryItem(name: "radius", value: "\(radius)"),
            URLQueryItem(name: "limit", value: "\(stopCandidateLimit)"),
            // Platforms are location type 0. This excludes station entrances,
            // pathways, elevators, escalators, and other internal map features.
            URLQueryItem(name: "location_type", value: "0"),
            URLQueryItem(name: "include_routes", value: "true"),
        ]
        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        let data = try await transitData(for: request)
        let response = try JSONDecoder().decode(StopsResponse.self, from: data)

        return response.stops.compactMap { apiStop -> TransitStop? in
            guard apiStop.geometry.coordinates.count >= 2 else { return nil }

            let routeReferences = apiStop.routeStops?.compactMap { $0.route } ?? []
            let routeIDs = Set(routeReferences.compactMap { $0.id })
            // A platform with no route association is not useful to a rider.
            guard !routeIDs.isEmpty else { return nil }

            let coordinate = CLLocationCoordinate2D(
                latitude: apiStop.geometry.coordinates[1],
                longitude: apiStop.geometry.coordinates[0]
            )
            let routeNames = routeReferences.compactMap { route -> String? in
                if let shortName = route.routeShortName?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !shortName.isEmpty {
                    return shortName
                }
                if let longName = route.routeLongName?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !longName.isEmpty {
                    return longName
                }
                return nil
            }

            return TransitStop(
                id: "\(apiStop.id)",
                name: apiStop.stopName ?? "Unknown Stop",
                coordinate: coordinate,
                routeNames: Array(Set(routeNames)).sorted(),
                routeIDs: routeIDs
            )
        }
    }

    /// Downloads geometry only for routes attached to the displayed stops.
    /// Individual route requests avoid receiving dozens of unrelated geometries.
    private func fetchRoutes(serving stops: [TransitStop]) async throws -> [TransitRoute] {
        let requestedIDs = Set(stops.flatMap { $0.routeIDs })
        guard !requestedIDs.isEmpty else { return [] }

        let missingIDs = requestedIDs.filter { routeCache[$0] == nil }
        let requests = missingIDs.compactMap { routeRequest(for: $0) }

        let payloads = await withTaskGroup(of: Data?.self) { group in
            for request in requests {
                group.addTask {
                    try? await transitData(for: request)
                }
            }

            var loaded: [Data] = []
            for await payload in group {
                if let payload {
                    loaded.append(payload)
                }
            }
            return loaded
        }

        for payload in payloads {
            guard let response = try? JSONDecoder().decode(RoutesResponse.self, from: payload)
            else { continue }

            for apiRoute in response.routes where requestedIDs.contains(apiRoute.id) {
                routeCache[apiRoute.id] = makeTransitRoute(from: apiRoute)
            }
        }

        let matchingRoutes = requestedIDs.compactMap { routeCache[$0] }
        if matchingRoutes.isEmpty {
            throw URLError(.resourceUnavailable)
        }

        return matchingRoutes.sorted {
            $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending
        }
    }

    private func routeRequest(for routeID: Int) -> URLRequest? {
        var components = URLComponents(string: "https://transit.land/api/v2/rest/routes")!
        components.queryItems = [
            URLQueryItem(name: "id", value: "\(routeID)"),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "include_geometry", value: "true"),
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        return request
    }

    private func makeTransitRoute(from apiRoute: APIRoute) -> TransitRoute {
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
            color: color,
            polylines: apiRoute.geometry?.coordinateLines ?? []
        )
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
