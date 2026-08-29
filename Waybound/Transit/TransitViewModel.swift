import Foundation
import Combine
import CoreLocation
import MapKit
import SwiftUI

private struct JourneyBoardingOption {
    let route: TransitRoute
    let stop: TransitStop
    let sourceStopID: Int
    let sourceCoordinate: CLLocationCoordinate2D
    let walkMinutes: Int
}

private struct JourneyDepartureSelection {
    let option: JourneyBoardingOption
    let departure: APIDeparture
    let trip: APITrip
    let departureDate: Date
    let departureIsRealtime: Bool
}

private enum JourneyDirectionIdentity: Hashable {
    case gtfs(Int)
    case destination(String)
}

private struct JourneyPatternIdentity: Hashable {
    let routeID: Int
    let direction: JourneyDirectionIdentity
    let headsign: String
}

private struct SourceRouteDirectionIdentity: Hashable {
    let routeID: Int
    let direction: JourneyDirectionIdentity
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
    /// Nil means live departures from the current moment. A value switches every
    /// schedule query and rider-facing duration to that future planning instant.
    @Published private(set) var planningDate: Date?
    /// The departure window the current overview actually answers. Usually the
    /// full three hours, narrowed to the near term when the network is busy.
    @Published private(set) var journeyWindowMinutes = 180
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
    /// Thirty clusters are normally enough for the UI, but route discovery also
    /// retains the three nearest boarding candidates for every numbered route.
    /// This prevents dense downtown records from hiding an opposite-direction
    /// platform just outside a nearest-30 prefix.
    private let minimumRetainedStopClusters = 30
    private let boardingClustersReservedPerRoute = 3
    /// Trip geometry is sampled per route so payloads stay bounded. Generated
    /// stop-to-stop shapes are discarded rather than drawn as real alignments.
    private let maximumTripGeometriesPerRoute = 12
    /// Keep up to twenty distinct numbered public routes when they are
    /// genuinely boardable. Each retained route may contribute up to two
    /// directional answers (both ways of one numbered route).
    private let maximumVisiblePublicRoutes = 20
    private let upcomingDepartureWindowSeconds = 10_800 // 3 hours
    /// A bus ride short enough that nobody would board for it. This hardens the
    /// soft "useful ride" preference already used when picking a representative
    /// trip, so the overview never surfaces block-hop trips as destinations.
    private let minimumUsefulRideMinutes = 8
    /// When many buses compete for the sheet, far-future departures turn the
    /// overview into a timetable of hours-away rides. Past this many boardable
    /// journeys only departures leaving within this window are shown.
    private let busyJourneyThreshold = 10
    private let busyDepartureWindowMinutes = 60
    /// Frequency is deliberately local to the decision a rider is making now.
    /// A route earns a utility bonus only for catchable trips in the next 90 min.
    private let frequencyObservationWindowSeconds = 5_400
    private let maximumFlagshipRideMinutes = 180
    private let minimumBoardingBufferMinutes = 2
    private let walkingMetersPerMinute: Double = 80
    // Transitland's REST endpoint filters by radius but does not guarantee
    // distance ordering, so the complete half-mile result is sorted locally.
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

    /// Changes only the schedule reference time. The current map position remains
    /// untouched while transit is reloaded for the same geographic origin.
    func setPlanningDate(_ date: Date?) {
        planningDate = date
        fetchTransitData(
            lat: userCoordinate.latitude,
            lon: userCoordinate.longitude
        )
    }

    // MARK: - Fetch data

    func fetchTransitData(lat: Double, lon: Double) {
        guard let apiKey, !apiKey.isEmpty else {
            errorMessage = "Missing TRANSITLAND_API_KEY in Secrets.plist. Add your Transitland API key, then relaunch."
            showError = true
            return
        }
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

        let selectedPlanningDate = planningDate
        let scheduleReferenceDate = selectedPlanningDate ?? Date()
        let isLiveSearch = selectedPlanningDate == nil

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
                        from: origin,
                        scheduleReferenceDate: scheduleReferenceDate,
                        isLiveSearch: isLiveSearch
                    )
                    guard self.activeFetchID == fetchID else { return }

