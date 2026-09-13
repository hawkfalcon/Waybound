import Foundation
import WayboundCore

/// waybound-lanelab: the lane report tool. Reads lane-diagnostics exports
/// (`waybound-lanes-*.json`) and prints the numeric screenshot — the
/// lateral stacking at stations along the longest strands, straight from
/// the device's own exported layouts — plus the per-fixture golden tables
/// the CI tests gate on. Replaces the Python `ingest.py` station report.
///
/// Usage:
///   swift run waybound-lanelab [fixture.json ...]
/// (no arguments: every `tools/replay/data/waybound-lanes-*.json` relative
/// to the repository root)

func fixturePaths() -> [String] {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if !arguments.isEmpty { return arguments }
    let dataDirectory = URL(fileURLWithPath: "tools/replay/data")
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: dataDirectory,
        includingPropertiesForKeys: nil
    ) else { return [] }
    return files
        .filter { $0.lastPathComponent.hasPrefix("waybound-lanes-") }
        .filter { $0.pathExtension == "json" }
        .map { $0.path }
        .sorted()
}

func stationReport(_ doc: LaneDiagnosticsDocument) {
    let laneSpacing = doc.laneSpacingPoints
    // The device's exported layouts, keyed per strand.
    struct StrandLayout {
        let journey: LaneDiagnosticsDocument.Journey
        let layout: LaneDiagnosticsDocument.LayoutStrand
    }
    var byStrand: [String: StrandLayout] = [:]
    for layout in doc.layouts {
        guard let journey = doc.journeyByID[layout.journeyID] else { continue }
        let key = "\(layout.journeyID)/\(layout.polylineIndex)"
        byStrand[key] = StrandLayout(journey: journey, layout: layout)
    }

    // Longest strands first, one per route number (ingest's selection).
    var arcsByStrand: [String: Double] = [:]
    for (key, strandLayout) in byStrand {
        guard strandLayout.layout.offsets.count >= 2 else { continue }
        var arc = 0.0
        let coordinates = journeyPolylines(
            strandLayout.journey,
            strandLayout.layout.polylineIndex
        )
        for index in 1..<coordinates.count {
            arc += coordinates[index - 1].projected
                .distance(to: coordinates[index].projected)
                * GeoProjection.metersPerUnit(
                    atLatitude: coordinates[index - 1].latitude
                )
        }
        arcsByStrand[key] = arc
    }
    let ranked = arcsByStrand.sorted { $0.value > $1.value }
    var seenRoutes = Set<String>()
    var spines: [(key: String, arc: Double)] = []
    for (key, arc) in ranked {
        let num = byStrand[key]!.journey.routeNumber
        if seenRoutes.contains(num) { continue }
        seenRoutes.insert(num)
        spines.append((key, arc))
        if spines.count >= 3 { break }
    }

    for spine in spines {
        let spineLayout = byStrand[spine.key]!
        print(
            "\n[stacking] along \(spineLayout.journey.routeNumber) "
                + "(\(spineLayout.journey.agency)), "
                + "\(Int(spine.arc)) m:"
        )
        let fractions = [0.08, 0.2, 0.35, 0.5, 0.65, 0.8, 0.92]
        let coordinates = journeyPolylines(
            spineLayout.journey,
            spineLayout.layout.polylineIndex
        )
        var arc = 0.0
        var arcs = [0.0]
        for index in 1..<coordinates.count {
            arc += coordinates[index - 1].projected
                .distance(to: coordinates[index].projected)
                * GeoProjection.metersPerUnit(
                    atLatitude: coordinates[index - 1].latitude
                )
            arcs.append(arc)
        }
        for fraction in fractions {
            let station = spine.arc * fraction
            guard let si = arcs.indices.min(by: {
                abs(arcs[$0] - station) < abs(arcs[$1] - station)
            }) else { continue }
            var rows: [(offset: Double, num: String)] = []
            for (key, strandLayout) in byStrand where key != spine.key {
                guard si < strandLayout.layout.offsets.count,
                      si < strandLayout.layout.shared.count,
                      strandLayout.layout.shared[si]
                else { continue }
                rows.append((
                    strandLayout.layout.offsets[si],
                    strandLayout.journey.routeNumber
                ))
            }
            rows.sort { $0.offset < $1.offset }
            let order = rows.map {
                String(
                    format: "%@(%+.1f)",
                    $0.num,
                    $0.offset / laneSpacing
                )
            }.joined(separator: " | ")
            var spineOffset = ""
            if si < spineLayout.layout.offsets.count,
               si < spineLayout.layout.shared.count,
               spineLayout.layout.shared[si] {
                spineOffset = String(
                    format: " spine %@(%+.1f)",
                    spineLayout.journey.routeNumber,
                    spineLayout.layout.offsets[si] / laneSpacing
                )
            }
            print(String(
                format: "  @ %6.0f m: %@%@",
                station,
                order,
                spineOffset
            ))
        }
    }
}

func journeyPolylines(
    _ journey: LaneDiagnosticsDocument.Journey,
    _ polylineIndex: Int
) -> [GeoCoordinate] {
    guard polylineIndex < journey.polylines.count else { return [] }
    return journey.polylines[polylineIndex]
}

let paths = fixturePaths()
if paths.isEmpty {
    print("no fixtures found (pass fixture paths as arguments)")
    exit(2)
}
for path in paths {
    let url = URL(fileURLWithPath: path)
    guard let doc = try? LaneDiagnosticsDocument(url: url) else {
        print("could not read \(path)")
        exit(2)
    }
    print("== \(url.lastPathComponent): \(doc.journeys.count) journeys, "
        + "\(doc.schedule.reduce(0) { $0 + $1.entries.count }) schedule rows")
    stationReport(doc)
}
