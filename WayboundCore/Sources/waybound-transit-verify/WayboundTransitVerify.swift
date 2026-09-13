import Foundation
import WayboundCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - Command line

private enum VerificationCLIError: Error, CustomStringConvertible {
    case message(String)
    case help

    var description: String {
        switch self {
        case let .message(value): return value
        case .help: return ""
        }
    }
}

private struct VerificationArea: Codable, Equatable {
    let name: String
    let slug: String
    let latitude: Double
    let longitude: Double

    var coordinate: GeoCoordinate {
        GeoCoordinate(latitude: latitude, longitude: longitude)
    }
}

private struct VerificationOptions {
    var areaBlobs: [String] = []
    var areaFiles: [String] = []
    var outputDirectory = "verification-output"
    var cacheDirectory = ".transitland-cache"
    var snapshotDate: String?
    var refresh = false
    var showHelp = false

    static func parse(_ arguments: [String]) throws -> VerificationOptions {
        var options = VerificationOptions()
        var index = 0
        var explicitLatitude: Double?
        var explicitLongitude: Double?

        func value(for flag: String) throws -> String {
            guard index + 1 < arguments.count else {
                throw VerificationCLIError.message("missing value for \(flag)")
            }
            index += 1
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--area", "--coordinate", "--areas":
                options.areaBlobs.append(try value(for: argument))
            case "--areas-file":
                options.areaFiles.append(try value(for: argument))
            case "--output-dir":
                options.outputDirectory = try value(for: argument)
            case "--cache-dir":
                options.cacheDirectory = try value(for: argument)
            case "--date":
                options.snapshotDate = try value(for: argument)
            case "--lat":
                guard let latitude = Double(try value(for: argument)) else {
                    throw VerificationCLIError.message("--lat must be a number")
                }
                explicitLatitude = latitude
            case "--lon", "--lng":
                guard let longitude = Double(try value(for: argument)) else {
                    throw VerificationCLIError.message("--lon must be a number")
                }
                explicitLongitude = longitude
            case "--refresh":
                options.refresh = true
            case "--help", "-h":
                options.showHelp = true
            default:
                if argument.hasPrefix("-") {
                    throw VerificationCLIError.message(
                        "unknown option \(argument); use --help for usage"
                    )
                }
                // Positional specifications are accepted as a convenience for
                // local runs. The workflow uses --areas-file so its dispatch
                // input can contain several lines without shell quoting issues.
                options.areaBlobs.append(argument)
            }
            index += 1
        }

        if let explicitLatitude, let explicitLongitude {
            options.areaBlobs.append("\(explicitLatitude),\(explicitLongitude)")
        } else if explicitLatitude != nil || explicitLongitude != nil {
            throw VerificationCLIError.message("--lat and --lon must be supplied together")
        }
        return options
    }

    func areas() throws -> [VerificationArea] {
        if showHelp { return [] }

        var specifications = areaBlobs
        for file in areaFiles {
            let url = URL(fileURLWithPath: file)
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                throw VerificationCLIError.message("could not read areas file \(file)")
            }
            specifications.append(contents)
        }
        guard !specifications.isEmpty else {
            throw VerificationCLIError.message(
                "at least one area is required; pass --area NAME=LAT,LON "
                    + "or --areas-file FILE"
            )
        }

        var result: [VerificationArea] = []
        var seen: Set<String> = []
        for blob in specifications {
            let lines = blob.split { character in
                character == "\n" || character == "\r" || character == ";"
            }
            for line in lines {
                let raw = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty, !raw.hasPrefix("#") else { continue }
                let area = try Self.parseArea(raw, ordinal: result.count + 1)
                let identity = "\(area.slug)|\(area.latitude)|\(area.longitude)"
                if seen.insert(identity).inserted {
                    result.append(area)
                }
            }
        }
        guard !result.isEmpty else {
            throw VerificationCLIError.message("the supplied areas did not contain coordinates")
        }
        return result
    }

    private static func parseArea(
        _ raw: String,
        ordinal: Int
    ) throws -> VerificationArea {
        var label: String?
        var coordinateText = raw
        if let equals = raw.firstIndex(of: "=") {
            label = String(raw[..<equals])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            coordinateText = String(raw[raw.index(after: equals)...])
        } else if let pipe = raw.firstIndex(of: "|") {
            label = String(raw[..<pipe])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            coordinateText = String(raw[raw.index(after: pipe)...])
        }

        let values = coordinateText
            .split(separator: ",", maxSplits: 1)
            .compactMap { Double(String($0).trimmingCharacters(in: .whitespaces)) }
        guard values.count == 2,
              (-90...90).contains(values[0]),
              (-180...180).contains(values[1])
        else {
            throw VerificationCLIError.message(
                "invalid area \"\(raw)\"; use NAME=LAT,LON or LAT,LON"
            )
        }

        let name = label.flatMap { $0.isEmpty ? nil : $0 }
            ?? "area-\(ordinal)"
        let slug = Self.slug(for: name, latitude: values[0], longitude: values[1])
        return VerificationArea(
            name: name,
            slug: slug,
            latitude: values[0],
            longitude: values[1]
        )
    }

    private static func slug(
        for name: String,
        latitude: Double,
        longitude: Double
    ) -> String {
        var result = ""
        for scalar in name.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result += String(scalar).lowercased()
            } else if !result.isEmpty, !result.hasSuffix("-") {
                result += "-"
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        if result.isEmpty {
            result = String(format: "area-%+.5f-%+.5f", latitude, longitude)
                .replacingOccurrences(of: "+", with: "")
                .replacingOccurrences(of: ".", with: "_")
                .replacingOccurrences(of: "-", with: "m")
        }
        return result
    }
}

private func usage() -> String {
    """
    waybound-transit-verify — live Transitland verification

    Required (repeat --area, or pass a file with one specification per line):
      --area "Santa Barbara=34.4209,-119.7033"
      --area "37.7749,-122.4194"
      --areas-file areas.txt

    Options:
      --areas TEXT       newline/semicolon-separated area specifications
      --coordinate TEXT  alias for --area
      --lat LAT --lon LON  add one unnamed coordinate pair
      --date YYYY-MM-DD  service day and snapshot/cache date (default: current UTC date)
      --cache-dir PATH   raw snapshot cache (default: .transitland-cache)
      --output-dir PATH  report and artifact directory (default: verification-output)
      --refresh          ignore an existing complete snapshot for this date
      --help

    The Transitland API key is read only from TRANSITLAND_API_KEY.
    """
}

// MARK: - Rate-limited Transitland HTTP

private struct TransitlandHTTPResponse {
    let data: Data
    let statusCode: Int
    let url: URL
}