                    // Only boardable journeys survive to the render model. Do
                    // not briefly publish every route in the half-mile search
                    // area while schedule details are still loading.
                    self.journeys = fetchedJourneys.journeys
                    self.routes = fetchedJourneys.journeys.map(\.route)
                    self.journeyWindowMinutes = fetchedJourneys.windowMinutes
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
        // Always inspect the promised half-mile boundary. Stopping after the first
        // dense 250-meter result can find an inbound route near its terminus while
        // omitting that route's useful outbound platform only one block farther on.
        let candidates = try await fetchStopCandidates(
            lat: lat,
            lon: lon,
            radius: radiusMeters
        )
        let clusters = StopClustering.cluster(stops: candidates)
        let origin = CLLocation(latitude: lat, longitude: lon)
        let rankedClusters = clusters
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

        // Preserve up to three physical boarding candidates for every numbered
        // source route before filling the ordinary nearest-30 floor. For route 11
        // downtown, this retains Transit Center as the useful UCSB-bound platform
        // even when many closer records describe only the final inbound blocks.
        var retainedIndices: Set<Int> = []
        var retainedCountByRouteID: [Int: Int] = [:]
        for (index, rankedCluster) in rankedClusters.enumerated() {
            let routeIDs = Set(
                rankedCluster.cluster.flatMap { $0.routeIDs }
            )
            for routeID in routeIDs
            where retainedCountByRouteID[routeID, default: 0]
                < boardingClustersReservedPerRoute {
                retainedIndices.insert(index)
                retainedCountByRouteID[routeID, default: 0] += 1
            }
        }
        for index in rankedClusters.indices
        where retainedIndices.count < minimumRetainedStopClusters {
            retainedIndices.insert(index)
        }
        let retainedClusters = rankedClusters.enumerated().compactMap {
            index, rankedCluster in
            retainedIndices.contains(index) ? rankedCluster.cluster : nil
        }

        // Departure-count lookups remain limited to duplicate groups that survive
        // the nearest/route-diversity selection rather than every half-mile record.
        let mergedStops = await mergeNearbyStopClusters(retainedClusters)
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
        let data = try await TransitHTTP.data(for: request)
        let response = try JSONDecoder().decode(StopsResponse.self, from: data)

