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
    /// Counts are fetched only for stops that are close enough to be duplicates.
    private var dailyDepartureCountCache: [Int: Int] = [:]

    private let apiKey = Config.transitLandAPIKey
    private let radiusMeters: Double = 804.672 // 0.5 mile
    private let routeDisplayRadiusMeters: Double = 1_207.008 // 0.75 mile
    private let duplicateStopDistanceMeters: Double = 1.524 // 5 feet
    private let maximumDisplayedStops = 30
    // Transitland's REST endpoint filters by radius but does not guarantee
    // distance ordering. Search outward in stages, then sort locally.
    private var stopSearchRadii: [Double] { [250, 500, radiusMeters] }
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
                // stops first instead of downloading every route in the area.
                let fetchedStops = try await fetchStops(lat: lat, lon: lon)
                self.stops = fetchedStops

                do {
                    self.routes = try await fetchRoutes(
                        serving: fetchedStops,
                        near: CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    )
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
        var clusters: [[TransitStop]] = []

        // Most places find 30 useful stops well before half a mile. Starting
        // small avoids downloading the full search area every time.
        for searchRadius in stopSearchRadii {
            candidates = try await fetchStopCandidates(
                lat: lat,
                lon: lon,
                radius: searchRadius
            )
            clusters = clusterNearbyStops(candidates)
            if clusters.count >= maximumDisplayedStops {
                break
            }
        }

        let origin = CLLocation(latitude: lat, longitude: lon)
        let closestClusters = clusters
            .map { cluster in
                let distance = cluster.map { stop in
                    origin.distance(from: CLLocation(
                        latitude: stop.coordinate.latitude,
                        longitude: stop.coordinate.longitude
                    ))
                }.min() ?? .greatestFiniteMagnitude
                return (cluster: cluster, distance: distance)
            }
            .sorted { $0.distance < $1.distance }
            .prefix(maximumDisplayedStops)
            .map { $0.cluster }

        // Departure queries are made only for duplicate groups that survived
        // the closest-30 selection, rather than for every candidate stop.
        let mergedStops = await mergeNearbyStopClusters(closestClusters)
        return mergedStops.sorted {
            let lhs = CLLocation(
                latitude: $0.coordinate.latitude,
                longitude: $0.coordinate.longitude
            )
            let rhs = CLLocation(
                latitude: $1.coordinate.latitude,
                longitude: $1.coordinate.longitude
            )
            return origin.distance(from: lhs) < origin.distance(from: rhs)
        }
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
            let agencyNames = routeReferences.compactMap { route -> String? in
                guard let rawAgencyName = route.agency?.agencyName else { return nil }
                let agencyName = rawAgencyName.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                return agencyName.isEmpty ? nil : agencyName
            }

            return TransitStop(
                id: apiStop.id,
                name: apiStop.stopName ?? "Unknown Stop",
                coordinate: coordinate,
                routeNames: Array(Set(routeNames)).sorted(),
                agencyNames: Array(Set(agencyNames)).sorted(),
                routeIDs: routeIDs
            )
        }
    }

    private func clusterNearbyStops(_ stops: [TransitStop]) -> [[TransitStop]] {
        guard !stops.isEmpty else { return [] }

        let locations = stops.map {
            CLLocation(
                latitude: $0.coordinate.latitude,
                longitude: $0.coordinate.longitude
            )
        }
        var parents = Array(stops.indices)

        func root(of index: Int) -> Int {
            var current = index
            while parents[current] != current {
                current = parents[current]
            }
            return current
        }

        // The candidate set is capped at 1,000, making this simple pairwise
        // clustering inexpensive while keeping the five-foot rule exact.
        for first in stops.indices {
            for second in stops.indices where second > first {
                guard locations[first].distance(from: locations[second])
                        <= duplicateStopDistanceMeters
                else { continue }

                let firstRoot = root(of: first)
                let secondRoot = root(of: second)
                if firstRoot != secondRoot {
                    parents[secondRoot] = firstRoot
                }
            }
        }

        var grouped: [Int: [TransitStop]] = [:]
        for index in stops.indices {
            grouped[root(of: index), default: []].append(stops[index])
        }
        return grouped.keys.sorted().compactMap { grouped[$0] }
    }

    private func mergeNearbyStopClusters(
        _ clusters: [[TransitStop]]
    ) async -> [TransitStop] {
        let duplicateIDs = Set(
            clusters
                .filter { $0.count > 1 }
                .flatMap { $0.map { stop in stop.id } }
        )
        let departureCounts = await fetchDailyDepartureCounts(for: duplicateIDs)

        return clusters.compactMap { cluster in
            guard let first = cluster.first else { return nil }
            guard cluster.count > 1 else { return first }

            // Departure counts are comparable only when every request in the
            // cluster succeeded. Otherwise route count is the consistent fallback.
            let hasCompleteDepartureData = cluster.allSatisfy {
                departureCounts[$0.id] != nil
            }
            let ranked = cluster.sorted { lhs, rhs in
                let lhsScore = hasCompleteDepartureData
                    ? departureCounts[lhs.id]!
                    : lhs.routeIDs.count
                let rhsScore = hasCompleteDepartureData
                    ? departureCounts[rhs.id]!
                    : rhs.routeIDs.count
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                if lhs.routeIDs.count != rhs.routeIDs.count {
                    return lhs.routeIDs.count > rhs.routeIDs.count
                }
                return lhs.id < rhs.id
            }
            guard let winner = ranked.first else { return first }

            // Keep the busiest stop's identity and coordinate, but preserve all
            // route associations represented by physically duplicate records.
            return TransitStop(
                id: winner.id,
                name: winner.name,
                coordinate: winner.coordinate,
                routeNames: Array(Set(cluster.flatMap { $0.routeNames })).sorted(),
                agencyNames: Array(Set(cluster.flatMap { $0.agencyNames })).sorted(),
                routeIDs: Set(cluster.flatMap { $0.routeIDs })
            )
        }
    }

    private func fetchDailyDepartureCounts(
        for stopIDs: Set<Int>
    ) async -> [Int: Int] {
        let missingIDs = stopIDs.filter { dailyDepartureCountCache[$0] == nil }
        let requests = missingIDs.compactMap { stopID -> (Int, URLRequest)? in
            guard let request = departureRequest(for: stopID) else { return nil }
            return (stopID, request)
        }

        let loadedCounts = await withTaskGroup(of: (Int, Int?).self) { group in
            for (stopID, request) in requests {
                group.addTask {
                    do {
                        let data = try await transitData(for: request)
                        let response = try JSONDecoder().decode(
                            StopDeparturesResponse.self,
                            from: data
                        )
                        let count = response.stops
                            .first { $0.id == stopID }?
                            .departures.count
                        return (stopID, count)
                    } catch {
                        return (stopID, nil)
                    }
                }
            }

            var counts: [(Int, Int?)] = []
            for await result in group {
                counts.append(result)
            }
            return counts
        }

        for (stopID, count) in loadedCounts {
            if let count {
                dailyDepartureCountCache[stopID] = count
            }
        }

        return stopIDs.reduce(into: [:]) { result, stopID in
            if let count = dailyDepartureCountCache[stopID] {
                result[stopID] = count
            }
        }
    }

    private func departureRequest(for stopID: Int) -> URLRequest? {
        var components = URLComponents(
            string: "https://transit.land/api/v2/rest/stops/\(stopID)/departures"
        )!
        components.queryItems = [
            URLQueryItem(name: "relative_date", value: "TODAY"),
            URLQueryItem(name: "limit", value: "1000"),
            URLQueryItem(name: "include_geometry", value: "false"),
            URLQueryItem(name: "include_alerts", value: "false"),
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        return request
    }

    /// Downloads geometry only for routes attached to the displayed stops.
    /// Individual route requests avoid receiving dozens of unrelated geometries.
    private func fetchRoutes(
        serving stops: [TransitStop],
        near origin: CLLocationCoordinate2D
    ) async throws -> [TransitRoute] {
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

        return matchingRoutes
            .map { makeDisplayRoute(from: $0, near: origin) }
            .sorted {
                $0.shortName.localizedStandardCompare($1.shortName)
                    == .orderedAscending
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

    private func makeDisplayRoute(
        from route: TransitRoute,
        near origin: CLLocationCoordinate2D
    ) -> TransitRoute {
        let maximumJump = maximumGeometryJump(for: route.routeType)
        let visiblePolylines: [[CLLocationCoordinate2D]] = route.polylines.flatMap {
            coordinates in
            splitPolyline(coordinates, atJumpsLongerThan: maximumJump).flatMap {
                clipPolyline($0, toRadius: routeDisplayRadiusMeters, around: origin)
            }
        }

        return TransitRoute(
            id: route.id,
            transitlandID: route.transitlandID,
            shortName: route.shortName,
            longName: route.longName,
            agencyName: route.agencyName,
            routeType: route.routeType,
            color: route.color,
            polylines: visiblePolylines
        )
    }

    /// Very large jumps are almost always malformed coordinates. These high
    /// thresholds intentionally favor retaining legitimate intercity service.
    private func maximumGeometryJump(for routeType: Int) -> CLLocationDistance {
        switch routeType {
        case 4: // ferry
            return 200_000
        case 2: // intercity or commuter rail
            return 100_000
        default:
            return 50_000
        }
    }

    private func splitPolyline(
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

    private func clipPolyline(
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

    private func clipLineSegment(
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

    private func makeTransitRoute(from apiRoute: APIRoute) -> TransitRoute {
        let color: Color = {
            if let hex = apiRoute.routeColor, !hex.isEmpty {
                return Color(hex: hex)
            }
            return .blue
        }()

        return TransitRoute(
            id: apiRoute.onestopId ?? "\(apiRoute.id)",
            transitlandID: apiRoute.id,
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