private final class TransitlandHTTPClient {
    private let apiKey: String
    private let minimumInterval: TimeInterval
    private let maximumAttempts = 5
    private var lastRequestAt: Date?

    init(apiKey: String, minimumInterval: TimeInterval = 0.35) {
        self.apiKey = apiKey
        self.minimumInterval = minimumInterval
    }

    /// All callers use this client from the area's sequential fetch loop. The
    /// limiter is deliberately here, rather than in the workflow, so a cached
    /// run and a local run have identical request behavior.
    func get(_ url: URL) async throws -> TransitlandHTTPResponse {
        var attempt = 0
        while attempt < maximumAttempts {
            try await waitForRateLimit()
            do {
                var request = URLRequest(url: url)
                request.setValue(apiKey, forHTTPHeaderField: "apikey")
                request.setValue("Waybound live verification", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                let status = httpResponse.statusCode
                guard !(200...299).contains(status) else {
                    return TransitlandHTTPResponse(
                        data: data,
                        statusCode: status,
                        url: url
                    )
                }

                if isRetryable(status: status), attempt + 1 < maximumAttempts {
                    let serverDelay = retryAfterSeconds(from: httpResponse)
                    attempt += 1
                    try await sleep(seconds: serverDelay ?? backoffSeconds(for: attempt))
                    continue
                }
                return TransitlandHTTPResponse(data: data, statusCode: status, url: url)
            } catch let error as URLError {
                guard isRetryable(error: error), attempt + 1 < maximumAttempts else {
                    throw error
                }
                attempt += 1
                try await sleep(seconds: backoffSeconds(for: attempt))
            }
        }
        throw URLError(.cannotLoadFromNetwork)
    }

    private func waitForRateLimit() async throws {
        if let lastRequestAt {
            let elapsed = Date().timeIntervalSince(lastRequestAt)
            if elapsed < minimumInterval {
                try await sleep(seconds: minimumInterval - elapsed)
            }
        }
        lastRequestAt = Date()
    }

    private func sleep(seconds: TimeInterval) async throws {
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }

    private func backoffSeconds(for attempt: Int) -> TimeInterval {
        min(30, pow(2, Double(max(0, attempt - 1))))
    }

    private func isRetryable(status: Int) -> Bool {
        status == 429 || (500...599).contains(status)
    }

    private func isRetryable(error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    private func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else {
            return nil
        }
        if let seconds = Double(value) {
            return min(60, max(0, seconds))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return min(60, max(0, date.timeIntervalSinceNow))
    }
}

// MARK: - Raw, date-keyed snapshots

private struct SnapshotResponse: Codable {
    let name: String
    let url: String
    let fetchedAt: String
    let statusCode: Int?
    let bodyBase64: String?
    let error: String?

    var bodyData: Data? {
        guard let bodyBase64 else { return nil }
        return Data(base64Encoded: bodyBase64)
    }

    var succeeded: Bool {
        guard let statusCode else { return false }
        return (200...299).contains(statusCode) && error == nil
    }
}

private struct TransitlandSnapshot: Codable {
    let schemaVersion: String
    let area: VerificationArea
    let snapshotDate: String
    let fetchedAt: String
    var complete: Bool
    var issues: [String]
    var responses: [SnapshotResponse]

    func response(named name: String) -> SnapshotResponse? {
        responses.first { $0.name == name }
    }
}

private func utcTimestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}

private func utcDateString() -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
}

private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: url, options: .atomic)
}

private func readSnapshot(
    from url: URL,
    for area: VerificationArea,
    date: String
) -> TransitlandSnapshot? {
    guard let data = try? Data(contentsOf: url),
          let snapshot = try? JSONDecoder().decode(TransitlandSnapshot.self, from: data),
          snapshot.schemaVersion == "waybound-transitland-snapshot-v1",
          snapshot.complete,
          snapshot.snapshotDate == date,
          snapshot.area.slug == area.slug,
          abs(snapshot.area.latitude - area.latitude) < 0.000001,
          abs(snapshot.area.longitude - area.longitude) < 0.000001
    else { return nil }
    return snapshot
}

private func snapshotURL(
    directory: URL,
    area: VerificationArea,
    date: String
) -> URL {
    directory
        .appendingPathComponent(date, isDirectory: true)
        .appendingPathComponent("\(area.slug).json")
}

private func capture(
    name: String,
    url: URL,
    client: TransitlandHTTPClient
) async -> SnapshotResponse {
    do {
        let response = try await client.get(url)
        let success = (200...299).contains(response.statusCode)
        return SnapshotResponse(
            name: name,
            url: url.absoluteString,
            fetchedAt: utcTimestamp(),
            statusCode: response.statusCode,
            bodyBase64: response.data.base64EncodedString(),
            error: success ? nil : "HTTP \(response.statusCode)"
        )
    } catch {
        return SnapshotResponse(
            name: name,
            url: url.absoluteString,
            fetchedAt: utcTimestamp(),
            statusCode: nil,
            bodyBase64: nil,
            error: String(describing: error)
        )
    }
}

// MARK: - Transitland response models

private struct TransitlandPoint: Decodable {
    let coordinate: GeoCoordinate?

    private enum CodingKeys: String, CodingKey {
        case coordinates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let values = try container.decodeIfPresent([Double].self, forKey: .coordinates) ?? []
        guard values.count >= 2,
              (-180...180).contains(values[0]),
              (-90...90).contains(values[1])
        else {
            coordinate = nil
            return
        }
        coordinate = GeoCoordinate(latitude: values[1], longitude: values[0])
    }
}

private struct TransitlandGeometry: Decodable {
    let lines: [[GeoCoordinate]]

    private enum CodingKeys: String, CodingKey {
        case type
        case coordinates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type)
        let rawLines: [[[Double]]]
        switch type {
        case .some("LineString"):
            rawLines = [
                try container.decodeIfPresent([[Double]].self, forKey: .coordinates) ?? []
            ]
        case .some("MultiLineString"):
            rawLines = try container.decodeIfPresent(
                [[[Double]]].self,
                forKey: .coordinates
            ) ?? []
        default:
            rawLines = []
        }

        lines = rawLines.compactMap { rawLine in
            let line = rawLine.compactMap { values -> GeoCoordinate? in
                guard values.count >= 2,
                      (-180...180).contains(values[0]),
                      (-90...90).contains(values[1])
                else { return nil }
                return GeoCoordinate(latitude: values[1], longitude: values[0])
            }
            return line.count >= 2 ? line : nil
        }
    }
}

private struct TransitlandAgency: Decodable {
    let agencyName: String?

