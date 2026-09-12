import Foundation

/// Decoder for the app's lane-diagnostics export
/// (`waybound-lanes-<epoch>.json`, format `waybound-lanes-v1`).
///
/// The export is the device's ground truth: the exact polylines the app
/// densified, the schedule its Swift lane scheduler chose, and the final
/// per-vertex offsets its pipeline drew. Golden tests in this package
/// recompute from the polylines and compare against these fields —
/// that is the fidelity contract between this package and the shipped
/// app, with no Python anywhere in the loop.
public struct LaneDiagnosticsDocument {
    public struct Journey {
        public let id: Int
        public let routeNumber: String
        public let agency: String
        public let directionID: Int?
        public let stackOrder: Int
        public let departures: Int
        public let polylines: [[GeoCoordinate]]
    }

    public struct ScheduleEntry {
        public let segmentIndex: Int
        public let offset: Double
        public let directionX: Double
        public let directionY: Double
        public let referenceJourneyID: Int
    }

    public struct ScheduleStrand {
        public let journeyID: Int
        public let polylineIndex: Int
        public let entries: [ScheduleEntry]
    }

    public struct LayoutStrand {
        public let journeyID: Int
        public let polylineIndex: Int
        public let offsets: [Double]
        public let shared: [Bool]
        public let trunk: [Bool]
    }

    public let journeys: [Journey]
    public let schedule: [ScheduleStrand]
    public let layouts: [LayoutStrand]
    public let laneSpacingPoints: Double

    public init(data: Data) throws {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let root = obj as? [String: Any] else {
            throw LaneDiagnosticsError.badRoot
        }

        var journeys: [Journey] = []
        if let rawJourneys = root["journeys"] as? [[String: Any]] {
            for raw in rawJourneys {
                guard let id = (raw["id"] as? NSNumber)?.intValue,
                      let routeNumber = raw["routeNumber"] as? String
                else { throw LaneDiagnosticsError.badJourney }
                var polylines: [[GeoCoordinate]] = []
                if let rawPolylines = raw["polylines"] as? [[[Any]]] {
                    for rawPolyline in rawPolylines {
                        var coords: [GeoCoordinate] = []
                        for pair in rawPolyline {
                            guard pair.count == 2,
                                  let lat = LaneDiagnostics.number(pair[0]),
                                  let lon = LaneDiagnostics.number(pair[1])
                            else { throw LaneDiagnosticsError.badCoordinate }
                            coords.append(
                                GeoCoordinate(latitude: lat, longitude: lon)
                            )
                        }
                        polylines.append(coords)
                    }
                }
                journeys.append(
                    Journey(
                        id: id,
                        routeNumber: routeNumber,
                        agency: raw["agency"] as? String ?? "",
                        directionID: (raw["directionID"] as? NSNumber)?.intValue,
                        stackOrder: (raw["stackOrder"] as? NSNumber)?.intValue ?? 0,
                        departures: (raw["departures"] as? NSNumber)?.intValue ?? 0,
                        polylines: polylines
                    )
                )
            }
        }

        var schedule: [ScheduleStrand] = []
        if let rawSchedule = root["schedule"] as? [[String: Any]] {
            for raw in rawSchedule {
                guard let journeyID = (raw["journeyID"] as? NSNumber)?.intValue,
                      let polylineIndex =
                          (raw["polylineIndex"] as? NSNumber)?.intValue,
                      let rawEntries = raw["entries"] as? [[Any]]
                else { throw LaneDiagnosticsError.badSchedule }
                var entries: [ScheduleEntry] = []
                for rawEntry in rawEntries {
                    guard rawEntry.count == 5,
                          let seg = (rawEntry[0] as? NSNumber)?.intValue,
                          let offset = LaneDiagnostics.number(rawEntry[1]),
                          let dx = LaneDiagnostics.number(rawEntry[2]),
                          let dy = LaneDiagnostics.number(rawEntry[3]),
                          let ref = (rawEntry[4] as? NSNumber)?.intValue
                    else { throw LaneDiagnosticsError.badEntry }
                    entries.append(
                        ScheduleEntry(
                            segmentIndex: seg,
                            offset: offset,
                            directionX: dx,
                            directionY: dy,
                            referenceJourneyID: ref
                        )
                    )
                }
                schedule.append(
                    ScheduleStrand(
                        journeyID: journeyID,
                        polylineIndex: polylineIndex,
                        entries: entries
                    )
                )
            }
        }

        var layouts: [LayoutStrand] = []
        if let rawLayouts = root["layouts"] as? [[String: Any]] {
            for raw in rawLayouts {
                guard let journeyID = (raw["journeyID"] as? NSNumber)?.intValue,
                      let polylineIndex =
                          (raw["polylineIndex"] as? NSNumber)?.intValue,
                      let rawOffsets = raw["offsets"] as? [Any],
                      let rawShared = raw["shared"] as? [Any]
                else { throw LaneDiagnosticsError.badLayout }
                let offsets = rawOffsets.compactMap {
                    LaneDiagnostics.number($0)
                }
                let shared = rawShared.map {
                    ($0 as? NSNumber)?.boolValue ?? false
                }
                let trunk = (raw["trunk"] as? [Any] ?? []).map {
                    ($0 as? NSNumber)?.boolValue ?? false
                }
                layouts.append(
                    LayoutStrand(
                        journeyID: journeyID,
                        polylineIndex: polylineIndex,
                        offsets: offsets,
                        shared: shared,
                        trunk: trunk
                    )
                )
            }
        }

        self.journeys = journeys
        self.schedule = schedule
        self.layouts = layouts
        self.laneSpacingPoints =
            (root["laneSpacingPoints"] as? NSNumber)?.doubleValue ?? 4.2
    }

    public init(url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    /// (journeyID, polylineIndex) -> journey, for quick membership tests.
    public var journeyByID: [Int: Journey] {
        var out: [Int: Journey] = [:]
        for journey in journeys { out[journey.id] = journey }
        return out
    }

    private static func number(_ value: Any) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}

public enum LaneDiagnosticsError: Error {
    case badRoot
    case badJourney
    case badCoordinate
    case badSchedule
    case badEntry
    case badLayout
}