        return response.stops.compactMap { apiStop -> TransitStop? in
            guard apiStop.geometry.coordinates.count >= 2 else { return nil }

            let routeReferences = (apiStop.routeStops?.compactMap { $0.route } ?? [])
                .filter {
                    TransitRouteNaming.routeNumber(shortName: $0.routeShortName) != nil
                }
            let routeIDs = Set(routeReferences.compactMap { $0.id })
            // Unnumbered records are not actionable route choices and often
            // represent feed artifacts, shuttles, or descriptive variants.
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
                },
                sourceStopCoordinates: [apiStop.id: coordinate]
            )
        }
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
                sourceStopIDsByRoute: sourceStopIDsByRoute,
                sourceStopCoordinates: cluster.reduce(
                    into: [Int: CLLocationCoordinate2D]()
                ) { result, stop in
                    for (sourceStopID, coordinate) in stop.sourceStopCoordinates {
                        result[sourceStopID] = coordinate
                    }
                }
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

        let loadedCounts = await TransitHTTP.parallel(requests) { pair in
            let stopID = pair.0
            do {
                let data = try await TransitHTTP.data(for: pair.1)
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

        let payloads = await TransitHTTP.parallel(requests) { pair in
            let routeID = pair.0
            let routePayload = try? await TransitHTTP.data(for: pair.1)
            let tripPayload = try? await TransitHTTP.data(for: pair.2)
            return (routeID, routePayload, tripPayload)
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
            .filter { $0.routeNumber != nil }
        if matchingRoutes.isEmpty {
            throw URLError(.resourceUnavailable)
        }

        let sortedRoutes = matchingRoutes
            .map { makeDisplayRoute(from: $0, near: origin) }
            .sorted {
                $0.fullDisplayName.localizedStandardCompare($1.fullDisplayName)
                    == .orderedAscending
            }

        // Preserve GTFS identity colors whenever the operator publishes one.
        // Duplicate source records for the same public route share the first
        // authoritative color by stable Transitland ID; only a genuinely
        // colorless public route uses the deterministic fallback palette.
        let officialColorsByPublicRoute = Dictionary(
            grouping: sortedRoutes,
            by: { RouteIdentity.identity(for: $0) }
        ).compactMapValues { matchingRoutes in
            matchingRoutes
                .filter { $0.officialColorHex != nil }
                .min { $0.transitlandID < $1.transitlandID }?
                .officialColorHex
        }
        return sortedRoutes.map { route in
            let officialColorHex = officialColorsByPublicRoute[
                RouteIdentity.identity(for: route)
            ]
            return TransitRoute(
                id: route.id,
                transitlandID: route.transitlandID,
                shortName: route.shortName,
                longName: route.longName,
                agencyName: route.agencyName,
                routeType: route.routeType,
                officialColorHex: officialColorHex,
                color: officialColorHex.map { Color(hex: $0) }
                    ?? RouteIdentity.stableColor(for: route),
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
        from origin: CLLocationCoordinate2D,
        scheduleReferenceDate: Date,
        isLiveSearch: Bool
    ) async -> (journeys: [RouteJourney], windowMinutes: Int) {
        let originLocation = CLLocation(
            latitude: origin.latitude,
            longitude: origin.longitude
        )
        var optionsByRoute: [Int: [JourneyBoardingOption]] = [:]

        for route in routes {
            let sourceOptions = stops
                .filter { $0.routeIDs.contains(route.transitlandID) }
                .flatMap { stop -> [JourneyBoardingOption] in
                    (stop.sourceStopIDsByRoute[route.transitlandID] ?? []).map {
                        sourceStopID in
                        let sourceCoordinate = stop.sourceStopCoordinates[sourceStopID]
                            ?? stop.coordinate
                        let distance = originLocation.distance(from: CLLocation(
                            latitude: sourceCoordinate.latitude,
                            longitude: sourceCoordinate.longitude
                        ))
                        return JourneyBoardingOption(
                            route: route,
                            stop: stop,
                            sourceStopID: sourceStopID,
                            sourceCoordinate: sourceCoordinate,
                            walkMinutes: max(
                                1,
                                Int(ceil(distance / walkingMetersPerMinute))
                            )
                        )
                    }
                }
                .sorted { lhs, rhs in
                    if lhs.walkMinutes != rhs.walkMinutes {
                        return lhs.walkMinutes < rhs.walkMinutes
                    }
                    let lhsDistance = originLocation.distance(from: CLLocation(
                        latitude: lhs.sourceCoordinate.latitude,
                        longitude: lhs.sourceCoordinate.longitude
                    ))
                    let rhsDistance = originLocation.distance(from: CLLocation(
                        latitude: rhs.sourceCoordinate.latitude,
                        longitude: rhs.sourceCoordinate.longitude
                    ))
                    if abs(lhsDistance - rhsDistance) > 1 {
                        return lhsDistance < rhsDistance
                    }
                    return lhs.sourceStopID < rhs.sourceStopID
                }

            // Stop discovery is already bounded and guarantees the three nearest
            // clusters per route. Inspect every retained physical source record:
            // distance alone cannot tell which platform serves which direction,
            // and an early prefix can discard the only catchable return trip.
            optionsByRoute[route.transitlandID] = sourceOptions
        }

        let sourceStopIDs = Set(
            optionsByRoute.values.flatMap { $0.map(\.sourceStopID) }
        )
        let departuresByStop = await fetchUpcomingDepartures(
            for: sourceStopIDs,
            scheduleReferenceDate: scheduleReferenceDate,
            isLiveSearch: isLiveSearch
        )
        let latestUsefulDeparture = scheduleReferenceDate.addingTimeInterval(
            Double(upcomingDepartureWindowSeconds)
        )
        let frequencyObservationEnd = scheduleReferenceDate.addingTimeInterval(
            Double(frequencyObservationWindowSeconds)
        )
        var selections: [JourneyDepartureSelection] = []
        var patternIdentityByTripID: [Int: JourneyPatternIdentity] = [:]
        var catchableTripIDsByPattern: [JourneyPatternIdentity: Set<Int>] = [:]

        for route in routes {
            var candidates: [JourneyDepartureSelection] = []
            for option in optionsByRoute[route.transitlandID] ?? [] {
                let earliestBoardableDate = scheduleReferenceDate.addingTimeInterval(
                    Double(option.walkMinutes + minimumBoardingBufferMinutes) * 60
                )
                for departure in departuresByStop[option.sourceStopID] ?? [] {
                    guard let trip = departure.trip,
                          trip.route?.id == route.transitlandID,
                          let event = departure.departure ?? departure.arrival,
                          let departureDate = riderFacingDepartureDate(
                              for: event,
                              scheduleReferenceDate: scheduleReferenceDate,
                              isLiveSearch: isLiveSearch
                          ),
                          departureDate >= earliestBoardableDate,
                          departureDate <= latestUsefulDeparture
                    else { continue }

                    let patternIdentity = journeyPatternIdentity(
                        routeID: route.transitlandID,
                        trip: trip
                    )
                    patternIdentityByTripID[trip.id] = patternIdentity
                    if departureDate <= frequencyObservationEnd {
                        catchableTripIDsByPattern[patternIdentity, default: []].insert(trip.id)
                    }
                    candidates.append(
                        JourneyDepartureSelection(
                            option: option,
                            departure: departure,
                            trip: trip,
                            departureDate: departureDate,
                            departureIsRealtime: isLiveSearch && event.isRealtime
                        )
                    )
                }
            }

            // A route can arrive in both directions and can expose the same trip
            // at several nearby stops. Pick the physically closest catchable stop
            // within each direction/headsign pattern—not merely the stop where the
            // vehicle happens to depart earliest along its run.
            let candidatesByPattern = Dictionary(
                grouping: candidates,
                by: { candidate in
                    journeyPatternIdentity(
                        routeID: route.transitlandID,
                        trip: candidate.trip
                    )
                }
            )
            let patternRepresentatives = candidatesByPattern.values
                .compactMap { patternCandidates in
                    patternCandidates.min { lhs, rhs in
                        let lhsDistance = originLocation.distance(from: CLLocation(
                            latitude: lhs.option.sourceCoordinate.latitude,
                            longitude: lhs.option.sourceCoordinate.longitude
                        ))
                        let rhsDistance = originLocation.distance(from: CLLocation(
                            latitude: rhs.option.sourceCoordinate.latitude,
                            longitude: rhs.option.sourceCoordinate.longitude
                        ))
                        if abs(lhsDistance - rhsDistance) > 1 {
                            return lhsDistance < rhsDistance
                        }
                        if lhs.departureDate != rhs.departureDate {
                            return lhs.departureDate < rhs.departureDate
                        }
                        if lhs.departureIsRealtime != rhs.departureIsRealtime {
                            return lhs.departureIsRealtime
                        }
                        return lhs.option.sourceStopID < rhs.option.sourceStopID
                    }
                }

            // Reserve one trip-detail request for every observed direction before
            // using the third request as a fallback. A simple earliest-three prefix
            // can spend all requests on outbound headsign variants and make the
            // inbound half of routes such as 6 or 11 disappear.
            let representativesByDirection = Dictionary(
                grouping: patternRepresentatives,
                by: { journeyDirectionIdentity(for: $0.trip) }
            )
            var representativeSelections = representativesByDirection.values
                .compactMap { $0.min(by: { $0.departureDate < $1.departureDate }) }
                .sorted { $0.departureDate < $1.departureDate }
                .prefix(3)
                .map { $0 }
            let selectedTripIDs = Set(
                representativeSelections.map(\.trip.id)
            )
            let fallbackSelections = patternRepresentatives
                .filter { representative in
                    !selectedTripIDs.contains(representative.trip.id)
                }
                .sorted { $0.departureDate < $1.departureDate }
                .prefix(max(0, 3 - representativeSelections.count))
            representativeSelections.append(contentsOf: fallbackSelections)
            selections.append(contentsOf: representativeSelections)
        }

        let tripRequests = selections.compactMap {
            selection -> (Int, URLRequest)? in
            let routeID = selection.option.route.transitlandID
            let tripID = selection.trip.id
            guard let request = journeyTripRequest(
                routeID: routeID,
                tripID: tripID
            ) else { return nil }
            return (tripID, request)
        }

        let tripPayloads = await TransitHTTP.parallel(tripRequests) { pair in
            (pair.0, try? await TransitHTTP.data(for: pair.1))
        }
        let loadedTrips = tripPayloads.reduce(into: [Int: Data]()) { result, item in
            if let data = item.1 { result[item.0] = data }
        }

        let observedDepartureCountByTripID = patternIdentityByTripID.reduce(
            into: [Int: Int]()
        ) { result, item in
            result[item.key] = catchableTripIDsByPattern[item.value]?.count ?? 0
        }
        let journeyCandidates = selections.compactMap {
            selection -> RouteJourney? in
            let tripID = selection.trip.id
            guard let data = loadedTrips[tripID],
                  let response = try? JSONDecoder().decode(TripsResponse.self, from: data),
                  let trip = response.trips.first(where: { $0.id == tripID })
            else { return nil }
            return makeJourney(
                from: trip,
                selection: selection,
                scheduleReferenceDate: scheduleReferenceDate,
                observedDepartureCount: observedDepartureCountByTripID[tripID] ?? 0
            )
        }
        // Keep one useful trip for each direction of each source route. Collapsing
        // here by route ID alone hid the return direction of ordinary two-way
        // service and made numbered routes such as 6 and 11 less discoverable.
        let candidatesByDirection = Dictionary(
            grouping: journeyCandidates,
            by: { journey in
                SourceRouteDirectionIdentity(
                    routeID: journey.route.transitlandID,
                    direction: journeyDirectionIdentity(for: journey)
                )
            }
        )
        let directionalJourneys = candidatesByDirection.values.compactMap {
            candidates -> RouteJourney? in
            let usefulCandidates = candidates.filter { $0.rideMinutes >= 8 }
            let pool = usefulCandidates.isEmpty ? candidates : usefulCandidates
            return pool.min {
                JourneyScoring.ranksAhead(
                    $0,
                    of: $1,
                    observedDepartureCounts: observedDepartureCountByTripID,
                    origin: originLocation
                )
            }
        }

        // Rank before deduplication so duplicate feeds keep the more useful live
        // departure. Physical direction and endpoints, not Transitland source IDs,
        // define whether two records are the same rider-facing journey.
        let utilityOrderedJourneys = directionalJourneys.sorted {
            JourneyScoring.ranksAhead(
                $0,
                of: $1,
                observedDepartureCounts: observedDepartureCountByTripID,
                origin: originLocation
            )
        }
        var logicalJourneys: [RouteJourney] = []
        for candidate in utilityOrderedJourneys {
            guard !logicalJourneys.contains(where: {
                JourneyScoring.representsSamePublicJourney($0, candidate)
            }) else { continue }
            logicalJourneys.append(candidate)
        }

        // The map budget counts numbered public routes, not directions. Operator
        // identity keeps unrelated services with the same badge separate. Retain
        // up to two directional answers per route, keep both directions adjacent
        // in the compact sheet, and admit routes until the budget is full.
        var retainedRouteKeys: [PublicRouteIdentity] = []
        var journeysByRouteKey: [PublicRouteIdentity: [RouteJourney]] = [:]
        var directionKeysByRouteKey: [
            PublicRouteIdentity: Set<JourneyDirectionIdentity>
        ] = [:]
        for candidate in logicalJourneys {
            guard candidate.route.routeNumber != nil else { continue }
            let routeKey = RouteIdentity.identity(for: candidate.route)
            guard routeKey.isUsable else { continue }
            let directionKey = journeyDirectionIdentity(for: candidate)

            if journeysByRouteKey[routeKey] == nil {
                guard retainedRouteKeys.count < maximumVisiblePublicRoutes else {
                    continue
                }
                retainedRouteKeys.append(routeKey)
            }
            guard journeysByRouteKey[routeKey, default: []].count < 2,
                  directionKeysByRouteKey[routeKey, default: []]
                    .insert(directionKey).inserted
            else { continue }
            journeysByRouteKey[routeKey, default: []].append(candidate)
        }
        let filtered = filteredJourneys(
            retainedRouteKeys.flatMap { journeysByRouteKey[$0] ?? [] }
        )
        return (filtered.journeys, filtered.windowMinutes)
    }

    /// Rider-facing filtering applied to the final boardable journey set.
    /// 1. Drop rides too short for anyone to bother boarding a bus.
    /// 2. When the network is busy enough to crowd the sheet (>10 journeys),
    ///    narrow it to only departures leaving within the near-term window so
    ///    it reads as choices, not a full timetable. Quiet areas keep every
    ///    far-future bus, because that is the rider's only option there.
    /// The reported window must match the filter actually applied, because the
    /// UI promises it ("no boardable trip in the next 3 hours").
    private func filteredJourneys(
        _ journeys: [RouteJourney]
    ) -> (journeys: [RouteJourney], windowMinutes: Int) {
        let substantiveRides = journeys.filter {
            $0.rideMinutes >= minimumUsefulRideMinutes
        }
        guard substantiveRides.count > busyJourneyThreshold else {
            return (substantiveRides, upcomingDepartureWindowSeconds / 60)
        }
        return (
            substantiveRides.filter {
                $0.departureMinutesFromNow <= busyDepartureWindowMinutes
            },
            busyDepartureWindowMinutes
        )
    }

    private func journeyDirectionIdentity(
        directionID: Int?,
        destination: String?
    ) -> JourneyDirectionIdentity {
        if let directionID { return .gtfs(directionID) }
        return .destination(TransitText.normalizedIdentityText(destination ?? ""))
    }

    private func journeyDirectionIdentity(
        for trip: APITrip
    ) -> JourneyDirectionIdentity {
        journeyDirectionIdentity(
            directionID: trip.directionID,
            destination: trip.tripHeadsign
        )
    }

    private func journeyDirectionIdentity(
        for journey: RouteJourney
    ) -> JourneyDirectionIdentity {
        journeyDirectionIdentity(
            directionID: journey.directionID,
            destination: journey.destinationName
        )
    }

    private func journeyPatternIdentity(
        routeID: Int,
        trip: APITrip
    ) -> JourneyPatternIdentity {
        JourneyPatternIdentity(
            routeID: routeID,
            direction: journeyDirectionIdentity(for: trip),
            headsign: TransitText.normalizedIdentityText(trip.tripHeadsign ?? "")
        )
    }

    /// Transitland's service-window fallback returns a trip from its representative
    /// service week, including that older week's timestamps. For a future preview,
    /// preserve the returned local wall-clock time but place it on the date the
    /// rider selected; otherwise the normal eligibility filter rejects the fallback
    /// as a bus that departed days ago.
    private func riderFacingDepartureDate(
        for event: APIStopTimeEvent,
        scheduleReferenceDate: Date,
        isLiveSearch: Bool
    ) -> Date? {
        guard !isLiveSearch else { return event.effectiveDate }
        guard let sourceDate = event.scheduledDate ?? event.effectiveDate else {
            return nil
        }

        let calendar = Calendar.autoupdatingCurrent
        let components: (hour: Int, minute: Int, second: Int)
        if let localComponents = localClockComponents(from: event.scheduledLocal) {
            components = localComponents
        } else {
            let dateComponents = calendar.dateComponents(
                [.hour, .minute, .second],
                from: sourceDate
            )
            guard let hour = dateComponents.hour,
                  let minute = dateComponents.minute
            else { return nil }
            components = (hour, minute, dateComponents.second ?? 0)
        }

        return calendar.date(
            bySettingHour: components.hour,
            minute: components.minute,
            second: components.second,
            of: scheduleReferenceDate
        )
    }

    private func localClockComponents(
        from localTimestamp: String?
    ) -> (hour: Int, minute: Int, second: Int)? {
        guard let localTimestamp, !localTimestamp.isEmpty else { return nil }
        let clockText = localTimestamp.split(separator: "T").last
            ?? Substring(localTimestamp)
        let parts = clockText.split(separator: ":", maxSplits: 2)
        guard parts.count >= 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute)
        else { return nil }
        let secondDigits = parts.count > 2
            ? parts[2].prefix { $0.isNumber } : Substring("0")
        let second = Int(secondDigits) ?? 0
        return (hour, minute, min(max(second, 0), 59))
    }

    private func fetchUpcomingDepartures(
        for stopIDs: Set<Int>,
        scheduleReferenceDate: Date,
        isLiveSearch: Bool
    ) async -> [Int: [APIDeparture]] {
        let requests = stopIDs.compactMap { stopID -> (Int, URLRequest)? in
            guard let request = upcomingDepartureRequest(
                for: stopID,
                scheduleReferenceDate: scheduleReferenceDate,
                isLiveSearch: isLiveSearch
            ) else { return nil }
            return (stopID, request)
        }

        let payloads = await TransitHTTP.parallel(requests) { pair in
            (pair.0, try? await TransitHTTP.data(for: pair.1))
        }

        return payloads.reduce(into: [Int: [APIDeparture]]()) {
            result, payload in
            let (stopID, data) = payload
            guard let data,
                  let response = try? JSONDecoder().decode(
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

    private func upcomingDepartureRequest(
        for stopID: Int,
        scheduleReferenceDate: Date,
        isLiveSearch: Bool
    ) -> URLRequest? {
        var components = URLComponents(
            string: "https://transit.land/api/v2/rest/stops/\(stopID)/departures"
        )!
        var queryItems = [
            URLQueryItem(name: "limit", value: "200"),
            URLQueryItem(name: "include_geometry", value: "false"),
            URLQueryItem(name: "include_alerts", value: "false"),
            // A future agency feed can be published before Transitland promotes
            // it to the active version. In that brief boundary, allow the API's
            // matching-week fallback rather than dropping that agency entirely.
            // Dates covered by the active feed still use their exact schedule.
            URLQueryItem(
                name: "use_service_window",
                value: isLiveSearch ? "false" : "true"
            ),
        ]

        if isLiveSearch {
            queryItems.insert(
                URLQueryItem(
                    name: "next",
                    value: "\(upcomingDepartureWindowSeconds)"
                ),
                at: 0
            )
        } else {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .autoupdatingCurrent
            let requestedEnd = scheduleReferenceDate.addingTimeInterval(
                Double(upcomingDepartureWindowSeconds)
            )
            let nextDay = calendar.date(
                byAdding: .day,
                value: 1,
                to: calendar.startOfDay(for: scheduleReferenceDate)
            ) ?? requestedEnd
            let endOfServiceDate = nextDay.addingTimeInterval(-1)
            let scheduleEndDate = min(requestedEnd, endOfServiceDate)

            let dateFormatter = DateFormatter()
            dateFormatter.calendar = calendar
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            dateFormatter.timeZone = calendar.timeZone
            dateFormatter.dateFormat = "yyyy-MM-dd"

            let timeFormatter = DateFormatter()
            timeFormatter.calendar = calendar
            timeFormatter.locale = Locale(identifier: "en_US_POSIX")
            timeFormatter.timeZone = calendar.timeZone
            timeFormatter.dateFormat = "HH:mm:ss"

            queryItems.insert(contentsOf: [
                URLQueryItem(
                    name: "date",
                    value: dateFormatter.string(from: scheduleReferenceDate)
                ),
                URLQueryItem(
                    name: "start_time",
                    value: timeFormatter.string(from: scheduleReferenceDate)
                ),
                URLQueryItem(
                    name: "end_time",
                    value: timeFormatter.string(from: scheduleEndDate)
                ),
            ], at: 0)
        }

        components.queryItems = queryItems
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
        scheduleReferenceDate: Date,
        observedDepartureCount: Int
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

        guard let flagshipIndex = FlagshipSelection.selectIndex(
            in: downstream,
            headsign: trip.tripHeadsign,
            maximumRideMinutes: maximumFlagshipRideMinutes
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
              let path = TripPathGeometry.tripPath(
                in: geometry.coordinateLines,
                alignedTo: downstreamCoordinates,
                flagshipStopIndex: flagshipIndex
              )
        else { return nil }

        let tripHeadsign = FlagshipSelection.cleanedName(trip.tripHeadsign)
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
            Int(ceil(
                selection.departureDate.timeIntervalSince(scheduleReferenceDate) / 60
            ))
        )
        let waitMinutes = max(
            0,
            departureMinutesFromNow - selection.option.walkMinutes
        )
        let totalMinutes = selection.option.walkMinutes + waitMinutes + flagship.offset
        let exactBoardingCoordinate = coordinate(for: stopTimes[boardingIndex].stop)
            ?? selection.option.sourceCoordinate
        let logicalStop = selection.option.stop
        let routeBoardingStop = TransitStop(
            id: logicalStop.id,
            name: logicalStop.name,
            coordinate: exactBoardingCoordinate,
            routeNames: logicalStop.routeNames,
            agencyNames: logicalStop.agencyNames,
            routeIDs: logicalStop.routeIDs,
            sourceStopIDs: logicalStop.sourceStopIDs,
            sourceStopIDsByRoute: logicalStop.sourceStopIDsByRoute,
            sourceStopCoordinates: logicalStop.sourceStopCoordinates
        )

        return RouteJourney(
            route: selection.option.route,
            tripID: trip.id,
            directionID: trip.directionID,
            boardingStop: routeBoardingStop,
            sourceStopID: selection.option.sourceStopID,
            destinationName: destinationName,
            destinationCoordinate: flagshipCoordinate,
            departureDate: selection.departureDate,
            departureMinutesFromNow: departureMinutesFromNow,
            observedDepartureCount: observedDepartureCount,
            walkMinutes: selection.option.walkMinutes,
            waitMinutes: waitMinutes,
            rideMinutes: flagship.offset,
            totalMinutes: totalMinutes,
            departureIsRealtime: selection.departureIsRealtime,
            stops: journeyStops,
            approachPolylines: path.approach,
            flagshipPolylines: path.flagship,
            continuationPolylines: path.continuation
        )
    }

    private func coordinate(for stop: APITripStop) -> CLLocationCoordinate2D? {
        guard stop.geometry.coordinates.count >= 2 else { return nil }
        return CLLocationCoordinate2D(
            latitude: stop.geometry.coordinates[1],
            longitude: stop.geometry.coordinates[0]
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
        let maximumJump = TripPathGeometry.maximumGeometryJump(for: route.routeType)
        let visiblePolylines: [[CLLocationCoordinate2D]] = route.polylines.flatMap {
            coordinates in
            let cleanedCoordinates = TripPathGeometry.cleanedShape(from: coordinates)
            return TripPathGeometry.splitPolyline(
                cleanedCoordinates,
                atJumpsLongerThan: maximumJump
            ).flatMap {
                TripPathGeometry.clipPolyline($0, toRadius: routeDisplayRadiusMeters, around: origin)
            }
        }

        return TransitRoute(
            id: route.id,
            transitlandID: route.transitlandID,
            shortName: route.shortName,
            longName: route.longName,
            agencyName: route.agencyName,
            routeType: route.routeType,
            officialColorHex: route.officialColorHex,
            color: route.color,
            polylines: visiblePolylines
        )
    }

    private func makeTransitRoute(
        from apiRoute: APIRoute,
        polylines: [[CLLocationCoordinate2D]]
    ) -> TransitRoute {
        let officialColorHex: String? = {
            guard let raw = apiRoute.routeColor else { return nil }
            let cleaned = raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            guard cleaned.count == 6,
                  UInt64(cleaned, radix: 16) != nil
            else { return nil }
            return cleaned.uppercased()
        }()

        return TransitRoute(
            id: apiRoute.onestopId ?? "\(apiRoute.id)",
            transitlandID: apiRoute.id,
            shortName: apiRoute.routeShortName ?? "?",
            longName: apiRoute.routeLongName ?? "Unknown Route",
            agencyName: apiRoute.agency?.agencyName ?? "Unknown Agency",
            routeType: apiRoute.routeType ?? 3,
            officialColorHex: officialColorHex,
            color: officialColorHex.map { Color(hex: $0) } ?? .blue,
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