    enum CodingKeys: String, CodingKey {
        case agencyName = "agency_name"
    }
}

private struct TransitlandRouteRef: Decodable {
    let id: Int?
    let routeShortName: String?
    let routeLongName: String?
    let routeType: Int?
    let routeColor: String?
    let onestopID: String?
    let agency: TransitlandAgency?

    enum CodingKeys: String, CodingKey {
        case id
        case routeShortName = "route_short_name"
        case routeLongName = "route_long_name"
        case routeType = "route_type"
        case routeColor = "route_color"
        case onestopID = "onestop_id"
        case agency
    }
}

private struct TransitlandRouteStop: Decodable {
    let route: TransitlandRouteRef?
}

private struct TransitlandStop: Decodable {
    let id: Int
    let stopName: String?
    let geometry: TransitlandPoint?
    let routeStops: [TransitlandRouteStop]?

    enum CodingKeys: String, CodingKey {
        case id
        case stopName = "stop_name"
        case geometry
        case routeStops = "route_stops"
    }
}

private struct TransitlandStopsResponse: Decodable {
    let stops: [TransitlandStop]
}

private struct TransitlandRoute: Decodable {
    let id: Int
    let routeShortName: String?
    let routeLongName: String?
    let routeType: Int?
    let routeColor: String?
    let onestopID: String?
    let agency: TransitlandAgency?

    enum CodingKeys: String, CodingKey {
        case id
        case routeShortName = "route_short_name"
        case routeLongName = "route_long_name"
        case routeType = "route_type"
        case routeColor = "route_color"
        case onestopID = "onestop_id"
        case agency
    }
}

private struct TransitlandRoutesResponse: Decodable {
    let routes: [TransitlandRoute]
}

private struct TransitlandTripShape: Decodable {
    let shapeID: String?
    let geometry: TransitlandGeometry?
    let generated: Bool?

    enum CodingKeys: String, CodingKey {
        case shapeID = "shape_id"
        case geometry
        case generated
    }
}

private struct TransitlandTripStop: Decodable {
    let id: Int
    let stopName: String?
    let geometry: TransitlandPoint?

    enum CodingKeys: String, CodingKey {
        case id
        case stopName = "stop_name"
        case geometry
    }
}

private struct TransitlandTripStopTime: Decodable {
    let arrivalTime: String?
    let departureTime: String?
    let stopSequence: Int
    let stop: TransitlandTripStop

    enum CodingKeys: String, CodingKey {
        case arrivalTime = "arrival_time"
        case departureTime = "departure_time"
        case stopSequence = "stop_sequence"
        case stop
    }
}

private struct TransitlandTrip: Decodable {
    let id: Int
    let tripHeadsign: String?
    let directionID: Int?
    let route: TransitlandRouteRef?
    let shape: TransitlandTripShape?
    let stopTimes: [TransitlandTripStopTime]?

    enum CodingKeys: String, CodingKey {
        case id
        case tripHeadsign = "trip_headsign"
        case directionID = "direction_id"
        case route
        case shape
        case stopTimes = "stop_times"
    }
}

private struct TransitlandTripsResponse: Decodable {
    let trips: [TransitlandTrip]
}

private struct TransitlandStopTimeEvent: Decodable {
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

    var date: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let estimatedUTC, let estimated = formatter.date(from: estimatedUTC) {
            return estimated
        }
        if let scheduledUTC, let scheduled = formatter.date(from: scheduledUTC) {
            return scheduled
        }
        return nil
    }
}

private struct TransitlandDeparture: Decodable {
    let stopSequence: Int?
    let serviceDate: String?
    let arrivalTime: String?
    let departureTime: String?
    let arrival: TransitlandStopTimeEvent?
    let departure: TransitlandStopTimeEvent?
    let trip: TransitlandTrip?

    enum CodingKeys: String, CodingKey {
        case stopSequence = "stop_sequence"
        case serviceDate = "service_date"
        case arrivalTime = "arrival_time"
        case departureTime = "departure_time"
        case arrival
        case departure
        case trip
    }

    var eventDate: Date? {
        (departure ?? arrival)?.date
    }
}

private struct TransitlandStopDepartures: Decodable {
    let id: Int
    let departures: [TransitlandDeparture]
}

private struct TransitlandDeparturesResponse: Decodable {
    let stops: [TransitlandStopDepartures]
}

private func transitlandURL(
    path: String,
    query: [(String, String)] = []
) -> URL {
    var components = URLComponents(
        string: "https://transit.land/api/v2/rest/\(path)"
    )!
    components.queryItems = query.map {
        URLQueryItem(name: $0.0, value: $0.1)
    }
    return components.url!
}

private func hasRouteNumber(_ shortName: String?) -> Bool {
    guard let shortName,
          !shortName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          shortName != "?"
    else { return false }
    return shortName.unicodeScalars.contains {
        CharacterSet.decimalDigits.contains($0)
    }
}

