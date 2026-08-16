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

private struct JourneyBoardingOption {
    let route: TransitRoute
    let stop: TransitStop
    let sourceStopID: Int
    let walkMinutes: Int
}

private struct JourneyDepartureSelection {
    let option: JourneyBoardingOption
    let departure: APIDeparture
    let departureDate: Date
    let departureIsRealtime: Bool
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
    @Published var journeys: [RouteJourney] = []
    @Published var userCoordinate: CLLocationCoordinate2D = TransitViewModel.defaultCoordinate
    @Published var isLoading = false
    @Published var isLoadingJourneys = false
    @Published var showError = false
    @Published var errorMessage = ""

    // MARK: - Private

    private let locationManager = CLLocationManager()
    private var lastLocation: CLLocation?
    private var hasFetchedOnce = false
    /// Prevents a slower fallback request from overwriting a newer GPS fetch.
    private var activeFetchID = UUID()
    /// Full route geometry is cached so recentering does not download it again.
    private var routeCache: [Int: TransitRoute] = [:]
    /// Counts are fetched only for stops that are close enough to be duplicates.
    private var dailyDepartureCountCache: [Int: Int] = [:]

    private let apiKey = Config.transitLandAPIKey
    private let radiusMeters: Double = 804.672 // 0.5 mile
    private let routeDisplayRadiusMeters: Double = 1_207.008 // 0.75 mile
    private let duplicateStopDistanceMeters: Double = 1.524 // 5 feet
    /// Cross-agency stop coordinates can differ slightly even when they mark the
    /// same pole. Name matching keeps this deliberately small radius conservative.
    private let samePlaceStopDistanceMeters: Double = 15
    private let maximumDisplayedStops = 30
    /// Trip geometry is sampled per route so payloads stay bounded. Generated
    /// stop-to-stop shapes are discarded rather than drawn as real alignments.
    private let maximumTripGeometriesPerRoute = 12
    /// Keep the map to a glanceable set of routes a rider can actually reach.
    private let maximumVisibleJourneys = 6
    private let upcomingDepartureWindowSeconds = 10_800 // 3 hours
    private let maximumFlagshipRideMinutes = 180
    private let routeLaneSpacingPoints: Double = 5.5
    private let minimumBoardingBufferMinutes = 2
    private let walkingMetersPerMinute: Double = 80
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
        userCoordinate = coordinate
        targetRegion = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
        )
        fetchTransitData(lat: coordinate.latitude, lon: coordinate.longitude)
    }

    // MARK: - Fetch data

    func fetchTransitData(lat: Double, lon: Double) {
        let fetchID = UUID()
        activeFetchID = fetchID
        let origin = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        userCoordinate = origin
        isLoading = true
        isLoadingJourneys = false
        showError = false
        stops = []
        routes = []
        journeys = []

        Task {
            var errors: [String] = []

            do {
                // Routes depend on the final stop set, so load the filtered
                // stops first instead of downloading every route in the area.
                let fetchedStops = try await fetchStops(lat: lat, lon: lon)
                guard self.activeFetchID == fetchID else { return }
                self.stops = fetchedStops

                do {
                    let fetchedRoutes = try await fetchRoutes(
                        serving: fetchedStops,
                        near: origin
                    )
                    guard self.activeFetchID == fetchID else { return }
                    self.isLoadingJourneys = true
                    let fetchedJourneys = await fetchJourneys(
                        for: fetchedRoutes,
                        boardingAt: fetchedStops,
                        from: origin
                    )
                    guard self.activeFetchID == fetchID else { return }

                    // Only boardable journeys survive to the render model. Do
                    // not briefly publish every route in the half-mile search
                    // area while schedule details are still loading.
                    self.journeys = fetchedJourneys
                    self.routes = fetchedJourneys.map(\.route)
                    self.isLoadingJourneys = false
                } catch {
                    errors.append("Routes: \(error.localizedDescription)")
                }
            } catch {
                errors.append("Stops: \(error.localizedDescription)")
            }

            guard self.activeFetchID == fetchID else { return }
            if !errors.isEmpty {
                self.errorMessage = errors.joined(separator: "\n")
                self.showError = true
            }
            self.isLoadingJourneys = false
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
            let routeNames = routeReferences.map { route in
                TransitRouteNaming.fullDisplayName(
                    shortName: route.routeShortName,
                    longName: route.routeLongName
                )
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
                routeIDs: routeIDs,
                sourceStopIDs: [apiStop.id],
                sourceStopIDsByRoute: routeIDs.reduce(
                    into: [Int: Set<Int>]()
                ) { result, routeID in
                    result[routeID] = [apiStop.id]
                }
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
        var clusterAgencyNames = stops.map { stop in
            Set(stop.agencyNames.map(normalizedAgencyName))
        }

        func root(of index: Int) -> Int {
            var current = index
            while parents[current] != current {
                current = parents[current]
            }
            return current
        }

        // The candidate set is capped at 1,000, making this pairwise pass
        // inexpensive. Exact coordinate duplicates use the strict five-foot
        // rule. A second, conservative rule joins differently named agency
        // records only when their normalized place names and directions agree.
        for first in stops.indices {
            for second in stops.indices where second > first {
                let distance = locations[first].distance(from: locations[second])
                let isCoordinateDuplicate = distance <= duplicateStopDistanceMeters
                let isSameNamedPlace = distance <= samePlaceStopDistanceMeters
                    && representsSameNamedPlace(stops[first], stops[second])
                guard isCoordinateDuplicate || isSameNamedPlace else { continue }

                let firstRoot = root(of: first)
                let secondRoot = root(of: second)
                guard firstRoot != secondRoot else { continue }

                // A same-place cluster may contain only one record from a given
                // operator. This prevents transitive merging of two directional
                // platforms through a third agency's record.
                if !isCoordinateDuplicate,
                   !clusterAgencyNames[firstRoot].isDisjoint(
                       with: clusterAgencyNames[secondRoot]
                   ) {
                    continue
                }

                parents[secondRoot] = firstRoot
                clusterAgencyNames[firstRoot].formUnion(
                    clusterAgencyNames[secondRoot]
                )
            }
        }

        var grouped: [Int: [TransitStop]] = [:]
        for index in stops.indices {
            grouped[root(of: index), default: []].append(stops[index])
        }
        return grouped.keys.sorted().compactMap { grouped[$0] }
    }

    private func representsSameNamedPlace(
        _ first: TransitStop,
        _ second: TransitStop
    ) -> Bool {
        let firstAgencies = Set(first.agencyNames.map(normalizedAgencyName))
        let secondAgencies = Set(second.agencyNames.map(normalizedAgencyName))
        guard !firstAgencies.isEmpty,
              !secondAgencies.isEmpty,
              firstAgencies.isDisjoint(with: secondAgencies)
        else { return false }

        let firstName = normalizedStopPlaceName(first.name)
        let secondName = normalizedStopPlaceName(second.name)
        return !firstName.isEmpty
            && firstName == secondName
            && stopDirectionTerms(in: first.name) == stopDirectionTerms(in: second.name)
    }

    private func normalizedStopPlaceName(_ name: String) -> String {
        let landmarkFreeName = name.components(separatedBy: "(").first ?? name
        let foldedName = landmarkFreeName.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
        let connectorWords: Set<String> = ["at", "and", "near"]
        return foldedName
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !connectorWords.contains($0) }
            .joined(separator: " ")
    }

    private func stopDirectionTerms(in name: String) -> Set<String> {
        // Avoid ambiguous two-letter forms: "SB" often means Santa Barbara,
        // as in the landmark qualifier "(SB Library)".
        let directionWords: Set<String> = [
            "northbound", "southbound", "eastbound", "westbound",
            "inbound", "outbound",
        ]
        let foldedName = name.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
        return Set(
            foldedName
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { directionWords.contains($0) }
        )
    }

    private func normalizedAgencyName(_ name: String) -> String {
        name.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .lowercased()
        .filter { $0.isLetter || $0.isNumber }
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
            // route associations represented by records for the same place. The
            // cleanest source name is selected independently for presentation.
            let displayName = cluster.map(\.name).sorted { lhs, rhs in
                let lhsHasQualifier = lhs.contains("(")
                let rhsHasQualifier = rhs.contains("(")
                if lhsHasQualifier != rhsHasQualifier {
                    return !lhsHasQualifier
                }
                let lhsUsesWordAt = lhs.range(
                    of: " at ",
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) != nil
                let rhsUsesWordAt = rhs.range(
                    of: " at ",
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) != nil
                if lhsUsesWordAt != rhsUsesWordAt {
                    return lhsUsesWordAt
                }
                return lhs.count < rhs.count
            }.first ?? winner.name

            let sourceStopIDsByRoute = cluster.reduce(into: [Int: Set<Int>]()) {
                result, stop in
                for (routeID, sourceStopIDs) in stop.sourceStopIDsByRoute {
                    result[routeID, default: []].formUnion(sourceStopIDs)
                }
            }

            return TransitStop(
                id: winner.id,
                name: displayName,
                coordinate: winner.coordinate,
                routeNames: Array(Set(cluster.flatMap { $0.routeNames })).sorted(),
                agencyNames: Array(Set(cluster.flatMap { $0.agencyNames })).sorted(),
                routeIDs: Set(cluster.flatMap { $0.routeIDs }),
                sourceStopIDs: Set(cluster.flatMap { $0.sourceStopIDs }),
                sourceStopIDsByRoute: sourceStopIDsByRoute
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

    /// Downloads metadata and a bounded sample of trip geometry only for routes
    /// attached to displayed stops. Aggregated route geometry can join variants
    /// with artificial diagonals, so map lines come only from actual trip shapes.
    private func fetchRoutes(
        serving stops: [TransitStop],
        near origin: CLLocationCoordinate2D
    ) async throws -> [TransitRoute] {
        let requestedIDs = Set(stops.flatMap { $0.routeIDs })
        guard !requestedIDs.isEmpty else { return [] }

        let missingIDs = requestedIDs.filter { routeCache[$0] == nil }
        let requests = missingIDs.compactMap {
            routeID -> (Int, URLRequest, URLRequest)? in
            guard let routeRequest = routeRequest(for: routeID),
                  let tripRequest = tripGeometryRequest(for: routeID)
            else { return nil }
            return (routeID, routeRequest, tripRequest)
        }

        let payloads = await withTaskGroup(
            of: (Int, Data?, Data?).self
        ) { group in
            for (routeID, routeRequest, tripRequest) in requests {
                group.addTask {
                    let routePayload = try? await transitData(for: routeRequest)
                    let tripPayload = try? await transitData(for: tripRequest)
                    return (routeID, routePayload, tripPayload)
                }
            }

            var loaded: [(Int, Data?, Data?)] = []
            for await payload in group {
                loaded.append(payload)
            }
            return loaded
        }

        for (routeID, routePayload, tripPayload) in payloads {
            guard let routePayload,
                  let response = try? JSONDecoder().decode(
                      RoutesResponse.self,
                      from: routePayload
                  ),
                  let apiRoute = response.routes.first(where: { $0.id == routeID })
            else { continue }

            let trustedPolylines = tripPayload.map {
                trustedTripPolylines(from: $0)
            } ?? []
            routeCache[routeID] = makeTransitRoute(
                from: apiRoute,
                polylines: trustedPolylines
            )
        }

        let matchingRoutes = requestedIDs.compactMap { routeCache[$0] }
        if matchingRoutes.isEmpty {
            throw URLError(.resourceUnavailable)
        }

        let sortedRoutes = matchingRoutes
            .map { makeDisplayRoute(from: $0, near: origin) }
            .sorted {
                $0.fullDisplayName.localizedStandardCompare($1.fullDisplayName)
                    == .orderedAscending
            }

        // The product palette is assigned after sorting so a route keeps one
        // identity color across its line, stop badge, pin, and sheet row.
        return sortedRoutes.enumerated().map { index, route in
            TransitRoute(
                id: route.id,
                transitlandID: route.transitlandID,
                shortName: route.shortName,
                longName: route.longName,
                agencyName: route.agencyName,
                routeType: route.routeType,
                color: WayboundPalette.routeColor(at: index),
                polylines: route.polylines
            )
        }
    }

    // MARK: - Destination journeys

    /// Builds one rider-relevant, real trip from the nearest viable boarding
    /// stop for each route. Stops, schedules, headsigns, and shapes all come
    /// from Transitland; no destination inventory is embedded in the app.
    private func fetchJourneys(
        for routes: [TransitRoute],
        boardingAt stops: [TransitStop],
        from origin: CLLocationCoordinate2D
    ) async -> [RouteJourney] {
        let originLocation = CLLocation(
            latitude: origin.latitude,
            longitude: origin.longitude
        )
        var optionsByRoute: [Int: [JourneyBoardingOption]] = [:]

        for route in routes {
            let nearestStops = stops
                .filter { $0.routeIDs.contains(route.transitlandID) }
                .sorted { lhs, rhs in
                    let lhsDistance = originLocation.distance(from: CLLocation(
                        latitude: lhs.coordinate.latitude,
                        longitude: lhs.coordinate.longitude
                    ))
                    let rhsDistance = originLocation.distance(from: CLLocation(
                        latitude: rhs.coordinate.latitude,
                        longitude: rhs.coordinate.longitude
                    ))
                    return lhsDistance < rhsDistance
                }
                .prefix(3)

            for stop in nearestStops {
                let distance = originLocation.distance(from: CLLocation(
                    latitude: stop.coordinate.latitude,
                    longitude: stop.coordinate.longitude
                ))
                let walkMinutes = max(1, Int(ceil(distance / walkingMetersPerMinute)))
                for sourceStopID in stop.sourceStopIDsByRoute[route.transitlandID] ?? [] {
                    optionsByRoute[route.transitlandID, default: []].append(
                        JourneyBoardingOption(
                            route: route,
                            stop: stop,
                            sourceStopID: sourceStopID,
                            walkMinutes: walkMinutes
                        )
                    )
                }
            }
        }

        let sourceStopIDs = Set(
            optionsByRoute.values.flatMap { $0.map(\.sourceStopID) }
        )
        let departuresByStop = await fetchUpcomingDepartures(for: sourceStopIDs)
        let now = Date()
        let latestUsefulDeparture = now.addingTimeInterval(
            Double(upcomingDepartureWindowSeconds)
        )
        var selections: [JourneyDepartureSelection] = []

        for route in routes {
            var candidates: [JourneyDepartureSelection] = []
            for option in optionsByRoute[route.transitlandID] ?? [] {
                let earliestBoardableDate = now.addingTimeInterval(
                    Double(option.walkMinutes + minimumBoardingBufferMinutes) * 60
                )
                for departure in departuresByStop[option.sourceStopID] ?? [] {
                    guard departure.trip?.route?.id == route.transitlandID,
                          let event = departure.departure ?? departure.arrival,
                          let departureDate = event.effectiveDate,
                          departureDate >= earliestBoardableDate,
                          departureDate <= latestUsefulDeparture
                    else { continue }

                    candidates.append(
                        JourneyDepartureSelection(
                            option: option,
                            departure: departure,
                            departureDate: departureDate,
                            departureIsRealtime: event.isRealtime
                        )
                    )
                }
            }

            // A route can arrive at this stop in both directions. Inspect a few
            // actual trips rather than accidentally choosing a bus one stop from
            // its terminus and calling that the route's useful destination.
            var seenPatterns: Set<String> = []
            let representativeSelections = candidates
                .sorted { $0.departureDate < $1.departureDate }
                .filter { candidate in
                    guard let trip = candidate.departure.trip else { return false }
                    let pattern = "\(trip.directionID ?? -1)|\(trip.tripHeadsign ?? "")"
                    return seenPatterns.insert(pattern).inserted
                }
                .prefix(3)
            selections.append(contentsOf: representativeSelections)
        }

        let tripRequests = selections.compactMap {
            selection -> (Int, URLRequest)? in
            let routeID = selection.option.route.transitlandID
            guard let tripID = selection.departure.trip?.id,
                  let request = journeyTripRequest(
                    routeID: routeID,
                    tripID: tripID
                  )
            else { return nil }
            return (tripID, request)
        }

        let loadedTrips = await withTaskGroup(of: (Int, Data?).self) { group in
            for (tripID, request) in tripRequests {
                group.addTask {
                    (tripID, try? await transitData(for: request))
                }
            }

            var result: [Int: Data] = [:]
            for await (tripID, data) in group {
                if let data { result[tripID] = data }
            }
            return result
        }

        let journeyCandidates = selections.compactMap {
            selection -> RouteJourney? in
            guard let tripID = selection.departure.trip?.id,
                  let data = loadedTrips[tripID],
                  let response = try? JSONDecoder().decode(TripsResponse.self, from: data),
                  let trip = response.trips.first(where: { $0.id == tripID })
            else { return nil }
            return makeJourney(from: trip, selection: selection, now: now)
        }
        let candidatesByRoute = Dictionary(
            grouping: journeyCandidates,
            by: { $0.route.transitlandID }
        )
        let allJourneys = routes.compactMap { route -> RouteJourney? in
            let candidates = candidatesByRoute[route.transitlandID] ?? []
            let usefulCandidates = candidates.filter { $0.rideMinutes >= 8 }
            let pool = usefulCandidates.isEmpty ? candidates : usefulCandidates
            return pool.min {
                if $0.departureDate != $1.departureDate {
                    return $0.departureDate < $1.departureDate
                }
                return $0.totalMinutes < $1.totalMinutes
            }
        }

        // Proximity is the primary map-ranking signal. Departure time breaks
        // ties between routes boarding at the same pole or intersection.
        var journeys = Array(
            allJourneys.sorted { lhs, rhs in
                let lhsDistance = originLocation.distance(from: CLLocation(
                    latitude: lhs.boardingStop.coordinate.latitude,
                    longitude: lhs.boardingStop.coordinate.longitude
                ))
                let rhsDistance = originLocation.distance(from: CLLocation(
                    latitude: rhs.boardingStop.coordinate.latitude,
                    longitude: rhs.boardingStop.coordinate.longitude
                ))
                if abs(lhsDistance - rhsDistance) > 1 {
                    return lhsDistance < rhsDistance
                }
                if lhs.departureDate != rhs.departureDate {
                    return lhs.departureDate < rhs.departureDate
                }
                return lhs.route.fullDisplayName.localizedStandardCompare(
                    rhs.route.fullDisplayName
                ) == .orderedAscending
            }
            .prefix(maximumVisibleJourneys)
        )

        let midpoint = Double(max(0, journeys.count - 1)) / 2
        journeys = journeys.enumerated().map { index, journey in
            copy(
                journey: journey,
                laneOffsetPoints: (Double(index) - midpoint) * routeLaneSpacingPoints
            )
        }
        return journeys
    }

    private func fetchUpcomingDepartures(
        for stopIDs: Set<Int>
    ) async -> [Int: [APIDeparture]] {
        let requests = stopIDs.compactMap { stopID -> (Int, URLRequest)? in
            guard let request = upcomingDepartureRequest(for: stopID) else { return nil }
            return (stopID, request)
        }

        let payloads = await withTaskGroup(of: (Int, Data?).self) { group in
            for (stopID, request) in requests {
                group.addTask {
                    (stopID, try? await transitData(for: request))
                }
            }

            var result: [Int: Data] = [:]
            for await (stopID, data) in group {
                if let data { result[stopID] = data }
            }
            return result
        }

        return payloads.reduce(into: [Int: [APIDeparture]]()) {
            result, payload in
            let (stopID, data) = payload
            guard let response = try? JSONDecoder().decode(
                StopDeparturesResponse.self,
                from: data
            ) else {
                result[stopID] = []
                return
            }
            result[stopID] = response.stops
                .first(where: { $0.id == stopID })?
                .departures ?? []
        }
    }

    private func upcomingDepartureRequest(for stopID: Int) -> URLRequest? {
        var components = URLComponents(
            string: "https://transit.land/api/v2/rest/stops/\(stopID)/departures"
        )!
        components.queryItems = [
            URLQueryItem(name: "next", value: "\(upcomingDepartureWindowSeconds)"),
            URLQueryItem(name: "limit", value: "200"),
            URLQueryItem(name: "include_geometry", value: "false"),
            URLQueryItem(name: "include_alerts", value: "false"),
            URLQueryItem(name: "use_service_window", value: "false"),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        return request
    }

    private func journeyTripRequest(routeID: Int, tripID: Int) -> URLRequest? {
        var components = URLComponents(
            string: "https://transit.land/api/v2/rest/routes/\(routeID)/trips/\(tripID)"
        )!
        components.queryItems = [
            URLQueryItem(name: "include_geometry", value: "true"),
            URLQueryItem(name: "include_alerts", value: "false"),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        return request
    }

    private func makeJourney(
        from trip: APITrip,
        selection: JourneyDepartureSelection,
        now: Date
    ) -> RouteJourney? {
        guard let stopTimes = trip.stopTimes?.sorted(by: {
                  $0.stopSequence < $1.stopSequence
              }),
              !stopTimes.isEmpty,
              let shape = trip.shape,
              shape.generated == false,
              let geometry = shape.geometry
        else { return nil }

        let boardingIndex: Int? = {
            if let departureSequence = selection.departure.stopSequence,
               let exactIndex = stopTimes.firstIndex(where: {
                   $0.stopSequence == departureSequence
                       && $0.stop.id == selection.option.sourceStopID
               }) {
                return exactIndex
            }
            return stopTimes.firstIndex {
                $0.stop.id == selection.option.sourceStopID
            }
        }()
        guard let boardingIndex,
              let boardingServiceMinutes = TransitTime.serviceMinutes(
                from: stopTimes[boardingIndex].departureTime
                    ?? stopTimes[boardingIndex].arrivalTime
              )
        else { return nil }

        var downstream: [(stopTime: APITripStopTime, offset: Int)] = []
        for stopTime in stopTimes[boardingIndex...] {
            guard var serviceMinutes = TransitTime.serviceMinutes(
                from: stopTime.arrivalTime ?? stopTime.departureTime
            ) else { continue }
            while serviceMinutes < boardingServiceMinutes {
                serviceMinutes += 24 * 60
            }
            downstream.append((
                stopTime: stopTime,
                offset: max(0, serviceMinutes - boardingServiceMinutes)
            ))
        }
        guard downstream.count >= 2 else { return nil }

        guard let flagshipIndex = selectFlagshipIndex(
            in: downstream,
            headsign: trip.tripHeadsign
        ) else { return nil }
        let flagship = downstream[flagshipIndex]
        guard flagship.offset > 0,
              flagship.offset <= maximumFlagshipRideMinutes,
              let flagshipCoordinate = coordinate(for: flagship.stopTime.stop)
        else { return nil }

        let downstreamCoordinates = downstream.compactMap {
            coordinate(for: $0.stopTime.stop)
        }
        guard downstreamCoordinates.count == downstream.count,
              let path = tripPath(
                in: geometry.coordinateLines,
                alignedTo: downstreamCoordinates,
                flagshipStopIndex: flagshipIndex
              )
        else { return nil }

        let tripHeadsign = cleanedDestinationName(trip.tripHeadsign)
        let isFinalStop = flagshipIndex == downstream.count - 1
        let destinationName = isFinalStop
            ? (tripHeadsign ?? flagship.stopTime.stop.stopName ?? "Route destination")
            : (flagship.stopTime.stop.stopName ?? tripHeadsign ?? "Route destination")

        let journeyStops = downstream.enumerated().compactMap {
            index, item -> JourneyStop? in
            guard let coordinate = coordinate(for: item.stopTime.stop) else { return nil }
            return JourneyStop(
                id: "\(trip.id)-\(item.stopTime.stopSequence)",
                sequence: item.stopTime.stopSequence,
                name: item.stopTime.stop.stopName ?? "Unnamed stop",
                coordinate: coordinate,
                minutesFromBoarding: item.offset,
                isBoarding: index == 0,
                isFlagship: index == flagshipIndex
            )
        }
        guard journeyStops.contains(where: \.isFlagship) else { return nil }

        let departureMinutesFromNow = max(
            0,
            Int(ceil(selection.departureDate.timeIntervalSince(now) / 60))
        )
        let waitMinutes = max(
            0,
            departureMinutesFromNow - selection.option.walkMinutes
        )
        let totalMinutes = selection.option.walkMinutes + waitMinutes + flagship.offset

        return RouteJourney(
            route: selection.option.route,
            tripID: trip.id,
            boardingStop: selection.option.stop,
            sourceStopID: selection.option.sourceStopID,
            destinationName: destinationName,
            destinationCoordinate: flagshipCoordinate,
            departureDate: selection.departureDate,
            departureMinutesFromNow: departureMinutesFromNow,
            walkMinutes: selection.option.walkMinutes,
            waitMinutes: waitMinutes,
            rideMinutes: flagship.offset,
            totalMinutes: totalMinutes,
            departureIsRealtime: selection.departureIsRealtime,
            stops: journeyStops,
            flagshipPolylines: path.flagship,
            continuationPolylines: path.continuation,
            laneOffsetPoints: 0
        )
    }

    /// Prefers an official terminus/headsign, a named civic destination, or a
    /// useful medium-length ride. This is semantic scoring, not a hardcoded list
    /// of local places, so it works wherever Transitland has stop data.
    private func selectFlagshipIndex(
        in stops: [(stopTime: APITripStopTime, offset: Int)],
        headsign: String?
    ) -> Int? {
        let landmarkTerms = [
            "airport", "beach", "campus", "center", "college", "courthouse",
            "downtown", "harbor", "hospital", "library", "mall", "museum",
            "park", "station", "terminal", "transit", "university",
        ]
        let headsignTerms = (headsign ?? "")
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 }
        let finalIndex = stops.count - 1
        let eligible = stops.indices.filter {
            stops[$0].offset >= 8
                && stops[$0].offset <= maximumFlagshipRideMinutes
        }
        guard !eligible.isEmpty else { return nil }
        return eligible.max { lhs, rhs in
                func score(_ index: Int) -> Int {
                    let item = stops[index]
                    let name = (item.stopTime.stop.stopName ?? "")
                        .folding(
                            options: [.caseInsensitive, .diacriticInsensitive],
                            locale: Locale(identifier: "en_US_POSIX")
                        )
                        .lowercased()
                    let matchedHeadsignTerms = headsignTerms.filter {
                        name.contains($0)
                    }.count
                    let headsignBonus: Int
                    if !headsignTerms.isEmpty
                        && matchedHeadsignTerms == headsignTerms.count {
                        headsignBonus = 90 + matchedHeadsignTerms * 15
                    } else if matchedHeadsignTerms > 0 {
                        headsignBonus = matchedHeadsignTerms * 45
                    } else {
                        headsignBonus = 0
                    }
                    let landmarkBonus = landmarkTerms.contains {
                        name.contains($0)
                    } ? 35 : 0
                    let terminusBonus = index == finalIndex ? 45 : 0
                    let usefulRideScore = max(0, 30 - abs(item.offset - 35))
                    let progressScore = Int(
                        (Double(index) / Double(max(1, finalIndex))) * 20
                    )
                    let veryLongPenalty = max(0, item.offset - 120) / 2
                    return headsignBonus + landmarkBonus + terminusBonus
                        + usefulRideScore + progressScore - veryLongPenalty
                }
                return score(lhs) < score(rhs)
            }
    }

    private func coordinate(for stop: APITripStop) -> CLLocationCoordinate2D? {
        guard stop.geometry.coordinates.count >= 2 else { return nil }
        return CLLocationCoordinate2D(
            latitude: stop.geometry.coordinates[1],
            longitude: stop.geometry.coordinates[0]
        )
    }

    private func cleanedDestinationName(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let generic = ["inbound", "outbound", "northbound", "southbound"]
        guard !cleaned.isEmpty,
              !generic.contains(cleaned.lowercased())
        else { return nil }
        return cleaned
    }

    /// Align every downstream stop to one monotonic occurrence on the trip shape.
    /// Matching only the boarding and destination coordinates is ambiguous on a
    /// loop or repeated corridor and can select endpoints from different passes,
    /// which produces a plausible-looking but rider-impossible local diagonal.
    private func tripPath(
        in coordinateLines: [[CLLocationCoordinate2D]],
        alignedTo orderedStops: [CLLocationCoordinate2D],
        flagshipStopIndex: Int
    ) -> (flagship: [[CLLocationCoordinate2D]], continuation: [[CLLocationCoordinate2D]])? {
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

            // GTFS shapes should already follow trip order, but evaluating both
            // orientations lets stop progression—not endpoint proximity—decide.
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
              best.maximumDistance <= 500,
              best.fitScore <= 200,
              let boardingIndex = best.indices.first,
              let finalIndex = best.indices.last
        else { return nil }
        let flagshipIndex = best.indices[flagshipStopIndex]
        guard flagshipIndex > boardingIndex,
              finalIndex >= flagshipIndex
        else { return nil }

        let flagshipLine = Array(best.line[boardingIndex...flagshipIndex])
        let continuationLine = finalIndex > flagshipIndex
            ? Array(best.line[flagshipIndex...finalIndex]) : []
        let maximumJump = maximumGeometryJump(for: 3)
        let flagshipSegments = splitPolyline(
            flagshipLine,
            atJumpsLongerThan: maximumJump
        )
        let continuationSegments = continuationLine.count >= 2
            ? splitPolyline(continuationLine, atJumpsLongerThan: maximumJump) : []
        guard !flagshipSegments.isEmpty else { return nil }
        return (flagshipSegments, continuationSegments)
    }

    /// Dynamic programming finds the lowest-error stop-to-shape assignment while
    /// preserving stop order. Shapes with enough samples require forward progress
    /// at every stop; sparse shapes fall back to nondecreasing assignments.
    private func monotonicShapeAlignment(
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

    private func copy(
        journey: RouteJourney,
        laneOffsetPoints: Double
    ) -> RouteJourney {
        RouteJourney(
            route: journey.route,
            tripID: journey.tripID,
            boardingStop: journey.boardingStop,
            sourceStopID: journey.sourceStopID,
            destinationName: journey.destinationName,
            destinationCoordinate: journey.destinationCoordinate,
            departureDate: journey.departureDate,
            departureMinutesFromNow: journey.departureMinutesFromNow,
            walkMinutes: journey.walkMinutes,
            waitMinutes: journey.waitMinutes,
            rideMinutes: journey.rideMinutes,
            totalMinutes: journey.totalMinutes,
            departureIsRealtime: journey.departureIsRealtime,
            stops: journey.stops,
            flagshipPolylines: journey.flagshipPolylines,
            continuationPolylines: journey.continuationPolylines,
            laneOffsetPoints: laneOffsetPoints
        )
    }

    private func routeRequest(for routeID: Int) -> URLRequest? {
        var components = URLComponents(string: "https://transit.land/api/v2/rest/routes")!
        components.queryItems = [
            URLQueryItem(name: "id", value: "\(routeID)"),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "include_geometry", value: "false"),
            URLQueryItem(name: "include_alerts", value: "false"),
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        return request
    }

    private func tripGeometryRequest(for routeID: Int) -> URLRequest? {
        var components = URLComponents(
            string: "https://transit.land/api/v2/rest/routes/\(routeID)/trips"
        )!
        components.queryItems = [
            URLQueryItem(
                name: "limit",
                value: "\(maximumTripGeometriesPerRoute)"
            ),
            URLQueryItem(name: "include_geometry", value: "true"),
            URLQueryItem(name: "include_alerts", value: "false"),
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        return request
    }

    private func trustedTripPolylines(from data: Data) -> [[CLLocationCoordinate2D]] {
        guard let response = try? JSONDecoder().decode(TripsResponse.self, from: data)
        else { return [] }

        var seenShapeIDs: Set<String> = []
        var result: [[CLLocationCoordinate2D]] = []
        for trip in response.trips {
            guard let shape = trip.shape,
                  shape.generated == false,
                  let geometry = shape.geometry
            else { continue }

            let shapeKey = shape.shapeID ?? "trip:\(trip.id)"
            guard seenShapeIDs.insert(shapeKey).inserted else { continue }
            result.append(contentsOf: geometry.coordinateLines)
        }
        return result
    }

    private func makeDisplayRoute(
        from route: TransitRoute,
        near origin: CLLocationCoordinate2D
    ) -> TransitRoute {
        let maximumJump = maximumGeometryJump(for: route.routeType)
        let visiblePolylines: [[CLLocationCoordinate2D]] = route.polylines.flatMap {
            coordinates in
            let cleanedCoordinates = removingSinglePointSpikes(from: coordinates)
            return splitPolyline(
                cleanedCoordinates,
                atJumpsLongerThan: maximumJump
            ).flatMap {
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

    /// Removes only an unmistakable one-vertex out-and-back excursion. Broader
    /// simplification could erase a legitimate route loop, so it is avoided.
    private func removingSinglePointSpikes(
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
            let isSpike = incomingDistance > 300
                && outgoingDistance > 300
                && bypassDistance < 75
                && bypassDistance * 8 < incomingDistance + outgoingDistance

            if isSpike {
                result.remove(at: index)
                if index > 1 { index -= 1 }
            } else {
                index += 1
            }
        }
        return result
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

    private func makeTransitRoute(
        from apiRoute: APIRoute,
        polylines: [[CLLocationCoordinate2D]]
    ) -> TransitRoute {
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
            polylines: polylines
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
                userCoordinate = location.coordinate
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