private func routeDisplayNumber(_ shortName: String?) -> String? {
    guard hasRouteNumber(shortName) else { return nil }
    return shortName?.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func normalizedDirection(
    directionID: Int?,
    headsign: String?
) -> String {
    if let directionID { return "gtfs:\(directionID)" }
    return "headsign:\(TransitText.normalizedIdentityText(headsign ?? ""))"
}

private func distanceMeters(_ first: GeoCoordinate, _ second: GeoCoordinate) -> Double {
    let earthRadius = 6_371_008.8
    let radians = Double.pi / 180
    let firstLatitude = first.latitude * radians
    let secondLatitude = second.latitude * radians
    let deltaLatitude = (second.latitude - first.latitude) * radians
    let deltaLongitude = (second.longitude - first.longitude) * radians
    let a = sin(deltaLatitude / 2) * sin(deltaLatitude / 2)
        + cos(firstLatitude) * cos(secondLatitude)
        * sin(deltaLongitude / 2) * sin(deltaLongitude / 2)
    return earthRadius * 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
}

// MARK: - Report model

private struct FetchReport: Codable {
    let status: String
    let cacheHit: Bool
    let snapshotPath: String
    let requestCount: Int
    let successfulRequestCount: Int
    let failedRequestCount: Int
    let issues: [String]
}

private struct JourneyCountReport: Codable {
    let sourceStopCount: Int
    let routeCount: Int
    let candidateDepartureCount: Int
    let representativeTripCount: Int
    let journeyCount: Int
    let directionCount: Int
    let observedDepartureCount: Int
}

private struct AreaReport: Codable {
    let name: String
    let slug: String
    let latitude: Double
    let longitude: Double
    let fetch: FetchReport
    let journeys: JourneyCountReport
    let laneCheck: LaneVerificationResult
}

private struct VerificationSummary: Codable {
    let areaCount: Int
    let fetchedAreaCount: Int
    let cachedAreaCount: Int
    let failedAreaCount: Int
    let journeyCount: Int
    let lanePassedAreaCount: Int
    let laneFailedAreaCount: Int
    let laneSkippedAreaCount: Int
}

private struct VerificationReport: Codable {
    let schemaVersion: String
    let generatedAt: String
    let snapshotDate: String
    let summary: VerificationSummary
    let areas: [AreaReport]
}

private struct SelectedStop {
    let id: Int
    let coordinate: GeoCoordinate
    let routeIDs: Set<Int>
}

private struct RouteMetadata {
    let id: Int
    let shortName: String
    let agency: String
}

private struct DepartureCandidate {
    let routeID: Int
    let tripID: Int
    let directionID: Int?
    let headsign: String?
    let sourceStopID: Int
    let directionKey: String
    let eventDate: Date?
    let distanceFromOrigin: Double
    let observedDepartureCount: Int
}

private struct AreaAnalysis {
    let journeyCounts: JourneyCountReport
    let laneCheck: LaneVerificationResult
}

// MARK: - Area fetch and analysis

private final class LiveAreaVerifier {
    private let client: TransitlandHTTPClient
    private let date: String
    private let isLiveSearch: Bool
    private let cacheDirectory: URL
    private let outputDirectory: URL

    init(
        client: TransitlandHTTPClient,
        date: String,
        isLiveSearch: Bool,
        cacheDirectory: URL,
        outputDirectory: URL
    ) {
        self.client = client
        self.date = date
        self.isLiveSearch = isLiveSearch
        self.cacheDirectory = cacheDirectory
        self.outputDirectory = outputDirectory
    }

    func verify(
        area: VerificationArea,
        refresh: Bool
    ) async throws -> AreaReport {
        let cachedURL = snapshotURL(
            directory: cacheDirectory,
            area: area,
            date: date
        )
        let snapshot: TransitlandSnapshot
        let cacheHit: Bool

        if !refresh, let cached = readSnapshot(
            from: cachedURL,
            for: area,
            date: date
        ) {
            snapshot = cached
            cacheHit = true
        } else {
            snapshot = await fetchSnapshot(for: area)
            try writeJSON(snapshot, to: cachedURL)
            cacheHit = false
        }

        let artifactURL = outputDirectory
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(date, isDirectory: true)
            .appendingPathComponent("\(area.slug).json")
        try copyFile(cachedURL, to: artifactURL)

        let analysis = analyze(snapshot: snapshot, area: area)
        let successful = snapshot.responses.filter { $0.succeeded }.count
        let failed = snapshot.responses.count - successful
        let status: String
        if cacheHit {
            status = "cached"
        } else if snapshot.complete {
            status = "fetched"
        } else if let stops = snapshot.response(named: "stops"), stops.succeeded {
            status = "partial"
        } else {
            status = "failed"
        }

        let relativeSnapshotPath = "snapshots/\(date)/\(area.slug).json"
        return AreaReport(
            name: area.name,
            slug: area.slug,
            latitude: area.latitude,
            longitude: area.longitude,
            fetch: FetchReport(
                status: status,
                cacheHit: cacheHit,
                snapshotPath: relativeSnapshotPath,
                requestCount: snapshot.responses.count,
                successfulRequestCount: successful,
                failedRequestCount: failed,
                issues: snapshot.issues
            ),
            journeys: analysis.journeyCounts,
            laneCheck: analysis.laneCheck
        )
    }

    private func fetchSnapshot(for area: VerificationArea) async -> TransitlandSnapshot {
        var snapshot = TransitlandSnapshot(
            schemaVersion: "waybound-transitland-snapshot-v1",
            area: area,
            snapshotDate: date,
            fetchedAt: utcTimestamp(),
            complete: false,
            issues: [],
            responses: []
        )

        let stopsURL = transitlandURL(
            path: "stops",
            query: [
                ("lat", String(area.latitude)),
                ("lon", String(area.longitude)),
                ("radius", "804.672"),
                ("limit", "1000"),
                ("location_type", "0"),
                ("include_routes", "true"),
            ]
        )
        let stopsResponse = await capture(
            name: "stops",
            url: stopsURL,
            client: client
        )
        snapshot.responses.append(stopsResponse)
        guard let stopsData = stopsResponse.bodyData,
              stopsResponse.succeeded,
              let stopDocument = try? JSONDecoder().decode(
                  TransitlandStopsResponse.self,
                  from: stopsData
              )
        else {
            snapshot.issues.append("stops response could not be fetched or decoded")
            return finalize(snapshot)
        }

        let selectedStops = selectStops(
            from: stopDocument.stops,
            origin: area.coordinate
        )
        let routeIDs = Set(selectedStops.flatMap { $0.routeIDs }).sorted()

        // Match TransitViewModel.fetchRoutes: route metadata and a bounded
        // sample of trusted trip shapes are fetched once for each numbered
        // route attached to the retained nearby stops.
        for routeID in routeIDs {
            let routeURL = transitlandURL(
                path: "routes",
                query: [
                    ("id", String(routeID)),
                    ("limit", "1"),
                    ("include_geometry", "false"),
                    ("include_alerts", "false"),
                ]
            )
            let routeResponse = await capture(
                name: "route-meta-\(routeID)",
                url: routeURL,
                client: client
            )
            snapshot.responses.append(routeResponse)
            if routeResponse.succeeded,
               let data = routeResponse.bodyData,
               (try? JSONDecoder().decode(TransitlandRoutesResponse.self, from: data)) == nil {
                snapshot.issues.append("route \(routeID) metadata did not decode")
            }

            let tripsURL = transitlandURL(
                path: "routes/\(routeID)/trips",
                query: [
                    ("limit", "12"),
                    ("include_geometry", "true"),
                    ("include_alerts", "false"),
                ]
            )
            let tripsResponse = await capture(
                name: "route-trips-\(routeID)",
                url: tripsURL,
                client: client
            )
            snapshot.responses.append(tripsResponse)
            if tripsResponse.succeeded,
               let data = tripsResponse.bodyData,
               (try? JSONDecoder().decode(TransitlandTripsResponse.self, from: data)) == nil {
                snapshot.issues.append("route \(routeID) trip-shape sample did not decode")
            }
        }

        // The app asks for the live three-hour window at each retained physical
        // source stop. This is deliberately sequential: a large area must not
        // fan out into a second unbounded request pool.
        for stop in selectedStops.sorted(by: { $0.id < $1.id }) {
            let departuresURL = transitlandURL(
                path: "stops/\(stop.id)/departures",
                query: departureQuery()
            )
            let departuresResponse = await capture(
                name: "departures-\(stop.id)",
                url: departuresURL,
                client: client
            )
            snapshot.responses.append(departuresResponse)
            if departuresResponse.succeeded,
               let data = departuresResponse.bodyData,
               (try? JSONDecoder().decode(
                   TransitlandDeparturesResponse.self,
                   from: data
               )) == nil {
                snapshot.issues.append("stop \(stop.id) departures did not decode")
            }
        }

        // Select at most the same small representative set the view model puts
        // through its trip-detail path: one earliest trip per observed direction,
        // then fill any remaining slots up to three per route.
        let candidates = departureCandidates(
            snapshot: snapshot,
            selectedStops: selectedStops,
            routeIDs: Set(routeIDs),
            origin: area.coordinate
        )
        var fetchedTripKeys: Set<String> = []
        for candidate in candidates {
            let key = "\(candidate.routeID)-\(candidate.tripID)"
            guard fetchedTripKeys.insert(key).inserted else { continue }
            let tripURL = transitlandURL(
                path: "routes/\(candidate.routeID)/trips/\(candidate.tripID)",
                query: [
                    ("include_geometry", "true"),
                    ("include_alerts", "false"),
                ]
            )
            let tripResponse = await capture(
                name: "trip-\(candidate.routeID)-\(candidate.tripID)",
                url: tripURL,
                client: client
            )
            snapshot.responses.append(tripResponse)
            if tripResponse.succeeded,
               let data = tripResponse.bodyData,
               (try? JSONDecoder().decode(TransitlandTripsResponse.self, from: data)) == nil {
                snapshot.issues.append(
                    "trip \(candidate.tripID) detail did not decode"
                )
            }
        }

        return finalize(snapshot)
    }

    private func finalize(_ snapshot: TransitlandSnapshot) -> TransitlandSnapshot {
        var result = snapshot
        let responseIssues = result.responses.compactMap { response -> String? in
            guard !response.succeeded else { return nil }
            return "\(response.name): \(response.error ?? "request failed")"
        }
        result.issues = Array(Set(result.issues + responseIssues)).sorted()
        result.complete = !result.responses.isEmpty
            && result.responses.allSatisfy { $0.succeeded }
            && result.issues.isEmpty
        return result
    }

    private func departureQuery() -> [(String, String)] {
        let common: [(String, String)] = [
            ("limit", "200"),
            ("include_geometry", "false"),
            ("include_alerts", "false"),
        ]
        if isLiveSearch {
            return [
                ("next", "10800"),
            ] + common + [
                ("use_service_window", "false"),
            ]
        }

        // This is the same service-window branch used by
        // TransitViewModel for a future planning date. The verifier asks for
        // the whole requested service day so comparisons across dates see the
        // feed's actual day-level route/direction mix rather than whatever
        // three-hour wall-clock slice happened to be current on the runner.
        return [
            ("date", date),
            ("start_time", "00:00:00"),
            ("end_time", "23:59:59"),
        ] + common + [
            ("use_service_window", "true"),
        ]
    }

    private func selectStops(
        from rawStops: [TransitlandStop],
        origin: GeoCoordinate
    ) -> [SelectedStop] {
        let candidates = rawStops.compactMap { stop -> SelectedStop? in
            guard let coordinate = stop.geometry?.coordinate else { return nil }
            let routeIDs = Set(
                (stop.routeStops ?? []).compactMap { $0.route }
                    .filter { hasRouteNumber($0.routeShortName) }
                    .compactMap { $0.id }
            )
            guard !routeIDs.isEmpty else { return nil }
            return SelectedStop(
                id: stop.id,
                coordinate: coordinate,
                routeIDs: routeIDs
            )
        }.sorted {
            distanceMeters($0.coordinate, origin)
                < distanceMeters($1.coordinate, origin)
        }

        // StopClustering in the app ultimately preserves the nearest 30 logical
        // places and three physical candidates per route. This audit keeps the
        // same bounded/diversity rule without importing MapKit-only UI models.
        var retained: [SelectedStop] = []
        var seenIDs: Set<Int> = []
        var countByRoute: [Int: Int] = [:]
        for stop in candidates {
            let contributes = stop.routeIDs.contains {
                countByRoute[$0, default: 0] < 3
            }
            guard contributes || retained.count < 30 else { continue }
            if seenIDs.insert(stop.id).inserted {
                retained.append(stop)
                for routeID in stop.routeIDs
                where countByRoute[routeID, default: 0] < 3 {
                    countByRoute[routeID, default: 0] += 1
                }
            }
        }
        return retained
    }

    private func departureCandidates(
        snapshot: TransitlandSnapshot,
        selectedStops: [SelectedStop],
        routeIDs: Set<Int>,
        origin: GeoCoordinate
    ) -> [DepartureCandidate] {
        var candidatesByPattern: [String: [DepartureCandidate]] = [:]
        var tripIDsByPattern: [String: Set<Int>] = [:]
        let stopByID = Dictionary(uniqueKeysWithValues: selectedStops.map { ($0.id, $0) })

        // A `for ... where` clause takes a single boolean expression, so the
        // per-response bindings have to live in a guard inside the body.
        for response in snapshot.responses
        where response.name.hasPrefix("departures-") {
            guard response.succeeded,
                  let stopID = Int(
                      String(response.name.dropFirst("departures-".count))
                  ),
                  let stop = stopByID[stopID],
                  let data = response.bodyData,
                  let document = try? JSONDecoder().decode(
                      TransitlandDeparturesResponse.self,
                      from: data
                  )
            else { continue }
            let departures = document.stops.first { $0.id == stopID }?.departures ?? []
            for departure in departures {
                guard let trip = departure.trip else { continue }
                let routeID: Int?
                if let route = trip.route?.id {
                    routeID = route
                } else if stop.routeIDs.count == 1 {
                    routeID = stop.routeIDs.first
                } else {
                    routeID = nil
                }
                guard let routeID, routeIDs.contains(routeID) else { continue }
                let directionKey = normalizedDirection(
                    directionID: trip.directionID,
                    headsign: trip.tripHeadsign
                )
                let patternKey = "\(routeID)|\(directionKey)"
                let candidate = DepartureCandidate(
                    routeID: routeID,
                    tripID: trip.id,
                    directionID: trip.directionID,
                    headsign: trip.tripHeadsign,
                    sourceStopID: stopID,
                    directionKey: directionKey,
                    eventDate: departure.eventDate,
                    distanceFromOrigin: distanceMeters(stop.coordinate, origin),
                    observedDepartureCount: 0
                )
                candidatesByPattern[patternKey, default: []].append(candidate)
                tripIDsByPattern[patternKey, default: []].insert(trip.id)
            }
        }

        var patternRepresentatives: [DepartureCandidate] = []
        // Dictionary iteration order changes on every launch because Swift seeds
        // its hasher randomly per process. candidatePrecedes is deliberately
        // tolerant -- its one-metre distance deadband lets A tie with B and B tie
        // with C while A beats C on distance -- so it is not transitive, and
        // Swift's sort is not stable. Feeding that sort an unordered array made
        // the winning representative for a direction, and therefore the trip
        // shapes handed to the lane pipeline, vary between runs over identical
        // snapshots: scheduledSegmentCount and trunkVertexCount moved while every
        // count stayed the same. Iterating patterns in a fixed order and
        // canonically ordering the representatives makes the selection
        // reproducible without changing what the comparator prefers.
        for key in candidatesByPattern.keys.sorted() {
            guard let first = candidatesByPattern[key]?
                .min(by: candidatePrecedes)
            else { continue }
            patternRepresentatives.append(DepartureCandidate(
                routeID: first.routeID,
                tripID: first.tripID,
                directionID: first.directionID,
                headsign: first.headsign,
                sourceStopID: first.sourceStopID,
                directionKey: first.directionKey,
                eventDate: first.eventDate,
                distanceFromOrigin: first.distanceFromOrigin,
                observedDepartureCount: tripIDsByPattern[key]?.count ?? 0
            ))
        }
        patternRepresentatives.sort(by: candidateIdentityPrecedes)

        var selected: [DepartureCandidate] = []
        for routeID in routeIDs.sorted() {
            let representatives = patternRepresentatives
                .filter { $0.routeID == routeID }
                .sorted(by: candidatePrecedes)
            var directions: Set<String> = []
            for candidate in representatives {
                guard directions.insert(candidate.directionKey).inserted else {
                    continue
                }
                selected.append(candidate)
                if directions.count == 3 { break }
            }
            if directions.count < 3 {
                for candidate in representatives
                where !selected.contains(where: {
                    $0.routeID == candidate.routeID && $0.tripID == candidate.tripID
                }) {
                    selected.append(candidate)
                    if selected.filter({ $0.routeID == routeID }).count == 3 {
                        break
                    }
                }
            }
        }
        return selected.sorted(by: candidateIdentityPrecedes)
    }

    /// Canonical, transitive order over candidates: route, then direction, then
    /// trip. `candidatePrecedes` expresses the audit's preference (proximity,
    /// then departure time) but its distance deadband makes it intransitive, so
    /// it cannot define a reproducible sequence on its own. Anything whose order
    /// is observable has to go through this instead.
    private func candidateIdentityPrecedes(
        _ first: DepartureCandidate,
        _ second: DepartureCandidate
    ) -> Bool {
        if first.routeID != second.routeID { return first.routeID < second.routeID }
        if first.directionKey != second.directionKey {
            return first.directionKey < second.directionKey
        }
        return first.tripID < second.tripID
    }

    private func candidatePrecedes(
        _ first: DepartureCandidate,
        _ second: DepartureCandidate
    ) -> Bool {
        if abs(first.distanceFromOrigin - second.distanceFromOrigin) > 1 {
            return first.distanceFromOrigin < second.distanceFromOrigin
        }
        switch (first.eventDate, second.eventDate) {
        case let (lhs?, rhs?) where lhs != rhs:
            return lhs < rhs
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return first.tripID < second.tripID
        }
    }

    private func analyze(
        snapshot: TransitlandSnapshot,
        area: VerificationArea
    ) -> AreaAnalysis {
        guard let stopResponse = snapshot.response(named: "stops"),
              let stopData = stopResponse.bodyData,
              let stopDocument = try? JSONDecoder().decode(
                  TransitlandStopsResponse.self,
                  from: stopData
              )
        else {
            let emptyCounts = JourneyCountReport(
                sourceStopCount: 0,
                routeCount: 0,
                candidateDepartureCount: 0,
                representativeTripCount: 0,
                journeyCount: 0,
                directionCount: 0,
                observedDepartureCount: 0
            )
            return AreaAnalysis(
                journeyCounts: emptyCounts,
                laneCheck: LiveLaneVerification.verify(journeys: [])
            )
        }

        let selectedStops = selectStops(
            from: stopDocument.stops,
            origin: area.coordinate
        )
        let routeIDs = Set(selectedStops.flatMap { $0.routeIDs })
        let candidates = departureCandidates(
            snapshot: snapshot,
            selectedStops: selectedStops,
            routeIDs: routeIDs,
            origin: area.coordinate
        )

        var journeys: [LaneDiagnosticsDocument.Journey] = []
        var routeIDsWithJourneys: Set<Int> = []
        var directionKeysWithJourneys: Set<String> = []
        var nextJourneyID = 0
        for candidate in candidates {
            guard let response = snapshot.response(
                named: "trip-\(candidate.routeID)-\(candidate.tripID)"
            ),
                  response.succeeded,
                  let data = response.bodyData,
                  let document = try? JSONDecoder().decode(
                      TransitlandTripsResponse.self,
                      from: data
                  ),
                  let trip = document.trips.first(where: { $0.id == candidate.tripID }),
                  let metadata = routeMetadata(
                      snapshot: snapshot,
                      routeID: candidate.routeID,
                      trip: trip
                  ),
                  routeDisplayNumber(metadata.shortName) != nil,
                  let journey = makeLaneJourney(
                      trip: trip,
                      candidate: candidate,
                      metadata: metadata,
                      origin: area.coordinate,
                      id: nextJourneyID,
                      departures: candidate.observedDepartureCount
                  )
            else { continue }

            journeys.append(journey)
            routeIDsWithJourneys.insert(candidate.routeID)
            directionKeysWithJourneys.insert(
                "\(candidate.routeID)|\(candidate.directionKey)"
            )
            nextJourneyID += 1
        }

        let laneCheck = LiveLaneVerification.verify(journeys: journeys)
        let counts = JourneyCountReport(
            sourceStopCount: selectedStops.count,
            routeCount: routeIDsWithJourneys.count,
            candidateDepartureCount: candidates.reduce(0) {
                $0 + $1.observedDepartureCount
            },
            representativeTripCount: candidates.count,
            journeyCount: journeys.count,
            directionCount: directionKeysWithJourneys.count,
            observedDepartureCount: candidates.reduce(0) {
                $0 + $1.observedDepartureCount
            }
        )
        return AreaAnalysis(journeyCounts: counts, laneCheck: laneCheck)
    }

    private func routeMetadata(
        snapshot: TransitlandSnapshot,
        routeID: Int,
        trip: TransitlandTrip
    ) -> RouteMetadata? {
        if let response = snapshot.response(named: "route-meta-\(routeID)"),
           let data = response.bodyData,
           let document = try? JSONDecoder().decode(
               TransitlandRoutesResponse.self,
               from: data
           ),
           let route = document.routes.first(where: { $0.id == routeID })
        {
            return RouteMetadata(
                id: route.id,
                shortName: route.routeShortName ?? trip.route?.routeShortName ?? "",
                agency: route.agency?.agencyName ?? trip.route?.agency?.agencyName
                    ?? "Unknown Agency"
            )
        }
        guard let route = trip.route else { return nil }
        return RouteMetadata(
            id: routeID,
            shortName: route.routeShortName ?? "",
            agency: route.agency?.agencyName ?? "Unknown Agency"
        )
    }

    private func makeLaneJourney(
        trip: TransitlandTrip,
        candidate: DepartureCandidate,
        metadata: RouteMetadata,
        origin: GeoCoordinate,
        id: Int,
        departures: Int
    ) -> LaneDiagnosticsDocument.Journey? {
        guard trip.shape?.generated == false,
              let shapeLines = trip.shape?.geometry?.lines,
              !shapeLines.isEmpty,
              let stopTimes = trip.stopTimes?.sorted(by: {
                  $0.stopSequence < $1.stopSequence
              }),
              let boardingIndex = stopTimes.firstIndex(where: {
                  $0.stop.id == candidate.sourceStopID
              }),
              stopTimes.count - boardingIndex >= 2
        else { return nil }

        // The app's flagship paths start at a selected physical boarding stop
        // and only draw nearby geometry. We retain the same invariant here:
        // reject a shape with no downstream stop and feed the exact trip shape
        // through the package after clipping it to the map's 0.75-mile route
        // display radius.
        let downstreamHasCoordinate = stopTimes[boardingIndex...].dropFirst().contains {
            $0.stop.geometry?.coordinate != nil
        }
        guard downstreamHasCoordinate else { return nil }

        let nearbyLines = clippedLines(
            shapeLines,
            around: origin,
            radiusMeters: 1_207.008
        )
        let densifiedLines = nearbyLines
            .map { CorridorMembership.densify($0) }
            .filter { $0.count >= 2 }
        guard !densifiedLines.isEmpty else { return nil }

        return LaneDiagnosticsDocument.Journey(
            id: id,
            routeNumber: metadata.shortName.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            agency: metadata.agency.trimmingCharacters(in: .whitespacesAndNewlines),
            directionID: trip.directionID ?? candidate.directionID,
            stackOrder: id,
            departures: max(0, departures),
            polylines: densifiedLines
        )
    }

    /// Clips actual trip-shape geometry in the same projected space used by
    /// WayboundCore. Keeping the clipping here makes a long intercity trip
    /// contribute only the local corridor the verifier fetched it for, while
    /// preserving both entry/exit intersections when a shape crosses the
    /// radius between two raw shape vertices.
    private func clippedLines(
        _ lines: [[GeoCoordinate]],
        around origin: GeoCoordinate,
        radiusMeters: Double
    ) -> [[GeoCoordinate]] {
        let originPoint = origin.projected
        let radius = radiusMeters
            / GeoProjection.metersPerUnit(atLatitude: origin.latitude)
        var result: [[GeoCoordinate]] = []

        func intervalInside(
            _ start: ProjectedPoint,
            _ end: ProjectedPoint
        ) -> (Double, Double)? {
            let dx = end.x - start.x
            let dy = end.y - start.y
            let a = dx * dx + dy * dy
            let radiusSquared = radius * radius
            let startX = start.x - originPoint.x
            let startY = start.y - originPoint.y
            let c = startX * startX + startY * startY - radiusSquared
            guard a > 0.000000000001 else {
                return c <= 0 ? (0, 1) : nil
            }
            let b = 2 * (startX * dx + startY * dy)
            let discriminant = b * b - 4 * a * c
            if discriminant < 0 {
                return c <= 0 ? (0, 1) : nil
            }
            let root = sqrt(discriminant)
            let lower = max(0, min(1, (-b - root) / (2 * a)))
            let upper = max(0, min(1, (-b + root) / (2 * a)))
            guard upper >= lower else { return nil }
            if c <= 0 { return (0, upper) }
            return (lower, upper)
        }

        for line in lines {
            guard line.count >= 2 else { continue }
            var current: [GeoCoordinate] = []
            func finish() {
                if current.count >= 2 { result.append(current) }
                current.removeAll(keepingCapacity: true)
            }

            for index in 0..<(line.count - 1) {
                let start = line[index].projected
                let end = line[index + 1].projected
                guard let interval = intervalInside(start, end) else {
                    finish()
                    continue
                }
                let clippedStart = ProjectedPoint(
                    x: start.x + (end.x - start.x) * interval.0,
                    y: start.y + (end.y - start.y) * interval.0
                )
                let clippedEnd = ProjectedPoint(
                    x: start.x + (end.x - start.x) * interval.1,
                    y: start.y + (end.y - start.y) * interval.1
                )
                guard clippedStart.distance(to: clippedEnd) > 0.000001 else {
                    continue
                }
                let first = GeoCoordinate.fromProjected(clippedStart)
                let last = GeoCoordinate.fromProjected(clippedEnd)
                if let previous = current.last,
                   previous.projected.distance(to: clippedStart) < 0.000001 {
                    current.append(last)
                } else {
                    finish()
                    current = [first, last]
                }
            }
            finish()
        }
        return result
    }

    private func copyFile(_ source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

// MARK: - Reports and entry point

private func markdownReport(_ report: VerificationReport) -> String {
    var lines: [String] = []
    lines.append("# Waybound live Transitland verification")
    lines.append("")
    lines.append("- Snapshot date: `\(report.snapshotDate)`")
    lines.append("- Generated: `\(report.generatedAt)`")
    lines.append("- Areas: \(report.summary.areaCount)")
    lines.append("")
    lines.append("## Summary")
    lines.append("")
    lines.append("- Complete fetches: \(report.summary.fetchedAreaCount)")
    lines.append("- Cache hits: \(report.summary.cachedAreaCount)")
    lines.append("- Failed or partial fetches: \(report.summary.failedAreaCount)")
    lines.append("- Usable journeys: \(report.summary.journeyCount)")
    lines.append("- Lane checks passed: \(report.summary.lanePassedAreaCount)")
    lines.append("- Lane checks failed: \(report.summary.laneFailedAreaCount)")
    lines.append("- Lane checks skipped: \(report.summary.laneSkippedAreaCount)")
    lines.append("")
    lines.append("## Areas")
    lines.append("")
    lines.append(
        "| Area | Fetch | Stops | Routes | Candidate departures "
            + "| Representative trips | Journeys | Lane check |"
    )
    lines.append(
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |"
    )
    for area in report.areas {
        lines.append(
            "| \(area.name.replacingOccurrences(of: "|", with: "\\|")) "
                + "| \(area.fetch.status) "
                + "| \(area.journeys.sourceStopCount) "
                + "| \(area.journeys.routeCount) "
                + "| \(area.journeys.candidateDepartureCount) "
                + "| \(area.journeys.representativeTripCount) "
                + "| \(area.journeys.journeyCount) "
                + "| \(area.laneCheck.status) |"
        )
    }

    for area in report.areas {
        lines.append("")
        lines.append("## \(area.name)")
        lines.append("")
        lines.append(
            "Coordinates: `\(area.latitude),\(area.longitude)`  \n"
                + "Snapshot: `\(area.fetch.snapshotPath)`"
        )
        lines.append("")
        lines.append("### Fetch")
        lines.append("")
        lines.append(
            "\(area.fetch.status) — \(area.fetch.successfulRequestCount)/"
                + "\(area.fetch.requestCount) requests succeeded; "
                + "\(area.fetch.failedRequestCount) failed."
        )
        if !area.fetch.issues.isEmpty {
            lines.append("")
            lines.append("Fetch issues:")
            for issue in area.fetch.issues {
                lines.append("- \(issue)")
            }
        }
        lines.append("")
        lines.append("### Journeys")
        lines.append("")
        lines.append(
            "\(area.journeys.journeyCount) usable journeys across "
                + "\(area.journeys.routeCount) routes and "
                + "\(area.journeys.directionCount) directions; "
                + "\(area.journeys.observedDepartureCount) observed departures."
        )
        lines.append("")
        lines.append("### Lane check")
        lines.append("")
        lines.append(
            "**\(area.laneCheck.status)** — "
                + "\(area.laneCheck.journeyCount) journeys, "
                + "\(area.laneCheck.polylineCount) polylines, "
                + "\(area.laneCheck.sharedSegmentCount) shared segments, "
                + "\(area.laneCheck.scheduledSegmentCount) scheduled segments, "
                + "\(area.laneCheck.layoutVertexCount) layout vertices, "
                + "\(area.laneCheck.trunkVertexCount) trunk vertices."
        )
        if !area.laneCheck.issues.isEmpty {
            lines.append("")
            lines.append("Lane issues:")
            for issue in area.laneCheck.issues {
                lines.append("- \(issue)")
            }
        }
    }
    lines.append("")
    return lines.joined(separator: "\n")
}

private func absoluteURL(_ path: String) -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
    return root.appendingPathComponent(path)
}

@main
struct WayboundTransitVerifyMain {
    static func main() async {
        do {
            let options = try VerificationOptions.parse(
                Array(CommandLine.arguments.dropFirst())
            )
            if options.showHelp {
                print(usage())
                return
            }
            let areas = try options.areas()
            let apiKey = ProcessInfo.processInfo.environment[
                "TRANSITLAND_API_KEY"
            ]?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let apiKey, !apiKey.isEmpty else {
                throw VerificationCLIError.message(
                    "TRANSITLAND_API_KEY is required for live verification"
                )
            }

            let date = options.snapshotDate ?? utcDateString()
            guard date.count == 10,
                  date[date.index(date.startIndex, offsetBy: 4)] == "-",
                  date[date.index(date.startIndex, offsetBy: 7)] == "-"
            else {
                throw VerificationCLIError.message(
                    "--date must use YYYY-MM-DD"
                )
            }

            let cacheDirectory = absoluteURL(options.cacheDirectory)
            let outputDirectory = absoluteURL(options.outputDirectory)
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )

            let verifier = LiveAreaVerifier(
                client: TransitlandHTTPClient(apiKey: apiKey),
                date: date,
                isLiveSearch: date == utcDateString(),
                cacheDirectory: cacheDirectory,
                outputDirectory: outputDirectory
            )
            var areaReports: [AreaReport] = []
            for area in areas {
                print("verifying \(area.name) (\(area.latitude),\(area.longitude))")
                let report = try await verifier.verify(
                    area: area,
                    refresh: options.refresh
                )
                areaReports.append(report)
                print(
                    "  \(report.fetch.status): \(report.journeys.journeyCount) journeys; "
                        + "lane \(report.laneCheck.status)"
                )
            }

            let fetched = areaReports.filter { $0.fetch.status == "fetched" }.count
            let cached = areaReports.filter { $0.fetch.status == "cached" }.count
            let failed = areaReports.count - fetched - cached
            let lanePassed = areaReports.filter { $0.laneCheck.status == "passed" }.count
            let laneFailed = areaReports.filter { $0.laneCheck.status == "failed" }.count
            let laneSkipped = areaReports.filter { $0.laneCheck.status == "skipped" }.count
            let report = VerificationReport(
                schemaVersion: "waybound-transitland-verification-v1",
                generatedAt: utcTimestamp(),
                snapshotDate: date,
                summary: VerificationSummary(
                    areaCount: areaReports.count,
                    fetchedAreaCount: fetched,
                    cachedAreaCount: cached,
                    failedAreaCount: failed,
                    journeyCount: areaReports.reduce(0) {
                        $0 + $1.journeys.journeyCount
                    },
                    lanePassedAreaCount: lanePassed,
                    laneFailedAreaCount: laneFailed,
                    laneSkippedAreaCount: laneSkipped
                ),
                areas: areaReports
            )
            try writeJSON(
                report,
                to: outputDirectory.appendingPathComponent("report.json")
            )
            let markdown = markdownReport(report)
            try markdown.write(
                to: outputDirectory.appendingPathComponent("report.md"),
                atomically: true,
                encoding: .utf8
            )
            print("wrote \(outputDirectory.path)/report.json")
            print("wrote \(outputDirectory.path)/report.md")

            // A partial/failed fetch or an actual lane invariant failure makes
            // the live job red. Empty service is reported as skipped, not as a
            // fabricated pass, so a valid no-service area remains inspectable.
            if failed > 0 || laneFailed > 0 {
                exit(1)
            }
        } catch VerificationCLIError.help {
            print(usage())
        } catch {
            fputs("waybound-transit-verify: \(error)\n", stderr)
            exit(2)
        }
    }
}
