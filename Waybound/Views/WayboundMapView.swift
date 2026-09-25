import SwiftUI
import MapKit
import UIKit
import WayboundCore

struct WayboundCameraRequest: Equatable {
    let id = UUID()
    let region: MKCoordinateRegion

    static func == (lhs: WayboundCameraRequest, rhs: WayboundCameraRequest) -> Bool {
        lhs.id == rhs.id
    }
}

private enum RouteMapStyle {
    // Tube-map bold: strands stay legible from city scale down to the
    // street, with the ink separator — not color — keeping adjacent
    // lanes countable when several routes share one hue family.
    static let standardLineWidth: Double = 5.0
    static let selectedLineWidth: Double = 5.7
    /// The dark gap drawn between interlined lanes.
    static let separatorWidth: Double = 1.1
    static let trunkLineWidth: Double = 6.0
    static let trunkCasingExpansion: Double = 1.2
    /// The lane schedule's unit: every scheduled offset is a multiple of
    /// this. It must match `LaneScheduleConstants.laneSpacing` (4.2) — the
    /// schedule, layout, diagnostics export, and golden fixtures are all
    /// pinned to that unit, so the renderer rescales schedule units into
    /// the wider on-screen spacing instead of changing the unit itself.
    static let laneSpacingPoints = 4.2

    static func zoomLevel(for zoomScale: MKZoomScale) -> Double {
        log2(max(Double(zoomScale), 0.000_000_1)) + 20
    }

    /// Shared corridors are one frequency-colored trunk at city scale. Between
    /// zoom levels 13 and 14.75 they cross-fade into the close-up color ribbon.
    static func detailProgress(for zoomScale: MKZoomScale) -> Double {
        let linear = max(
            0,
            min(1, (zoomLevel(for: zoomScale) - 13) / 1.75)
        )
        // Smoothstep prevents a visible speed change at either end of the blend.
        return linear * linear * (3 - 2 * linear)
    }

    static func stopDetailProgress(for zoomScale: MKZoomScale) -> Double {
        let linear = max(
            0,
            min(1, (zoomLevel(for: zoomScale) - 13.75) / 0.75)
        )
        return linear * linear * (3 - 2 * linear)
    }

    /// Keep the network readable from neighborhood scale, then make it more
    /// tactile as the rider zooms toward individual streets and stops.
    static func zoomLineExpansion(for zoomScale: MKZoomScale) -> Double {
        let zoomLevel = zoomLevel(for: zoomScale)
        let progress = max(0, min(1, (zoomLevel - 13.75) / 3.5))
        return progress * 2.8
    }

    static func lineWidth(
        baseWidth: Double,
        zoomScale: MKZoomScale
    ) -> Double {
        baseWidth + zoomLineExpansion(for: zoomScale)
    }

    /// On-screen center distance between adjacent lanes. It grows slightly
    /// slower than the line width itself, so strands thicken as the rider
    /// zooms in without the whole ribbon ballooning wider than the street
    /// it represents — while the ink separator between colors survives.
    static func laneSpacing(for zoomScale: MKZoomScale) -> Double {
        standardLineWidth + zoomLineExpansion(for: zoomScale) * 0.85
            + separatorWidth
    }

    /// Rescales schedule-unit lane offsets (multiples of 4.2) into the
    /// wider on-screen spacing above.
    static func laneOffsetScale(for zoomScale: MKZoomScale) -> Double {
        laneSpacing(for: zoomScale) / laneSpacingPoints
    }

    /// Stop dots barely register at the zoom where they first fade in and are
    /// the primary interface at street level, so they grow across that range.
    static func stopSizeScale(for zoomScale: MKZoomScale) -> Double {
        let zoomLevel = zoomLevel(for: zoomScale)
        let progress = max(0, min(1, (zoomLevel - 14.5) / 2.0))
        return 1 + progress * 0.3
    }
}

struct WayboundMapView: UIViewRepresentable {
    let routes: [TransitRoute]
    let journeys: [RouteJourney]
    let stops: [TransitStop]
    let selectedJourneyID: Int?
    let selectedStopID: Int?
    let highlightedJourneyIDs: Set<Int>?
    let showsMapLadder: Bool
    let viewportBottomInset: CGFloat
    let cameraRequest: WayboundCameraRequest
    let onSelectJourney: (Int) -> Void
    let onSelectStop: (Int, Set<Int>, Set<Int>) -> Void
    /// Bump to make the coordinator dump its lane state (densified strand
    /// coordinates, the anchored-lane schedule, and the final per-vertex
    /// layouts) to a JSON file and present a share sheet for it. The debug
    /// Settings action is the only caller.
    var diagnosticsRequestID: Int = 0

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.tintColor = UIColor(WayboundPalette.routeColors[1])
        let mapConfiguration = MKStandardMapConfiguration(
            elevationStyle: .flat,
            emphasisStyle: .muted
        )
        // Waybound supplies its own transit stops and destination hierarchy.
        // Hide Apple's POI layer so incidental business and venue labels do not
        // compete with route strands; street and geographic labels remain visible.
        mapConfiguration.pointOfInterestFilter = .excludingAll
        mapView.preferredConfiguration = mapConfiguration

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.didTapMap(_:))
        )
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        mapView.addGestureRecognizer(tap)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.rebuildMapContent(on: mapView)
        if context.coordinator.lastCameraRequestID != cameraRequest.id {
            context.coordinator.lastCameraRequestID = cameraRequest.id
            mapView.setRegion(cameraRequest.region, animated: true)
        }
        if diagnosticsRequestID > 0,
           context.coordinator.lastDiagnosticsRequestID != diagnosticsRequestID {
            context.coordinator.lastDiagnosticsRequestID = diagnosticsRequestID
            context.coordinator.shareLaneDiagnostics(from: mapView)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: WayboundMapView
        var lastCameraRequestID: UUID?
        private var routeOverlays: [RouteLaneOverlay] = []
        private var corridorGeometryByJourneyID: [Int: CorridorJourneyGeometry] = [:]
        private var viewportRefreshWorkItem: DispatchWorkItem?
        private var lastRouteClipRect: MKMapRect?
        private var lastEscapeDrivenRefresh = Date.distantPast
        private var lastContentSignature: Int?
        private var lastPulsedJourneyID: Int?
        private var pulseTimer: Timer?
        private var corridorSignature: Int?
        /// Zero means no export has been requested. Matching the SwiftUI request
    /// counter prevents the coordinator's first update from presenting a
    /// share sheet at app launch.
    var lastDiagnosticsRequestID = 0
        /// Full-polyline lane layouts, computed once per corridor-content change
        /// and only clipped per viewport tick. Recomputing these on every pan
        /// frame was O(routes² × segments²) and drove the memory spikes that got
        /// the app jettisoned.
        private var laneLayoutsByJourneyID: [Int: [CorridorLaneLayout]] = [:]
        /// Anchored-lane schedule: one lane sample per (journey, flagship
        /// polyline, densified segment), computed once per corridor-content
        /// change alongside the layouts. Live departures never re-trigger it.
        private var corridorLaneSchedule:
            [CorridorLaneSchedule.StrandKey: [Int: CorridorLaneSchedule.Sample]] = [:]
        private var heldUnitDirectionsByStrand:
            [CorridorLaneSchedule.StrandKey: [(x: Double, y: Double)]] = [:]
        private var densifiedFlagshipCoordinatesByJourneyID:
            [Int: [[CLLocationCoordinate2D]]] = [:]

        init(parent: WayboundMapView) {
            self.parent = parent
        }

        func rebuildMapContent(on mapView: MKMapView) {
            // updateUIView runs on every SwiftUI state change — camera requests,
            // sheet interactions, timers — and a full teardown/re-add of every
            // annotation and overlay on each of those was constant allocation
            // churn. Rebuild only when something the map actually shows changed;
            // pure viewport work goes through the cheaper debounced refresh.
            let signature = contentSignature()
            guard signature != lastContentSignature else { return }
            lastContentSignature = signature

            viewportRefreshWorkItem?.cancel()
            mapView.removeOverlays(mapView.overlays)
            mapView.removeAnnotations(
                mapView.annotations.filter { !($0 is MKUserLocation) }
            )
            routeOverlays = []

            // Every stop through each flagship is a tiny route-colored dot. The
            // selected route's inline ladder replaces its dots rather than stacking
            // labels on top of them.
            mapView.addAnnotations(routeStopAnnotations())

            // Only each route's nearest boardable stop receives a prominent badge.
            // Nearby source records within one marker footprint become one cluster.
            mapView.addAnnotations(boardingStopAnnotations())

            if parent.showsMapLadder,
               let selectedID = parent.selectedJourneyID,
               let journey = parent.journeys.first(where: { $0.id == selectedID }) {
                for stop in journey.stops where !stop.isBoarding && !stop.isFlagship {
                    mapView.addAnnotation(
                        LadderStopMapAnnotation(stop: stop, journey: journey)
                    )
                }
            }

            refreshViewportContent(on: mapView)

            // In a dense corridor several routes share one hue family, so a
            // color chip alone cannot say "this line right here." A brief
            // pulse on the newly selected strand closes that gap. Added after
            // the rebuild so the teardown above cannot remove it mid-flight.
            if parent.selectedJourneyID != lastPulsedJourneyID {
                lastPulsedJourneyID = parent.selectedJourneyID
                pulseSelectedRoute(on: mapView)
            }
        }

        /// One soft, route-colored halo sweeps the selected strand and fades.
        /// It runs ~0.9 s and removes itself; selection state, not the pulse,
        /// carries the persistent emphasis.
        private func pulseSelectedRoute(on mapView: MKMapView) {
            pulseTimer?.invalidate()
            pulseTimer = nil
            for overlay in mapView.overlays where overlay is RoutePulseOverlay {
                mapView.removeOverlay(overlay)
            }
            guard let selectedID = parent.selectedJourneyID,
                  let journey = parent.journeys.first(where: {
                      $0.id == selectedID
                  })
            else { return }

            let polylines = journey.flagshipPolylines
                .filter { $0.count >= 2 }
                .map { MKPolyline(coordinates: $0, count: $0.count) }
            guard !polylines.isEmpty else { return }
            let pulse = RoutePulseOverlay(polylines)
            pulse.color = UIColor(journey.route.color)
            mapView.addOverlay(pulse, level: .aboveRoads)

            let pulseStart = Date()
            let pulseDuration: TimeInterval = 0.9
            pulseTimer = Timer.scheduledTimer(
                withTimeInterval: 1.0 / 30.0,
                repeats: true
            ) { [weak self, weak mapView, weak pulse] timer in
                guard let self, let mapView, let pulse else {
                    timer.invalidate()
                    return
                }
                let progress = Date().timeIntervalSince(pulseStart)
                    / pulseDuration
                guard progress < 1 else {
                    timer.invalidate()
                    self.pulseTimer = nil
                    mapView.removeOverlay(pulse)
                    return
                }
                if let renderer = mapView.renderer(for: pulse) {
                    // Ease-out fade: bright at tap, gone before it can nag.
                    renderer.alpha = CGFloat(pow(1 - progress, 1.6))
                }
            }
        }

        /// Everything the map draws is derived from these inputs. Journey IDs
        /// stand in for geometry because a RouteJourney's shape is immutable
        /// for the lifetime of its trip ID.
        private func contentSignature() -> Int {
            var hasher = Hasher()
            for journey in parent.journeys {
                hasher.combine(journey.id)
                hasher.combine(journey.observedDepartureCount)
            }
            hasher.combine(parent.selectedJourneyID)
            hasher.combine(parent.selectedStopID)
            hasher.combine(parent.highlightedJourneyIDs)
            hasher.combine(parent.showsMapLadder)
            hasher.combine(parent.viewportBottomInset)
            return hasher.finalize()
        }

        /// Corridor lanes depend on the journey set and on which route wins
        /// trunk dominance (selection/highlight), but not on the viewport.
        /// Recompute them only when one of those inputs changes; panning and
        /// zooming reuse the cached layouts and merely re-clip them.
        private func ensureCorridorLaneLayouts() {
            var hasher = Hasher()
            for journey in parent.journeys {
                hasher.combine(journey.id)
                hasher.combine(journey.observedDepartureCount)
            }
            hasher.combine(parent.selectedJourneyID)
            hasher.combine(parent.highlightedJourneyIDs)
            let signature = hasher.finalize()
            guard signature != corridorSignature else { return }
            corridorSignature = signature

            // Ribbon lanes and the far-zoom trunk are built only from the vivid
            // "where can I go" flagship paths. Approach geometry ("where the
            // bus has been") and post-destination continuations stay plain
            // centerlines: they may not claim a lane, mark another route's
            // flagship as shared, or win a trunk that would then be drawn
            // faded — or, for continuations, not drawn at all.
            // Densify once and share the coordinates between the member
            // index, the lane scheduler, and the layout pass below.
            corridorGeometryByJourneyID = [:]
            densifiedFlagshipCoordinatesByJourneyID = [:]
            for (index, journey) in parent.journeys.enumerated() {
                let densified = journey.flagshipPolylines
                    .filter { $0.count >= 2 }
                    .map { densifiedRouteCoordinates($0) }
                densifiedFlagshipCoordinatesByJourneyID[journey.id] = densified

                var indexedSegments: [MapRouteSegment] = []
                var segmentLocations: [CorridorSegmentLocation] = []
                for (polylineIndex, coordinates) in densified.enumerated() {
                    guard coordinates.count >= 2 else { continue }
                    for segmentIndex in 0..<(coordinates.count - 1) {
                        if let segment = MapRouteSegment(
                            start: MKMapPoint(coordinates[segmentIndex]),
                            end: MKMapPoint(coordinates[segmentIndex + 1])
                        ) {
                            indexedSegments.append(segment)
                            segmentLocations.append(
                                CorridorSegmentLocation(
                                    polylineIndex: polylineIndex,
                                    segmentIndex: segmentIndex
                                )
                            )
                        }
                    }
                }

                corridorGeometryByJourneyID[journey.id] =
                    CorridorJourneyGeometry(
                        stackOrder: index,
                        routeNumber: journey.route.routeNumber
                            ?? journey.route.shortName,
                        agencyName: journey.route.agencyName,
                        directionID: journey.directionID,
                        observedDepartureCount: journey.observedDepartureCount,
                        segmentIndex: CorridorSegmentIndex(
                            segments: indexedSegments,
                            locations: segmentLocations
                        )
                    )
            }

            // Anchored lanes: one global pass over every journey's flagship
            // strands. A strand keeps the lane it was given when it entered
            // a corridor for as long as it continues — the re-centring slide
            // that made shared-street ribbons braid is gone.
            let laneJourneys = recomputeCorridorLaneSchedule()
            let packageLayouts = CorridorLaneLayoutEngine.layouts(
                journeys: laneJourneys,
                schedule: corridorLaneSchedule,
                selectedJourneyID: parent.selectedJourneyID,
                laneSpacingPoints: RouteMapStyle.laneSpacingPoints,
                highlightedJourneyIDs: parent.highlightedJourneyIDs
            )

            laneLayoutsByJourneyID = [:]
            for journey in parent.journeys {
                let densified =
                    densifiedFlagshipCoordinatesByJourneyID[journey.id] ?? []
                laneLayoutsByJourneyID[journey.id] = densified.enumerated()
                    .compactMap { polylineIndex, coordinates in
                        guard coordinates.count >= 2 else { return nil }
                        let key = CorridorLaneSchedule.StrandKey(
                            journeyID: journey.id,
                            polylineIndex: polylineIndex
                        )
                        guard let packageLayout = packageLayouts[key]
                        else { return nil }
                        return sharedCorridorLaneLayout(
                            for: coordinates,
                            journeyID: journey.id,
                            polylineIndex: polylineIndex,
                            packageLayout: packageLayout
                        )
                    }
            }
        }

        /// Export the lane state (see exportLaneDiagnostics) and present a
        /// UIKit share sheet for the file, walked up from the map view. The
        /// presentation is dispatched async: this runs inside updateUIView,
        /// where presenting (or touching SwiftUI state) mid-update would be
        /// dropped.
        fileprivate func shareLaneDiagnostics(from mapView: MKMapView) {
            guard let url = exportLaneDiagnostics() else { return }
            DispatchQueue.main.async {
                let share = UIActivityViewController(
                    activityItems: [url],
                    applicationActivities: nil
                )
                share.popoverPresentationController?.sourceView = mapView
                var responder: UIResponder? = mapView
                while let current = responder,
                      !(current is UIViewController) {
                    responder = current.next
                }
                guard let presenter = responder as? UIViewController else {
                    return
                }
                presenter.present(share, animated: true)
            }
        }

        /// Dump the corridor lane state to a JSON file for offline
        /// diagnosis: per journey the densified flagship coordinates (the
        /// scheduler's exact input), the anchored-lane schedule (offset,
        /// spine direction, reference per strand segment), and the final
        /// per-vertex layouts the renderer consumes. `waybound-lanelab` and
        /// the WayboundCore golden tests rebuild the same shapes, so a
        /// reported visual can be reproduced numerically.
        fileprivate func exportLaneDiagnostics() -> URL? {
            ensureCorridorLaneLayouts()
            var root: [String: Any] = [
                "format": "waybound-lanes-v1",
                "exportedAt": Date().timeIntervalSince1970,
                "laneSpacingPoints": RouteMapStyle.laneSpacingPoints,
                "selectedJourneyID": parent.selectedJourneyID ?? -1
            ]
            var journeys = [[String: Any]]()
            for journey in parent.journeys {
                guard let geometry = corridorGeometryByJourneyID[journey.id]
                else { continue }
                journeys.append([
                    "id": journey.id,
                    "routeNumber": geometry.routeNumber,
                    "agency": geometry.agencyName,
                    "directionID": geometry.directionID ?? -1,
                    "stackOrder": geometry.stackOrder,
                    "departures": geometry.observedDepartureCount,
                    "polylines": (densifiedFlagshipCoordinatesByJourneyID[
                        journey.id
                    ] ?? []).map { polyline in
                        polyline.map { [$0.latitude, $0.longitude] }
                    }
                ])
            }
            root["journeys"] = journeys

            var schedule = [[String: Any]]()
            for (key, entries) in corridorLaneSchedule {
                schedule.append([
                    "journeyID": key.journeyID,
                    "polylineIndex": key.polylineIndex,
                    "entries": entries
                        .sorted { $0.key < $1.key }
                        .map { index, sample in
                            [index, sample.offset, sample.directionX,
                             sample.directionY, sample.referenceID] as [Any]
                        }
                ])
            }
            root["schedule"] = schedule

            var layouts = [[String: Any]]()
            for (journeyID, laneLayouts) in laneLayoutsByJourneyID {
                for (polylineIndex, layout) in laneLayouts.enumerated() {
                    layouts.append([
                        "journeyID": journeyID,
                        "polylineIndex": polylineIndex,
                        "offsets": layout.offsets,
                        "shared": layout.sharedVertices.map { $0 ? 1 : 0 },
                        "trunk": layout.trunkOwnerVertices.map { $0 ? 1 : 0 }
                    ])
                }
            }
            root["layouts"] = layouts

            guard JSONSerialization.isValidJSONObject(root),
                  let data = try? JSONSerialization.data(
                      withJSONObject: root,
                      options: [.sortedKeys]
                  )
            else { return nil }
            let stamp = Int(Date().timeIntervalSince1970)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("waybound-lanes-\(stamp).json")
            do {
                try data.write(to: url)
                return url
            } catch {
                return nil
            }
        }

        /// Approach and continuation context lines take no lane and join no
        /// corridor; they draw exactly on their own centerline.
        private func plainLaneLayouts(
            for polylines: [[CLLocationCoordinate2D]]
        ) -> [CorridorLaneLayout] {
            polylines.compactMap { coordinates in
                guard coordinates.count >= 2 else { return nil }
                return CorridorLaneLayout(
                    coordinates: coordinates,
                    offsets: Array(repeating: 0, count: coordinates.count),
                    sharedVertices: Array(
                        repeating: false,
                        count: coordinates.count
                    ),
                    trunkOwnerVertices: Array(
                        repeating: false,
                        count: coordinates.count
                    )
                )
            }
        }

        /// Split a cached lane layout into the runs whose segments touch the
        /// padded viewport. Vertices are kept whole rather than trimmed to the
        /// exact boundary: the clip rect already extends 1.5 screens past the
        /// visible edge, and preserving vertices keeps every per-vertex lane
        /// attribute valid without interpolation.
        private func clippedLaneLayouts(
            _ layouts: [CorridorLaneLayout],
            to rect: MKMapRect
        ) -> [CorridorLaneLayout] {
            layouts.flatMap { layout -> [CorridorLaneLayout] in
                let count = layout.coordinates.count
                guard count >= 2,
                      layout.offsets.count == count,
                      layout.sharedVertices.count == count,
                      layout.trunkOwnerVertices.count == count
                else { return [] }
                let points = layout.coordinates.map { MKMapPoint($0) }
                var result: [CorridorLaneLayout] = []
                var runStart: Int?

                func closeRun(at lastVertex: Int) {
                    guard let start = runStart, lastVertex > start else {
                        runStart = nil
                        return
                    }
                    result.append(
                        CorridorLaneLayout(
                            coordinates: Array(
                                layout.coordinates[start...lastVertex]
                            ),
                            offsets: Array(layout.offsets[start...lastVertex]),
                            sharedVertices: Array(
                                layout.sharedVertices[start...lastVertex]
                            ),
                            trunkOwnerVertices: Array(
                                layout.trunkOwnerVertices[start...lastVertex]
                            )
                        )
                    )
                    runStart = nil
                }

                for index in 0..<(count - 1) {
                    let segmentIsVisible = clippedSegment(
                        from: points[index],
                        to: points[index + 1],
                        inside: rect
                    ) != nil
                    if segmentIsVisible {
                        if runStart == nil { runStart = index }
                    } else {
                        closeRun(at: index)
                    }
                }
                closeRun(at: count - 1)
                return result
            }
        }

        /// Centerlines clip to the real drawable map boundary: the screen edges and
        /// the exact top of the sheet. Destination cards use a separate safe layout
        /// rectangle, so keeping labels readable never shortens the route itself.
        private func refreshViewportContent(on mapView: MKMapView) {
            mapView.removeOverlays(
                mapView.overlays.filter { $0 is RouteLaneOverlay }
            )
            mapView.removeAnnotations(
                mapView.annotations.filter { $0 is DestinationMapAnnotation }
            )
            routeOverlays = []

            guard let visibleRouteViewport = routeViewportMapRect(in: mapView),
                  let tagViewport = destinationTagViewportMapRect(in: mapView)
            else { return }
            // Clip against a generously padded viewport rather than the exact
            // screen. Pinch-zooming out then reveals geometry that is already
            // drawn instead of waiting for the debounced rebuild, which used to
            // show cropped line ends for a beat at every zoom-out.
            let routeViewport = visibleRouteViewport.insetBy(
                dx: -visibleRouteViewport.size.width * 1.5,
                dy: -visibleRouteViewport.size.height * 1.5
            )
            lastRouteClipRect = routeViewport
            let selectedID = parent.selectedJourneyID
            let highlightedJourneyIDs = parent.highlightedJourneyIDs
            ensureCorridorLaneLayouts()

            // Draw the already-travelled portion underneath every active route.
            // It answers "where is this bus coming from?" without competing with
            // the path the rider can still take from the boarding stop. It is
            // deliberately plain context: it stays on its own centerline and
            // never joins the corridor ribbon or the far-zoom trunk.
            for journey in parent.journeys {
                let isHighlighted = highlightedJourneyIDs?.contains(journey.id) ?? true
                addOverlays(
                    layouts: plainLaneLayouts(
                        for: clippedPolylines(
                            journey.approachPolylines,
                            to: routeViewport
                        )
                    ),
                    journeyID: journey.id,
                    color: UIColor(journey.route.color),
                    opacity: isHighlighted ? 0.22 : 0.05,
                    lineWidth: RouteMapStyle.standardLineWidth,
                    isSelected: selectedID == journey.id,
                    dashed: false,
                    to: mapView
                )
            }

            for journey in parent.journeys {
                let isSelected = selectedID == journey.id
                let isHighlighted = highlightedJourneyIDs?.contains(journey.id) ?? true
                let opacity = isHighlighted ? 0.94 : 0.12
                addOverlays(
                    layouts: clippedLaneLayouts(
                        laneLayoutsByJourneyID[journey.id] ?? [],
                        to: routeViewport
                    ),
                    journeyID: journey.id,
                    color: UIColor(journey.route.color),
                    opacity: opacity,
                    lineWidth: isSelected
                        ? RouteMapStyle.selectedLineWidth
                        : (isHighlighted ? RouteMapStyle.standardLineWidth : 4.0),
                    isSelected: isSelected,
                    dashed: false,
                    to: mapView
                )

                if isSelected && parent.showsMapLadder {
                    addOverlays(
                        layouts: plainLaneLayouts(
                            for: clippedPolylines(
                                journey.continuationPolylines,
                                to: routeViewport
                            )
                        ),
                        journeyID: journey.id,
                        color: UIColor(journey.route.color),
                        opacity: 0.58,
                        lineWidth: RouteMapStyle.standardLineWidth,
                        isSelected: true,
                        dashed: true,
                        to: mapView
                    )
                }
            }

            // Tags are ranked, collision-tested before insertion, and explicitly
            // budgeted. Selecting a route bypasses the overview budget, so every
            // route remains discoverable without forcing six labels onto the map.
            // A tag that would land on another tag or a boarding marker tries
            // the mirror placements before giving up its budget slot.
            var occupiedTagFrames: [CGRect] = []
            var insertedTagCount = 0
            let tagBudget = destinationTagBudget(in: mapView)
            let clusterExclusions = boardingClusterExclusionRects(in: mapView)
            for (rank, journey) in parent.journeys.enumerated()
            where selectedID == nil || journey.id == selectedID {
                guard insertedTagCount < tagBudget,
                      let anchor = destinationAnchor(
                        for: journey,
                        in: tagViewport
                      )
                else { continue }

                let anchorPoint = mapView.convert(
                    anchor.coordinate,
                    toPointTo: mapView
                )
                let candidates = destinationTagCandidates(
                    at: anchorPoint,
                    edge: anchor.edge,
                    in: mapView
                )
                var chosen: DestinationTagLayout?
                for layout in candidates {
                    let collisionFrame = layout.frame.insetBy(dx: -8, dy: -6)
                    guard selectedID != nil || occupiedTagFrames.allSatisfy({
                        !$0.intersects(collisionFrame)
                    }) else { continue }
                    guard !clusterExclusions.contains(where: {
                        $0.intersects(collisionFrame)
                    }) else { continue }
                    chosen = layout
                    break
                }
                if chosen == nil {
                    // A selected route's tag always shows: accept the
                    // preferred placement even over a boarding marker rather
                    // than hiding the one label that names the selection.
                    guard selectedID != nil, let preferred = candidates.first
                    else { continue }
                    chosen = preferred
                }
                guard let layout = chosen else { continue }

                occupiedTagFrames.append(layout.frame.insetBy(dx: -8, dy: -6))
                insertedTagCount += 1
                mapView.addAnnotation(
                    DestinationMapAnnotation(
                        journey: journey,
                        coordinate: anchor.coordinate,
                        edge: anchor.edge,
                        rank: rank,
                        isSelected: journey.id == selectedID,
                        isDimmed: highlightedJourneyIDs.map {
                            !$0.contains(journey.id)
                        } ?? false,
                        viewCenterOffset: layout.centerOffset,
                        pinCenter: layout.pinCenter
                    )
                )
            }
            updateRouteStopVisibility(on: mapView)
        }

        private func destinationTagBudget(in mapView: MKMapView) -> Int {
            if parent.selectedJourneyID != nil { return 1 }
            let usableHeight = mapView.bounds.height
                - parent.viewportBottomInset
                - mapView.safeAreaInsets.top
            return mapView.bounds.width < 390 || usableHeight < 350 ? 3 : 4
        }

        private struct DestinationTagLayout {
            let frame: CGRect
            let centerOffset: CGPoint
            let pinCenter: CGPoint
        }

        /// Preferred placement plus mirror alternates for one destination tag.
        /// Must match `DestinationAnnotationView`'s frame exactly: the layout
        /// frame is what collision-testing sees, the view is what draws.
        private func destinationTagCandidates(
            at anchor: CGPoint,
            edge: DestinationViewportEdge,
            in mapView: MKMapView
        ) -> [DestinationTagLayout] {
            let size = CGSize(width: 184, height: 54)
            let preferred: CGPoint
            switch edge {
            case .inside, .bottom:
                preferred = CGPoint(x: 0, y: -size.height / 2)
            case .top:
                preferred = CGPoint(x: 0, y: size.height / 2)
            case .right:
                preferred = CGPoint(x: -size.width / 2, y: 0)
            case .left:
                preferred = CGPoint(x: size.width / 2, y: 0)
            }
            let alternates = [
                preferred,
                CGPoint(x: preferred.x, y: -preferred.y),
                CGPoint(x: -preferred.x, y: preferred.y),
                CGPoint(x: -preferred.x, y: -preferred.y),
            ]
            // A zero component flips to itself; keep first-seen order.
            var seenOffsets = Set<String>()
            var seenFrames = Set<String>()
            var layouts: [DestinationTagLayout] = []
            for offset in alternates {
                guard seenOffsets.insert("\(offset.x),\(offset.y)").inserted
                else { continue }
                let layout = destinationTagLayout(
                    at: anchor,
                    preferredOffset: offset,
                    size: size,
                    in: mapView
                )
                // Safe-rect clamping can collapse two mirrors onto one frame.
                guard seenFrames.insert("\(layout.frame)").inserted else { continue }
                layouts.append(layout)
            }
            return layouts
        }

        private func destinationTagLayout(
            at anchor: CGPoint,
            preferredOffset: CGPoint,
            size: CGSize,
            in mapView: MKMapView
        ) -> DestinationTagLayout {
            let width = size.width
            let height = size.height
            let safeRect = destinationLabelScreenRect(in: mapView)
            let minimumCenterX = safeRect.minX + width / 2
            let maximumCenterX = safeRect.maxX - width / 2
            let minimumCenterY = safeRect.minY + height / 2
            let maximumCenterY = safeRect.maxY - height / 2
            let preferredCenter = CGPoint(
                x: anchor.x + preferredOffset.x,
                y: anchor.y + preferredOffset.y
            )
            let center = CGPoint(
                x: max(minimumCenterX, min(maximumCenterX, preferredCenter.x)),
                y: max(minimumCenterY, min(maximumCenterY, preferredCenter.y))
            )
            let frame = CGRect(
                x: center.x - width / 2,
                y: center.y - height / 2,
                width: width,
                height: height
            )
            return DestinationTagLayout(
                frame: frame,
                centerOffset: CGPoint(
                    x: center.x - anchor.x,
                    y: center.y - anchor.y
                ),
                pinCenter: CGPoint(
                    x: max(4.5, min(width - 4.5, anchor.x - frame.minX)),
                    y: max(4.5, min(height - 4.5, anchor.y - frame.minY))
                )
            )
        }

        /// Screen rectangles the destination tags must not cover: one per
        /// boarding cluster, sized from its route numbers the same way the
        /// marker view sizes itself, then inflated by the tag collision
        /// padding so a tag never even grazes a marker.
        private func boardingClusterExclusionRects(in mapView: MKMapView) -> [CGRect] {
            mapView.annotations.compactMap { annotation -> CGRect? in
                guard let cluster = annotation as? StopClusterMapAnnotation
                else { return nil }
                let point = mapView.convert(cluster.coordinate, toPointTo: mapView)
                // Mirrors StopClusterAnnotationView at its 12 pt route font:
                // ~7.2 pt per monospaced glyph plus the double-space gaps on
                // a 28 pt pill, then inflated so a tag never grazes a marker.
                var seenNumbers = Set<String>()
                var textWidth: CGFloat = 0
                for number in cluster.routeNumbers {
                    guard seenNumbers.insert(number).inserted else { continue }
                    if textWidth > 0 { textWidth += 13 }
                    textWidth += CGFloat(number.count) * 7.2
                }
                let width = max(30, ceil(textWidth) + 16) + 16
                let height: CGFloat = 28 + 12
                return CGRect(
                    x: point.x - width / 2,
                    y: point.y - height / 2,
                    width: width,
                    height: height
                )
            }
        }

        private func routeStopVisibility(
            for routeStop: RouteStopMapAnnotation,
            on mapView: MKMapView
        ) -> Double {
            let belongsToSelectedRoute = parent.selectedJourneyID.map {
                routeStop.routeIDs.contains($0)
            } ?? false
            if belongsToSelectedRoute { return 1 }
            let zoomScale = MKZoomScale(
                Double(mapView.bounds.width)
                    / max(1, mapView.visibleMapRect.size.width)
            )
            return RouteMapStyle.stopDetailProgress(for: zoomScale)
        }

        private func currentZoomScale(in mapView: MKMapView) -> MKZoomScale {
            MKZoomScale(
                Double(mapView.bounds.width)
                    / max(1, mapView.visibleMapRect.size.width)
            )
        }

        private func updateRouteStopVisibility(on mapView: MKMapView) {
            let zoomScale = currentZoomScale(in: mapView)
            for annotation in mapView.annotations {
                guard let routeStop = annotation as? RouteStopMapAnnotation,
                      let view = mapView.view(for: routeStop)
                        as? RouteStopAnnotationView
                else { continue }
                view.setZoomVisibility(
                    routeStopVisibility(for: routeStop, on: mapView),
                    zoomScale: zoomScale
                )
            }
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            updateRouteStopVisibility(on: mapView)

            // While the camera stays inside the padded clip rect the overlays
            // already cover everything on screen, so the refresh can wait for
            // the debounce. Once the visible region escapes that padding — a
            // fast zoom-out or fling — rebuild immediately (throttled) so line
            // ends never sit visibly cropped while the user watches.
            if let clipRect = lastRouteClipRect,
               let visibleRect = routeViewportMapRect(in: mapView),
               !mapRect(clipRect, contains: visibleRect),
               Date().timeIntervalSince(lastEscapeDrivenRefresh) > 0.12 {
                lastEscapeDrivenRefresh = Date()
                viewportRefreshWorkItem?.cancel()
                refreshViewportContent(on: mapView)
                return
            }

            viewportRefreshWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self, weak mapView] in
                guard let self, let mapView else { return }
                self.refreshViewportContent(on: mapView)
            }
            viewportRefreshWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: workItem)
        }

        private func mapRect(
            _ outer: MKMapRect,
            contains inner: MKMapRect
        ) -> Bool {
            inner.minX >= outer.minX && inner.maxX <= outer.maxX
                && inner.minY >= outer.minY && inner.maxY <= outer.maxY
        }

        private func routeViewportMapRect(in mapView: MKMapView) -> MKMapRect? {
            let sheetTop = max(
                mapView.bounds.minY,
                mapView.bounds.maxY - parent.viewportBottomInset
            )
            let screenRect = CGRect(
                x: mapView.bounds.minX,
                y: mapView.bounds.minY,
                width: mapView.bounds.width,
                height: sheetTop - mapView.bounds.minY
            )
            return mapRect(for: screenRect, in: mapView)
        }

        private func destinationTagViewportMapRect(
            in mapView: MKMapView
        ) -> MKMapRect? {
            mapRect(for: destinationLabelScreenRect(in: mapView), in: mapView)
        }

        private func destinationLabelScreenRect(in mapView: MKMapView) -> CGRect {
            let horizontalMargin: CGFloat = 6
            let top = max(
                mapView.bounds.minY + 6,
                mapView.safeAreaInsets.top + 4
            )
            let sheetTop = mapView.bounds.maxY - parent.viewportBottomInset
            let bottom = min(
                mapView.bounds.maxY - 6,
                sheetTop - 6
            )
            return CGRect(
                x: mapView.bounds.minX + horizontalMargin,
                y: top,
                width: max(184, mapView.bounds.width - horizontalMargin * 2),
                height: max(54, bottom - top)
            )
        }

        private func mapRect(
            for screenRect: CGRect,
            in mapView: MKMapView
        ) -> MKMapRect? {
            guard screenRect.width > 80, screenRect.height > 80 else { return nil }
            let screenPoints = [
                CGPoint(x: screenRect.minX, y: screenRect.minY),
                CGPoint(x: screenRect.maxX, y: screenRect.minY),
                CGPoint(x: screenRect.maxX, y: screenRect.maxY),
                CGPoint(x: screenRect.minX, y: screenRect.maxY),
            ]
            let mapPoints = screenPoints.map {
                MKMapPoint(mapView.convert($0, toCoordinateFrom: mapView))
            }
            guard let first = mapPoints.first else { return nil }
            let minimumX = mapPoints.dropFirst().reduce(first.x) { min($0, $1.x) }
            let maximumX = mapPoints.dropFirst().reduce(first.x) { max($0, $1.x) }
            let minimumY = mapPoints.dropFirst().reduce(first.y) { min($0, $1.y) }
            let maximumY = mapPoints.dropFirst().reduce(first.y) { max($0, $1.y) }
            return MKMapRect(
                x: minimumX,
                y: minimumY,
                width: maximumX - minimumX,
                height: maximumY - minimumY
            )
        }

        private func clippedPolylines(
            _ polylines: [[CLLocationCoordinate2D]],
            to rect: MKMapRect
        ) -> [[CLLocationCoordinate2D]] {
            polylines.flatMap { coordinates -> [[CLLocationCoordinate2D]] in
                guard coordinates.count >= 2 else { return [] }
                var result: [[CLLocationCoordinate2D]] = []
                var current: [CLLocationCoordinate2D] = []

                func finishCurrent() {
                    if current.count >= 2 { result.append(current) }
                    current = []
                }

                for index in 0..<(coordinates.count - 1) {
                    let start = MKMapPoint(coordinates[index])
                    let end = MKMapPoint(coordinates[index + 1])
                    guard let clipped = clippedSegment(
                        from: start,
                        to: end,
                        inside: rect
                    ) else {
                        finishCurrent()
                        continue
                    }

                    let clippedStart = clipped.start.coordinate
                    let clippedEnd = clipped.end.coordinate
                    if let previous = current.last,
                       MKMapPoint(previous).distance(to: clipped.start) > 0.25 {
                        finishCurrent()
                    }
                    if current.isEmpty { current.append(clippedStart) }
                    if MKMapPoint(current.last!).distance(to: clipped.end) > 0.05 {
                        current.append(clippedEnd)
                    }
                }
                finishCurrent()
                return result
            }
        }

        private func destinationAnchor(
            for journey: RouteJourney,
            in rect: MKMapRect
        ) -> (coordinate: CLLocationCoordinate2D, edge: DestinationViewportEdge)? {
            let destination = MKMapPoint(journey.destinationCoordinate)
            if contains(destination, in: rect) {
                return (journey.destinationCoordinate, .inside)
            }

            var hasEnteredViewport = false
            var lastVisiblePoint: MKMapPoint?
            for coordinates in journey.flagshipPolylines where coordinates.count >= 2 {
                for index in 0..<(coordinates.count - 1) {
                    let start = MKMapPoint(coordinates[index])
                    let end = MKMapPoint(coordinates[index + 1])
                    let startIsInside = contains(start, in: rect)
                    let endIsInside = contains(end, in: rect)
                    let clipped = clippedSegment(from: start, to: end, inside: rect)

                    if startIsInside { hasEnteredViewport = true }
                    if let clipped { lastVisiblePoint = clipped.end }

                    if hasEnteredViewport, !endIsInside, let clipped {
                        return (
                            clipped.end.coordinate,
                            nearestEdge(to: clipped.end, in: rect)
                        )
                    }
                    if !startIsInside, endIsInside {
                        hasEnteredViewport = true
                    } else if !startIsInside, !endIsInside,
                              !hasEnteredViewport, let clipped {
                        // A long segment can cross the entire viewport without a
                        // source vertex landing inside it.
                        return (
                            clipped.end.coordinate,
                            nearestEdge(to: clipped.end, in: rect)
                        )
                    }
                }
            }

            guard let lastVisiblePoint else { return nil }
            return (
                lastVisiblePoint.coordinate,
                nearestEdge(to: lastVisiblePoint, in: rect)
            )
        }

        private func contains(_ point: MKMapPoint, in rect: MKMapRect) -> Bool {
            point.x >= rect.minX && point.x <= rect.maxX
                && point.y >= rect.minY && point.y <= rect.maxY
        }

        private func nearestEdge(
            to point: MKMapPoint,
            in rect: MKMapRect
        ) -> DestinationViewportEdge {
            let distances: [(DestinationViewportEdge, Double)] = [
                (.left, abs(point.x - rect.minX)),
                (.right, abs(point.x - rect.maxX)),
                (.top, abs(point.y - rect.minY)),
                (.bottom, abs(point.y - rect.maxY)),
            ]
            return distances.min { $0.1 < $1.1 }?.0 ?? .inside
        }

        private func clippedSegment(
            from start: MKMapPoint,
            to end: MKMapPoint,
            inside rect: MKMapRect
        ) -> (start: MKMapPoint, end: MKMapPoint)? {
            let deltaX = end.x - start.x
            let deltaY = end.y - start.y
            var lower = 0.0
            var upper = 1.0

            func update(_ denominator: Double, _ numerator: Double) -> Bool {
                if abs(denominator) < 0.000_000_001 {
                    return numerator >= 0
                }
                let ratio = numerator / denominator
                if denominator < 0 {
                    if ratio > upper { return false }
                    lower = max(lower, ratio)
                } else {
                    if ratio < lower { return false }
                    upper = min(upper, ratio)
                }
                return true
            }

            guard update(-deltaX, start.x - rect.minX),
                  update(deltaX, rect.maxX - start.x),
                  update(-deltaY, start.y - rect.minY),
                  update(deltaY, rect.maxY - start.y),
                  upper >= lower
            else { return nil }

            return (
                MKMapPoint(
                    x: start.x + lower * deltaX,
                    y: start.y + lower * deltaY
                ),
                MKMapPoint(
                    x: start.x + upper * deltaX,
                    y: start.y + upper * deltaY
                )
            )
        }

        private struct RouteStopMarker {
            let stop: JourneyStop
            let journey: RouteJourney
        }

        private func routeStopAnnotations() -> [RouteStopMapAnnotation] {
            let mergeDistance: CLLocationDistance = 12
            let boardingStopSuppressionDistance: CLLocationDistance = 28
            let boardingStopLocations = parent.journeys.map {
                CLLocation(
                    latitude: $0.boardingStop.coordinate.latitude,
                    longitude: $0.boardingStop.coordinate.longitude
                )
            }
            var groups: [[RouteStopMarker]] = []

            for journey in parent.journeys {
                if parent.showsMapLadder,
                   parent.selectedJourneyID == journey.id {
                    continue
                }
                guard let flagshipIndex = journey.stops.firstIndex(where: {
                    $0.isFlagship
                }) else { continue }

                for stop in journey.stops[...flagshipIndex] where !stop.isBoarding {
                    let marker = RouteStopMarker(stop: stop, journey: journey)
                    let location = CLLocation(
                        latitude: stop.coordinate.latitude,
                        longitude: stop.coordinate.longitude
                    )
                    if let groupIndex = groups.firstIndex(where: { group in
                        group.contains { member in
                            let memberLocation = CLLocation(
                                latitude: member.stop.coordinate.latitude,
                                longitude: member.stop.coordinate.longitude
                            )
                            return location.distance(from: memberLocation)
                                <= mergeDistance
                        }
                    }) {
                        groups[groupIndex].append(marker)
                    } else {
                        groups.append([marker])
                    }
                }
            }

            return groups.compactMap { group in
                guard let first = group.first else { return nil }
                let coordinate = CLLocationCoordinate2D(
                    latitude: group.map { $0.stop.coordinate.latitude }
                        .reduce(0, +) / Double(group.count),
                    longitude: group.map { $0.stop.coordinate.longitude }
                        .reduce(0, +) / Double(group.count)
                )
                let markerLocation = CLLocation(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                )
                // A prominent boarding marker already represents this physical
                // stop. Do not also place a small route dot where it can sit on top.
                guard boardingStopLocations.allSatisfy({ location in
                    markerLocation.distance(from: location) >
                        boardingStopSuppressionDistance
                }) else { return nil }

                let sortedJourneys = group.map(\.journey).sorted {
                    $0.route.fullDisplayName.localizedStandardCompare(
                        $1.route.fullDisplayName
                    ) == .orderedAscending
                }
                var seenRouteNumbers: Set<String> = []
                let uniqueJourneys = sortedJourneys.filter {
                    seenRouteNumbers.insert($0.route.routeNumber ?? $0.route.shortName)
                        .inserted
                }
                let journeyIDs = Set(sortedJourneys.map(\.id))
                let isDimmed = parent.highlightedJourneyIDs.map {
                    journeyIDs.isDisjoint(with: $0)
                } ?? false
                return RouteStopMapAnnotation(
                    coordinate: coordinate,
                    name: first.stop.name,
                    routeIDs: journeyIDs,
                    colors: uniqueJourneys.map { UIColor($0.route.color) },
                    isDimmed: isDimmed
                )
            }
        }

        private func boardingStopAnnotations() -> [StopClusterMapAnnotation] {
            let mergeDistance: CLLocationDistance = 28
            var groups: [[RouteJourney]] = []

            for journey in parent.journeys {
                let location = CLLocation(
                    latitude: journey.boardingStop.coordinate.latitude,
                    longitude: journey.boardingStop.coordinate.longitude
                )
                if let groupIndex = groups.firstIndex(where: { group in
                    group.contains { member in
                        let memberLocation = CLLocation(
                            latitude: member.boardingStop.coordinate.latitude,
                            longitude: member.boardingStop.coordinate.longitude
                        )
                        return location.distance(from: memberLocation) <= mergeDistance
                    }
                }) {
                    groups[groupIndex].append(journey)
                } else {
                    groups.append([journey])
                }
            }

            return groups.compactMap { group in
                guard let representative = group.min(by: {
                    if $0.walkMinutes != $1.walkMinutes {
                        return $0.walkMinutes < $1.walkMinutes
                    }
                    return $0.departureDate < $1.departureDate
                }) else { return nil }

                let sortedJourneys = group.sorted {
                    $0.route.fullDisplayName.localizedStandardCompare(
                        $1.route.fullDisplayName
                    ) == .orderedAscending
                }
                let journeyIDs = Set(sortedJourneys.map(\.id))
                let routeIDs = Set(
                    sortedJourneys.map { $0.route.transitlandID }
                )
                let colors = sortedJourneys.map { UIColor($0.route.color) }
                let isDimmed = parent.highlightedJourneyIDs.map {
                    journeyIDs.isDisjoint(with: $0)
                } ?? false
                return StopClusterMapAnnotation(
                    stop: representative.boardingStop,
                    sourceStopIDs: Set(group.map { $0.boardingStop.id }),
                    routeIDs: routeIDs,
                    journeyIDs: journeyIDs,
                    routeNumbers: sortedJourneys.compactMap { $0.route.routeNumber },
                    colors: colors,
                    isDimmed: isDimmed,
                    isSelected: group.contains {
                        $0.boardingStop.id == parent.selectedStopID
                    }
                )
            }
        }

        private func addOverlays(
            layouts: [CorridorLaneLayout],
            journeyID: Int,
            color: UIColor,
            opacity: Double,
            lineWidth: Double,
            isSelected: Bool,
            dashed: Bool,
            to mapView: MKMapView
        ) {
            for laneLayout in layouts where laneLayout.coordinates.count >= 2 {
                let overlay = RouteLaneOverlay(
                    coordinates: laneLayout.coordinates,
                    journeyID: journeyID,
                    color: color,
                    opacity: opacity,
                    lineWidth: lineWidth,
                    laneOffsetPoints: laneLayout.offsets,
                    sharedCorridorVertices: laneLayout.sharedVertices,
                    trunkOwnerVertices: laneLayout.trunkOwnerVertices,
                    isSelected: isSelected,
                    dashed: dashed
                )
                routeOverlays.append(overlay)
                mapView.addOverlay(overlay, level: .aboveRoads)
            }
        }

        private func densifiedRouteCoordinates(
            _ coordinates: [CLLocationCoordinate2D]
        ) -> [CLLocationCoordinate2D] {
            // True meters: MKMapPoint distances are projected units (~8.1 per
            // meter in Santa Barbara), and dividing by the raw threshold
            // sampled shapes eight times more densely than intended — the
            // vertex counts behind the layout-pass memory spikes.
            let maximumSegmentLength: CLLocationDistance = 18
            guard coordinates.count >= 2 else { return coordinates }
            let metersPerMapPoint = TripPathGeometry.metersPerMapPoint(
                atLatitude: coordinates[0].latitude
            )
            let maximumSegmentMapPoints = maximumSegmentLength / metersPerMapPoint
            var result = [coordinates[0]]

            for index in 0..<(coordinates.count - 1) {
                let start = MKMapPoint(coordinates[index])
                let end = MKMapPoint(coordinates[index + 1])
                let distance = start.distance(to: end)
                let subdivisionCount = max(
                    1,
                    Int(ceil(distance / maximumSegmentMapPoints))
                )
                for subdivision in 1...subdivisionCount {
                    let progress = Double(subdivision) / Double(subdivisionCount)
                    result.append(
                        MKMapPoint(
                            x: start.x + (end.x - start.x) * progress,
                            y: start.y + (end.y - start.y) * progress
                        ).coordinate
                    )
                }
            }
            return result
        }

        /// Isolated geometry remains on its authoritative GTFS centerline. Routes
        /// sharing one road first align to a single local corridor spine and then
        /// receive consecutive screen-space lanes. This produces one compact ribbon
        /// instead of several almost-parallel shapes drifting across the road.
        // MARK: - Anchored lane scheduling
        //
        // Mirrors tools/replay/lanesched.py (the executable spec). One pass
        // per connected group of shared runs ("corridor"): a strand's lane is
        // chosen once, when it enters the corridor, and is held while it
        // continues; joiners enter at the outer edge of their approach side;
        // leavers keep their lane and peel away; freed slots are remembered so
        // a dropout-and-return reclaims its own lane; corridor-birth order is
        // exit-aware (first strand to peel off on a side sits outermost there,
        // which minimises fork crossings); opposite travel directions stay on
        // opposite sides of the centreline. The schedule stores, per strand
        // segment, the lane offset expressed against the sweeping spine's
        // travel direction plus the sticky reference journey; observers
        // convert into their own frame against their held direction chain —
        // the same reversal hold stableRouteOffsetPoints applies.

        private struct CorridorSegmentLocation: Equatable {
            let polylineIndex: Int
            let segmentIndex: Int
        }

        private func recomputeCorridorLaneSchedule()
            -> [LaneDiagnosticsDocument.Journey]
        {
            var held: [CorridorLaneSchedule.StrandKey: [(x: Double, y: Double)]] = [:]
            var journeys: [LaneDiagnosticsDocument.Journey] = []

            for journey in parent.journeys {
                guard let densified =
                    densifiedFlagshipCoordinatesByJourneyID[journey.id],
                      let geometry = corridorGeometryByJourneyID[journey.id]
                else { continue }
                var polylines: [[GeoCoordinate]] = []
                for (polylineIndex, coordinates) in densified.enumerated() {
                    polylines.append(coordinates.map { GeoCoordinate($0) })
                    guard coordinates.count >= 2 else { continue }
                    let key = CorridorLaneSchedule.StrandKey(
                        journeyID: journey.id,
                        polylineIndex: polylineIndex
                    )
                    // The renderer's reversal hold, per segment: schedule
                    // offsets convert against this chain (see
                    // sharedCorridorSegmentLayout).
                    let points = coordinates.map { MKMapPoint($0) }
                    var directions: [(x: Double, y: Double)] = []
                    var previous: (x: Double, y: Double)?
                    for index in 0..<(points.count - 1) {
                        let deltaX = points[index + 1].x - points[index].x
                        let deltaY = points[index + 1].y - points[index].y
                        let length = hypot(deltaX, deltaY)
                        guard length > 0.000_001 else {
                            directions.append(previous ?? (x: 1, y: 0))
                            continue
                        }
                        var unitX = deltaX / length
                        var unitY = deltaY / length
                        if let previous,
                           unitX * previous.x + unitY * previous.y < -0.8 {
                            unitX = -unitX
                            unitY = -unitY
                        }
                        directions.append((unitX, unitY))
                        previous = (unitX, unitY)
                    }
                    held[key] = directions
                }
                guard !polylines.isEmpty else { continue }
                journeys.append(
                    LaneDiagnosticsDocument.Journey(
                        id: journey.id,
                        routeNumber: geometry.routeNumber,
                        agency: geometry.agencyName,
                        directionID: geometry.directionID,
                        stackOrder: geometry.stackOrder,
                        departures: geometry.observedDepartureCount,
                        polylines: polylines
                    )
                )
            }

            heldUnitDirectionsByStrand = held
            corridorLaneSchedule = CorridorLaneSchedule.schedule(
                journeys: journeys,
                laneSpacingPoints: RouteMapStyle.laneSpacingPoints
            )
            return journeys
        }
        private func sharedCorridorLaneLayout(
            for coordinates: [CLLocationCoordinate2D],
            journeyID: Int,
            polylineIndex: Int,
            packageLayout: CorridorLaneLayoutEngine.VertexLayout
        ) -> CorridorLaneLayout {
            guard coordinates.count >= 2,
                  packageLayout.offsets.count == coordinates.count,
                  packageLayout.shared.count == coordinates.count,
                  packageLayout.trunk.count == coordinates.count
            else {
                return CorridorLaneLayout(
                    coordinates: coordinates,
                    offsets: Array(repeating: 0, count: coordinates.count),
                    sharedVertices: Array(
                        repeating: false,
                        count: coordinates.count
                    ),
                    trunkOwnerVertices: Array(
                        repeating: false,
                        count: coordinates.count
                    )
                )
            }

            let points = coordinates.map { MKMapPoint($0) }
            // The package owns membership, lane offsets, dropout bridging,
            // taper, hairpin decay, and trunk ownership. The app keeps only
            // the centerline correction: its anchors are allowed to follow a
            // locally matched reference street without changing the package's
            // slot-valued lane fields.
            let metersPerMapPoint = TripPathGeometry.metersPerMapPoint(
                atLatitude: coordinates[0].latitude
            )
            var alignmentLayouts: [CorridorSegmentLayout?] = []
            alignmentLayouts.reserveCapacity(points.count - 1)
            for index in 0..<(points.count - 1) {
                guard let segment = MapRouteSegment(
                    start: points[index],
                    end: points[index + 1]
                ) else {
                    alignmentLayouts.append(nil)
                    continue
                }
                alignmentLayouts.append(
                    sharedCorridorSegmentLayout(
                        for: segment,
                        journeyID: journeyID,
                        polylineIndex: polylineIndex,
                        segmentIndex: index,
                        metersPerMapPoint: metersPerMapPoint
                    )
                )
            }

            var alignmentDeltaX = Array(repeating: 0.0, count: points.count)
            var alignmentDeltaY = Array(repeating: 0.0, count: points.count)
            var baseSharedVertices = Array(
                repeating: false,
                count: points.count
            )
            var referenceVotes = Array(
                repeating: [Int: Int](),
                count: points.count
            )
            for (index, layout) in alignmentLayouts.enumerated() {
                // A layout segment can be found by the app's local scan even
                // when the package has rejected its short/noisy run. Only
                // package-shared endpoints are allowed to seed alignment.
                guard let layout,
                      packageLayout.shared[index],
                      packageLayout.shared[index + 1]
                else { continue }
                baseSharedVertices[index] = true
                baseSharedVertices[index + 1] = true
                alignmentDeltaX[index] += layout.alignedStart.x
                    - points[index].x
                alignmentDeltaY[index] += layout.alignedStart.y
                    - points[index].y
                alignmentDeltaX[index + 1] += layout.alignedEnd.x
                    - points[index + 1].x
                alignmentDeltaY[index + 1] += layout.alignedEnd.y
                    - points[index + 1].y
                referenceVotes[index][layout.referenceID, default: 0] += 1
                referenceVotes[index + 1][layout.referenceID, default: 0] += 1
            }

            for index in points.indices where baseSharedVertices[index] {
                let count = referenceVotes[index].values.reduce(0, +)
                guard count > 0 else { continue }
                alignmentDeltaX[index] /= Double(count)
                alignmentDeltaY[index] /= Double(count)
            }
            // The package has already made the membership decision for a
            // dropout. Fill only the centerline correction across vertices it
            // bridged, using the same arc-distance interpolation as the
            // pre-port path. No lane field is recomputed here.
            bridgeAlignmentGaps(
                points: points,
                baseSharedVertices: baseSharedVertices,
                packageSharedVertices: packageLayout.shared,
                deltaX: &alignmentDeltaX,
                deltaY: &alignmentDeltaY,
                metersPerMapPoint: metersPerMapPoint
            )

            stabilizeSharedAlignmentTransitions(
                points: points,
                explicitlyStacked: packageLayout.shared,
                deltaX: &alignmentDeltaX,
                deltaY: &alignmentDeltaY
            )

            // Fade the centerline correction at the ends of every package-owned
            // shared run. The lane taper itself is deliberately not repeated.
            let taperDistance: CLLocationDistance = 58
            var index = 0
            while index < points.count {
                while index < points.count && !packageLayout.shared[index] {
                    index += 1
                }
                guard index < points.count else { break }
                let runStart = index
                while index < points.count && packageLayout.shared[index] {
                    index += 1
                }
                let runEnd = index - 1

                var backwardDistance: CLLocationDistance = 0
                let startDeltaX = alignmentDeltaX[runStart]
                let startDeltaY = alignmentDeltaY[runStart]
                for destination in stride(
                    from: runStart - 1,
                    through: 0,
                    by: -1
                ) {
                    if packageLayout.shared[destination] { break }
                    backwardDistance += points[destination].distance(
                        to: points[destination + 1]
                    ) * metersPerMapPoint
                    if backwardDistance >= taperDistance { break }
                    applyTaperedAlignment(
                        factor: 1 - backwardDistance / taperDistance,
                        sourceDeltaX: startDeltaX,
                        sourceDeltaY: startDeltaY,
                        destinationIndex: destination,
                        deltaX: &alignmentDeltaX,
                        deltaY: &alignmentDeltaY
                    )
                }

                var forwardDistance: CLLocationDistance = 0
                let endDeltaX = alignmentDeltaX[runEnd]
                let endDeltaY = alignmentDeltaY[runEnd]
                for destination in (runEnd + 1)..<points.count {
                    if packageLayout.shared[destination] { break }
                    forwardDistance += points[destination - 1].distance(
                        to: points[destination]
                    ) * metersPerMapPoint
                    if forwardDistance >= taperDistance { break }
                    applyTaperedAlignment(
                        factor: 1 - forwardDistance / taperDistance,
                        sourceDeltaX: endDeltaX,
                        sourceDeltaY: endDeltaY,
                        destinationIndex: destination,
                        deltaX: &alignmentDeltaX,
                        deltaY: &alignmentDeltaY
                    )
                }
            }

            // Reference changes can be several meters at a street corner. Keep
            // that correction continuous along the route; this is geometry-only
            // smoothing and cannot alter the package's crossing decisions.
            // Small reference steps (inside the ramp budget) would still
            // zigzag the drawn centerline across the corner vertex itself,
            // and the lateral smoother stands down at corners — so the kink
            // survives, and the innermost lane's miter inverts into a little
            // X. Hold corrections constant across sharp corners instead; the
            // exit street's correction ramps in after the turn.
            var cornerVertices = Array(repeating: false, count: points.count)
            if points.count > 2 {
                var rawDirections: [(x: Double, y: Double)] = []
                rawDirections.reserveCapacity(points.count - 1)
                for index in 0..<(points.count - 1) {
                    let stepX = points[index + 1].x - points[index].x
                    let stepY = points[index + 1].y - points[index].y
                    let length = hypot(stepX, stepY)
                    if length > 0.000_001 {
                        rawDirections.append(
                            (stepX / length, stepY / length)
                        )
                    } else if let last = rawDirections.last {
                        rawDirections.append(last)
                    } else {
                        rawDirections.append((x: 1, y: 0))
                    }
                }
                for index in 1..<(points.count - 1) {
                    let before = rawDirections[index - 1]
                    let after = rawDirections[index]
                    cornerVertices[index] =
                        before.x * after.x + before.y * after.y < 0.7
                }
            }
            let maximumAlignmentRamp = 0.08  // meters of correction per meter
            if points.count > 2 {
                for index in 1..<points.count {
                    if cornerVertices[index] {
                        alignmentDeltaX[index] = alignmentDeltaX[index - 1]
                        alignmentDeltaY[index] = alignmentDeltaY[index - 1]
                        continue
                    }
                    let segmentMeters = points[index - 1].distance(
                        to: points[index]
                    ) * metersPerMapPoint
                    let budget = maximumAlignmentRamp * segmentMeters
                    let stepX = alignmentDeltaX[index]
                        - alignmentDeltaX[index - 1]
                    let stepY = alignmentDeltaY[index]
                        - alignmentDeltaY[index - 1]
                    let step = hypot(stepX, stepY)
                    if step > budget, budget > 0 {
                        let scale = budget / step
                        alignmentDeltaX[index] = alignmentDeltaX[index - 1]
                            + stepX * scale
                        alignmentDeltaY[index] = alignmentDeltaY[index - 1]
                            + stepY * scale
                    }
                }
                for index in stride(from: points.count - 2, through: 0, by: -1) {
                    if cornerVertices[index] {
                        alignmentDeltaX[index] = alignmentDeltaX[index + 1]
                        alignmentDeltaY[index] = alignmentDeltaY[index + 1]
                        continue
                    }
                    let segmentMeters = points[index].distance(
                        to: points[index + 1]
                    ) * metersPerMapPoint
                    let budget = maximumAlignmentRamp * segmentMeters
                    let stepX = alignmentDeltaX[index]
                        - alignmentDeltaX[index + 1]
                    let stepY = alignmentDeltaY[index]
                        - alignmentDeltaY[index + 1]
                    let step = hypot(stepX, stepY)
                    if step > budget, budget > 0 {
                        let scale = budget / step
                        alignmentDeltaX[index] = alignmentDeltaX[index + 1]
                            + stepX * scale
                        alignmentDeltaY[index] = alignmentDeltaY[index + 1]
                            + stepY * scale
                    }
                }
            }

            // Finally, pull the drawn centers laterally toward their own
            // neighborhood mean along shared runs. The delta smoothing above
            // averages the *correction*; the raw GTFS wobble underneath it
            // survives untouched, and with wide lanes that wobble is what
            // lets adjacent strands touch. Smoothing the summed centers —
            // lateral only, so corners are never cut — converges every
            // corridor member onto the same smooth spine.
            let smoothedCenters = smoothSharedLateralCenters(
                points: points,
                deltaX: alignmentDeltaX,
                deltaY: alignmentDeltaY,
                sharedVertices: packageLayout.shared,
                metersPerMapPoint: metersPerMapPoint
            )

            let alignedCoordinates = smoothedCenters.map { $0.coordinate }
            return CorridorLaneLayout(
                coordinates: alignedCoordinates,
                offsets: packageLayout.offsets,
                sharedVertices: packageLayout.shared,
                trunkOwnerVertices: packageLayout.trunk
            )
        }

        private func bridgeAlignmentGaps(
            points: [MKMapPoint],
            baseSharedVertices: [Bool],
            packageSharedVertices: [Bool],
            deltaX: inout [Double],
            deltaY: inout [Double],
            metersPerMapPoint: Double
        ) {
            guard points.count == baseSharedVertices.count,
                  points.count == packageSharedVertices.count,
                  points.count == deltaX.count,
                  points.count == deltaY.count
            else { return }

            var start = 0
            while start < points.count {
                guard packageSharedVertices[start],
                      !baseSharedVertices[start]
                else {
                    start += 1
                    continue
                }
                let gapStart = start
                while start < points.count,
                      packageSharedVertices[start],
                      !baseSharedVertices[start] {
                    start += 1
                }
                let gapEnd = start
                let left = gapStart - 1
                let right = gapEnd
                guard left >= 0,
                      right < points.count,
                      baseSharedVertices[left],
                      baseSharedVertices[right]
                else { continue }

                var gapDistance: CLLocationDistance = 0
                for index in left..<right {
                    gapDistance += points[index].distance(
                        to: points[index + 1]
                    ) * metersPerMapPoint
                }
                guard gapDistance > 0 else { continue }
                var distanceFromLeft: CLLocationDistance = 0
                for index in gapStart..<gapEnd {
                    distanceFromLeft += points[index - 1].distance(
                        to: points[index]
                    ) * metersPerMapPoint
                    let progress = distanceFromLeft / gapDistance
                    deltaX[index] = deltaX[left]
                        + (deltaX[right] - deltaX[left]) * progress
                    deltaY[index] = deltaY[left]
                        + (deltaY[right] - deltaY[left]) * progress
                }
            }
        }

        private func stabilizeSharedAlignmentTransitions(
            points: [MKMapPoint],
            explicitlyStacked: [Bool],
            deltaX: inout [Double],
            deltaY: inout [Double]
        ) {
            guard points.count > 2,
                  points.count == explicitlyStacked.count,
                  points.count == deltaX.count,
                  points.count == deltaY.count
            else { return }

            let originalDeltaX = deltaX
            let originalDeltaY = deltaY
            for index in 1..<(points.count - 1) {
                guard explicitlyStacked[index - 1],
                      explicitlyStacked[index],
                      explicitlyStacked[index + 1]
                else { continue }
                deltaX[index] = 0.25 * originalDeltaX[index - 1]
                    + 0.50 * originalDeltaX[index]
                    + 0.25 * originalDeltaX[index + 1]
                deltaY[index] = 0.25 * originalDeltaY[index - 1]
                    + 0.50 * originalDeltaY[index]
                    + 0.25 * originalDeltaY[index + 1]
            }
        }

        /// Pull each shared vertex's drawn center laterally toward its own
        /// neighborhood mean (±3 vertices, σ ≈ 30 m by arc distance) so
        /// independent GTFS sampling wobble cannot make adjacent wide lanes
        /// touch. Laterals are measured against the vertex's held normal —
        /// the same reversal-stable frame the renderer offsets in — and
        /// longitudinal positions are untouched, so corners are never cut.
        /// The pull fades to zero outside shared runs over the taper reach,
        /// and high-curvature neighborhoods keep their raw centers so
        /// hairpins and tight corners are not distorted. Corridor members
        /// converge onto the same smooth spine (each adopted the reference
        /// within the 8 m gate), which is what keeps the drawn lanes
        /// parallel; divided carriageways beyond the gate keep their own
        /// centers as before. One Jacobi iteration: every vertex reads the
        /// pre-pass centers, so the result cannot depend on sweep order.
        private func smoothSharedLateralCenters(
            points: [MKMapPoint],
            deltaX: [Double],
            deltaY: [Double],
            sharedVertices: [Bool],
            metersPerMapPoint: Double
        ) -> [MKMapPoint] {
            let count = points.count
            guard count >= 2,
                  deltaX.count == count,
                  deltaY.count == count,
                  sharedVertices.count == count
            else {
                return points
            }
            let alignedX = points.indices.map { points[$0].x + deltaX[$0] }
            let alignedY = points.indices.map { points[$0].y + deltaY[$0] }

            // Held segment directions over the aligned centers, with the
            // renderer's reversal hold.
            var heldDirections: [(x: Double, y: Double)] = []
            heldDirections.reserveCapacity(count - 1)
            var previousHeld: (x: Double, y: Double)?
            for index in 0..<(count - 1) {
                let stepX = alignedX[index + 1] - alignedX[index]
                let stepY = alignedY[index + 1] - alignedY[index]
                let length = hypot(stepX, stepY)
                guard length > 0.000_001 else {
                    heldDirections.append(previousHeld ?? (x: 1, y: 0))
                    continue
                }
                var unit = (stepX / length, stepY / length)
                if let previousHeld,
                   unit.0 * previousHeld.x + unit.1 * previousHeld.y < -0.8 {
                    unit = (-unit.0, -unit.1)
                }
                heldDirections.append(unit)
                previousHeld = unit
            }
            var normalX = Array(repeating: 0.0, count: count)
            var normalY = Array(repeating: 1.0, count: count)
            for index in 0..<count {
                let previous = heldDirections[index == 0 ? 0 : index - 1]
                let next = heldDirections[
                    index == count - 1 ? count - 2 : index
                ]
                let sumX = -(previous.y + next.y) / 2
                let sumY = (previous.x + next.x) / 2
                let length = max(0.000_001, hypot(sumX, sumY))
                normalX[index] = sumX / length
                normalY[index] = sumY / length
            }

            // Raw segment directions for curvature gating: the held chain
            // deliberately hides reversals, but smoothing must not span one.
            var rawDirections: [(x: Double, y: Double)] = []
            rawDirections.reserveCapacity(max(0, count - 1))
            for index in 0..<(count - 1) {
                let stepX = points[index + 1].x - points[index].x
                let stepY = points[index + 1].y - points[index].y
                let length = hypot(stepX, stepY)
                if length > 0.000_001 {
                    rawDirections.append((stepX / length, stepY / length))
                } else if let last = rawDirections.last {
                    rawDirections.append(last)
                } else {
                    rawDirections.append((x: 1, y: 0))
                }
            }

            var arc = Array(repeating: 0.0, count: count)
            for index in 1..<count {
                arc[index] = arc[index - 1] + hypot(
                    alignedX[index] - alignedX[index - 1],
                    alignedY[index] - alignedY[index - 1]
                ) * metersPerMapPoint
            }

            // Full weight on shared vertices, fading to zero over the same
            // 58 m reach the centerline taper uses.
            let taperReach: CLLocationDistance = 58
            var weight = sharedVertices.map { $0 ? 1.0 : 0.0 }
            var lastSharedArc = -Double.greatestFiniteMagnitude
            for index in 0..<count {
                if sharedVertices[index] {
                    lastSharedArc = arc[index]
                } else if arc[index] - lastSharedArc < taperReach {
                    weight[index] = max(
                        weight[index],
                        1 - (arc[index] - lastSharedArc) / taperReach
                    )
                }
            }
            var nextSharedArc = Double.greatestFiniteMagnitude
            for index in stride(from: count - 1, through: 0, by: -1) {
                if sharedVertices[index] {
                    nextSharedArc = arc[index]
                } else if nextSharedArc - arc[index] < taperReach {
                    weight[index] = max(
                        weight[index],
                        1 - (nextSharedArc - arc[index]) / taperReach
                    )
                }
            }

            let sigma = 30.0
            let halfWindow = 3
            var smoothedX = alignedX
            var smoothedY = alignedY
            for index in 0..<count {
                guard weight[index] > 0.001 else { continue }
                let lower = max(0, index - halfWindow)
                let upper = min(count - 1, index + halfWindow)
                // Curvature coherence: the minimum dot between consecutive
                // raw segments in the window. Near 1 on a straight street
                // (full smoothing), near -1 through a hairpin (none).
                var coherence = 1.0
                if rawDirections.count >= 2 {
                    let firstSegment = max(0, lower)
                    let lastSegment = min(upper, rawDirections.count - 1)
                    if firstSegment < lastSegment {
                        for segment in firstSegment..<lastSegment {
                            coherence = min(
                                coherence,
                                rawDirections[segment].x
                                    * rawDirections[segment + 1].x
                                    + rawDirections[segment].y
                                    * rawDirections[segment + 1].y
                            )
                        }
                    }
                }
                let curvatureFactor = max(0, min(1, (coherence - 0.70) / 0.25))
                let strength = weight[index] * 0.9 * curvatureFactor
                guard strength > 0.001 else { continue }

                let axisX = normalX[index]
                let axisY = normalY[index]
                var weightedSum = 0.0
                var weightTotal = 0.0
                for neighbor in lower...upper {
                    let distance = abs(arc[neighbor] - arc[index])
                    let gaussian = exp(
                        -(distance / sigma) * (distance / sigma)
                    )
                    weightedSum += (
                        alignedX[neighbor] * axisX + alignedY[neighbor] * axisY
                    ) * gaussian
                    weightTotal += gaussian
                }
                guard weightTotal > 0 else { continue }
                let base = alignedX[index] * axisX + alignedY[index] * axisY
                let shift = (weightedSum / weightTotal - base) * strength
                smoothedX[index] += axisX * shift
                smoothedY[index] += axisY * shift
            }
            return smoothedX.indices.map {
                MKMapPoint(x: smoothedX[$0], y: smoothedY[$0])
            }
        }

        private func applyTaperedAlignment(
            factor: Double,
            sourceDeltaX: Double,
            sourceDeltaY: Double,
            destinationIndex: Int,
            deltaX: inout [Double],
            deltaY: inout [Double]
        ) {
            let candidateX = sourceDeltaX * factor
            let candidateY = sourceDeltaY * factor
            if hypot(candidateX, candidateY) > hypot(
                deltaX[destinationIndex],
                deltaY[destinationIndex]
            ) {
                deltaX[destinationIndex] = candidateX
                deltaY[destinationIndex] = candidateY
            }
        }

        private func corridorLaneComesBefore(
            _ firstID: Int,
            _ secondID: Int
        ) -> Bool {
            guard let first = corridorGeometryByJourneyID[firstID],
                  let second = corridorGeometryByJourneyID[secondID]
            else { return firstID < secondID }

            let firstIs1 = first.routeNumber == "1"
            let firstIs4 = first.routeNumber == "4"
            let secondIs1 = second.routeNumber == "1"
            let secondIs4 = second.routeNumber == "4"
            if (firstIs1 && secondIs4) || (firstIs4 && secondIs1) {
                return firstIs4
            }
            let routeComparison = first.routeNumber.compare(
                second.routeNumber,
                options: [.caseInsensitive, .numeric]
            )
            if routeComparison != .orderedSame {
                return routeComparison == .orderedAscending
            }
            let agencyComparison = first.agencyName.compare(
                second.agencyName,
                options: [.caseInsensitive, .diacriticInsensitive]
            )
            if agencyComparison != .orderedSame {
                return agencyComparison == .orderedAscending
            }
            let firstDirection = first.directionID ?? Int.max
            let secondDirection = second.directionID ?? Int.max
            if firstDirection != secondDirection {
                return firstDirection < secondDirection
            }
            if first.stackOrder != second.stackOrder {
                return first.stackOrder < second.stackOrder
            }
            return firstID < secondID
        }

        private func sharedCorridorSegmentLayout(
            for segment: MapRouteSegment,
            journeyID: Int,
            polylineIndex: Int,
            segmentIndex: Int,
            metersPerMapPoint: Double
        ) -> CorridorSegmentLayout? {
            let midpoint = MKMapPoint(
                x: (segment.start.x + segment.end.x) / 2,
                y: (segment.start.y + segment.end.y) / 2
            )
            var localSegmentByJourneyID = [journeyID: segment]

            for (candidateID, geometry) in corridorGeometryByJourneyID
            where candidateID != journeyID {
                // Alignment uses the same local membership gates as the old
                // renderer, but the package owns the authoritative lane
                // membership and all subsequent lane passes.
                guard let midpointSegment = parallelCorridorSegment(
                    near: midpoint,
                    direction: segment,
                    among: geometry.segmentIndex.segments(near: midpoint),
                    metersPerMapPoint: metersPerMapPoint
                ),
                      hasParallelCorridor(
                        near: segment.start,
                        direction: segment,
                        among: geometry.segmentIndex.segments(
                            near: segment.start
                        ),
                        metersPerMapPoint: metersPerMapPoint
                      ),
                      hasParallelCorridor(
                        near: segment.end,
                        direction: segment,
                        among: geometry.segmentIndex.segments(near: segment.end),
                        metersPerMapPoint: metersPerMapPoint
                      )
                else { continue }
                localSegmentByJourneyID[candidateID] = midpointSegment
            }

            guard localSegmentByJourneyID.count > 1 else { return nil }
            let memberIDs = localSegmentByJourneyID.keys.sorted(
                by: corridorLaneComesBefore
            )

            let strandKey = CorridorLaneSchedule.StrandKey(
                journeyID: journeyID,
                polylineIndex: polylineIndex
            )
            guard let sample = corridorLaneSchedule[strandKey]?[segmentIndex]
            else { return nil }

            // Alignment anchors follow the schedule's sticky corridor
            // reference when it is locally matched; a reference not visible
            // from this sample falls back to the first public-identity member.
            let referenceID: Int
            let referenceSegment: MapRouteSegment?
            let stickyReferenceMatched: Bool
            if let matchedReference = localSegmentByJourneyID[
                sample.referenceID
            ] {
                referenceID = sample.referenceID
                referenceSegment = matchedReference
                stickyReferenceMatched = true
            } else {
                referenceID = memberIDs.first ?? journeyID
                referenceSegment = localSegmentByJourneyID[referenceID]
                stickyReferenceMatched = false
            }

            var alignedStart: MKMapPoint
            var alignedEnd: MKMapPoint
            if referenceID == journeyID || referenceSegment == nil {
                alignedStart = segment.start
                alignedEnd = segment.end
            } else {
                // Project both endpoints onto the same locally matched segment.
                // Searching again per endpoint can select two different parallel
                // pieces of a terminal loop and manufacture a sideways jog.
                alignedStart = corridorProjection(
                    of: segment.start,
                    onto: referenceSegment!,
                    metersPerMapPoint: metersPerMapPoint
                )
                alignedEnd = corridorProjection(
                    of: segment.end,
                    onto: referenceSegment!,
                    metersPerMapPoint: metersPerMapPoint
                )
            }

            // Keep the street-anchor correction from the shipped renderer.
            // It changes only the drawn centerline; package lane slots remain
            // untouched and are returned by CorridorLaneLayoutEngine.
            if referenceID != journeyID, stickyReferenceMatched,
               let reference = referenceSegment {
                let refX = reference.unitX, refY = reference.unitY
                let frame = (segment.unitX * refX + segment.unitY * refY) >= 0
                    ? 1.0 : -1.0
                let normalX = -refY, normalY = refX
                let spanX = reference.end.x - reference.start.x
                let spanY = reference.end.y - reference.start.y
                let norm2 = spanX * spanX + spanY * spanY
                let maxShift = 30.0 / metersPerMapPoint
                if norm2 > 0 {
                    func streetAnchored(_ anchor: MKMapPoint) -> MKMapPoint {
                        var t = ((anchor.x - reference.start.x) * spanX
                            + (anchor.y - reference.start.y) * spanY) / norm2
                        t = min(max(t, 0), 1)
                        let hitX = reference.start.x + t * spanX
                        let hitY = reference.start.y + t * spanY
                        var delta = ((anchor.x - hitX) * normalX
                            + (anchor.y - hitY) * normalY) * frame
                        delta = min(max(delta, -maxShift), maxShift)
                        return MKMapPoint(
                            x: anchor.x + delta * segment.unitY,
                            y: anchor.y - delta * segment.unitX
                        )
                    }
                    alignedStart = streetAnchored(alignedStart)
                    alignedEnd = streetAnchored(alignedEnd)
                }
            }

            // These lane fields are intentionally inert: the package layout
            // engine supplies offsets/shared/trunk for the whole corridor.
            // Keeping one record type lets the geometry-only pass carry the
            // two aligned anchors and its sticky reference without a second
            // parallel representation.
            return CorridorSegmentLayout(
                offset: 0,
                enteringOffset: 0,
                alignedStart: alignedStart,
                alignedEnd: alignedEnd,
                referenceID: referenceID,
                isTrunkOwner: false
            )
        }

        /// Remove only perpendicular drift from a member shape. Both endpoints of
        /// one short sample use the same reference segment, preserving longitudinal
        /// progress and preventing a dense terminal loop from becoming a shortcut.
        private func corridorProjection(
            of point: MKMapPoint,
            onto reference: MapRouteSegment,
            metersPerMapPoint: Double
        ) -> MKMapPoint {
            let deltaX = reference.end.x - reference.start.x
            let deltaY = reference.end.y - reference.start.y
            let lengthSquared = deltaX * deltaX + deltaY * deltaY
            guard lengthSquared > 0 else { return point }
            let progress = max(
                0,
                min(
                    1,
                    ((point.x - reference.start.x) * deltaX
                        + (point.y - reference.start.y) * deltaY) / lengthSquared
                )
            )
            let projection = MKMapPoint(
                x: reference.start.x + progress * deltaX,
                y: reference.start.y + progress * deltaY
            )
            // Alignment corrects feed-to-feed centerline drift on the same
            // roadway — two publishers sampling the same street a few meters
            // apart. With tube-map-wide lanes that drift must be adopted
            // essentially fully, or adjacent strands touch wherever the raw
            // shapes wander toward each other. Santa Barbara's shared transit
            // streets are largely divided carriageways 12–20 m apart
            // (Hollister, El Colegio, Calle Real), and freeway ramps braid
            // just as close to their frontage roads. Adopting a "reference"
            // centerline across that gap is what drew the 9 loop, 12x, and
            // 24x onto the wrong side of the street as tapered sideways
            // detours — so the gate sits at 8 m, comfortably clear of the
            // 12 m carriageway floor. Partners beyond it still share the
            // corridor and its lanes; they just keep their own authoritative
            // centerline instead of snapping to their neighbor's. (This gate
            // binds direct projection. Members whose sticky reference is
            // locally matched additionally take the street-anchor pull below
            // toward the reference line, up to 30 m out; sticky references
            // are meant to be same-roadway partners, so in practice that
            // range only closes endpoint and corner residuals.)
            return point.distance(to: projection) * metersPerMapPoint <= 8
                ? projection
                : point
        }

        private func hasParallelCorridor(
            near point: MKMapPoint,
            direction: MapRouteSegment,
            among candidates: [MapRouteSegment],
            metersPerMapPoint: Double
        ) -> Bool {
            parallelCorridorSegment(
                near: point,
                direction: direction,
                among: candidates,
                metersPerMapPoint: metersPerMapPoint
            ) != nil
        }

        private func parallelCorridorSegment(
            near point: MKMapPoint,
            direction: MapRouteSegment,
            among candidates: [MapRouteSegment],
            metersPerMapPoint: Double
        ) -> MapRouteSegment? {
            // Two feeds can publish centerlines on different parts of the same
            // street. Twenty meters still covers that drift without treating a
            // nearby terminal bay or parallel downtown street as one corridor.
            // This gate decides corridor *membership* (lanes) only — centerline
            // adoption is far stricter, since divided carriageways and ramp
            // braids also sit inside twenty meters of each other.
            let maximumSeparation: CLLocationDistance = 20
            let minimumParallelDot = 0.93
            return candidates
                .filter { candidate in
                    abs(direction.unitX * candidate.unitX
                        + direction.unitY * candidate.unitY) >= minimumParallelDot
                        && mapDistance(
                            from: point,
                            to: candidate
                        ) * metersPerMapPoint <= maximumSeparation
                }
                .min {
                    mapDistance(from: point, to: $0) < mapDistance(
                        from: point,
                        to: $1
                    )
                }
        }

        private func mapDistance(
            from point: MKMapPoint,
            to segment: MapRouteSegment
        ) -> CLLocationDistance {
            let deltaX = segment.end.x - segment.start.x
            let deltaY = segment.end.y - segment.start.y
            let lengthSquared = deltaX * deltaX + deltaY * deltaY
            guard lengthSquared > 0 else {
                return point.distance(to: segment.start)
            }
            let progress = max(
                0,
                min(
                    1,
                    ((point.x - segment.start.x) * deltaX
                        + (point.y - segment.start.y) * deltaY) / lengthSquared
                )
            )
            let projection = MKMapPoint(
                x: segment.start.x + progress * deltaX,
                y: segment.start.y + progress * deltaY
            )
            return point.distance(to: projection)
        }

        private struct CorridorJourneyGeometry {
            let stackOrder: Int
            let routeNumber: String
            let agencyName: String
            let directionID: Int?
            let observedDepartureCount: Int
            let segmentIndex: CorridorSegmentIndex
        }

        /// Coarse spatial hash over a journey's corridor segments. Corridor
        /// detection asks "which of this journey's segments pass within 20
        /// meters of this point?" thousands of times per layout pass; scanning
        /// the full segment list for each query made the whole pass
        /// O(routes² × segments²) and was the main driver of the memory/CPU
        /// spikes that got the app jettisoned. Each segment is registered in
        /// every grid cell its padded bounding box overlaps, so a query only
        /// inspects the one cell containing the query point.
        private struct CorridorSegmentIndex {
            private static let queryPadding: CLLocationDistance = 24
            private let cellSize: Double
            private let segments: [MapRouteSegment]
            private let locations: [CorridorSegmentLocation]?
            private var segmentIndicesByCell: [UInt64: [Int32]] = [:]

            init(
                segments: [MapRouteSegment],
                locations: [CorridorSegmentLocation]? = nil
            ) {
                self.segments = segments
                self.locations = locations
                guard let first = segments.first else {
                    cellSize = 1
                    return
                }
                // Map-point units per meter vary only with latitude; one city
                // area is uniform enough for a conservative padded grid.
                let pointsPerMeter = MKMapPointsPerMeterAtLatitude(
                    first.start.coordinate.latitude
                )
                cellSize = max(1, 64 * pointsPerMeter)
                let padding = Self.queryPadding * pointsPerMeter

                for (index, segment) in segments.enumerated() {
                    let minCellX = Int32(
                        (min(segment.start.x, segment.end.x) - padding)
                            / cellSize
                    )
                    let maxCellX = Int32(
                        (max(segment.start.x, segment.end.x) + padding)
                            / cellSize
                    )
                    let minCellY = Int32(
                        (min(segment.start.y, segment.end.y) - padding)
                            / cellSize
                    )
                    let maxCellY = Int32(
                        (max(segment.start.y, segment.end.y) + padding)
                            / cellSize
                    )
                    guard minCellX <= maxCellX, minCellY <= maxCellY else {
                        continue
                    }
                    for cellX in minCellX...maxCellX {
                        for cellY in minCellY...maxCellY {
                            segmentIndicesByCell[
                                Self.cellKey(cellX, cellY),
                                default: []
                            ].append(Int32(index))
                        }
                    }
                }
            }

            /// Valid for query radii up to `queryPadding` meters — enough for
            /// the 20-meter corridor separation test.
            func segments(near point: MKMapPoint) -> [MapRouteSegment] {
                guard !segments.isEmpty else { return [] }
                let key = Self.cellKey(
                    Int32(point.x / cellSize),
                    Int32(point.y / cellSize)
                )
                guard let indices = segmentIndicesByCell[key] else { return [] }
                return indices.map { segments[Int($0)] }
            }

            /// Nearest parallel segment within corridor tolerances, together
            /// with its location on the owning journey's flagship strands —
            /// the membership scan the lane scheduler runs over. Same gates
            /// as parallelCorridorSegment below.
            func parallelMember(
                near point: MKMapPoint,
                direction: MapRouteSegment,
                metersPerMapPoint: Double
            ) -> (segment: MapRouteSegment,
                  location: CorridorSegmentLocation)? {
                guard let locations else { return nil }
                guard !segments.isEmpty else { return nil }
                let key = Self.cellKey(
                    Int32(point.x / cellSize),
                    Int32(point.y / cellSize)
                )
                guard let indices = segmentIndicesByCell[key] else {
                    return nil
                }
                let maximumSeparation: Double = 20
                let minimumParallelDot = 0.93
                var best:
                    (segment: MapRouteSegment,
                     location: CorridorSegmentLocation)?
                var bestDistance = Double.greatestFiniteMagnitude
                for index in indices {
                    let candidate = segments[Int(index)]
                    guard abs(
                        direction.unitX * candidate.unitX
                            + direction.unitY * candidate.unitY
                    ) >= minimumParallelDot else { continue }
                    let distance = point.distance(
                        to: Self.projection(of: point, onto: candidate)
                    )
                    guard distance * metersPerMapPoint
                            <= maximumSeparation,
                          distance < bestDistance
                    else { continue }
                    best = (candidate, locations[Int(index)])
                    bestDistance = distance
                }
                return best
            }

            private static func projection(
                of point: MKMapPoint,
                onto segment: MapRouteSegment
            ) -> MKMapPoint {
                let deltaX = segment.end.x - segment.start.x
                let deltaY = segment.end.y - segment.start.y
                let lengthSquared = deltaX * deltaX + deltaY * deltaY
                guard lengthSquared > 0 else { return point }
                let progress = max(
                    0,
                    min(
                        1,
                        ((point.x - segment.start.x) * deltaX
                            + (point.y - segment.start.y) * deltaY)
                            / lengthSquared
                    )
                )
                return MKMapPoint(
                    x: segment.start.x + progress * deltaX,
                    y: segment.start.y + progress * deltaY
                )
            }

            private static func cellKey(_ x: Int32, _ y: Int32) -> UInt64 {
                UInt64(UInt32(bitPattern: x)) << 32
                    | UInt64(UInt32(bitPattern: y))
            }
        }

        private struct CorridorLaneLayout {
            let coordinates: [CLLocationCoordinate2D]
            let offsets: [Double]
            let sharedVertices: [Bool]
            let trunkOwnerVertices: [Bool]
        }

        private struct CorridorSegmentLayout {
            let offset: Double
            let enteringOffset: Double
            let alignedStart: MKMapPoint
            let alignedEnd: MKMapPoint
            let referenceID: Int
            let isTrunkOwner: Bool
        }

        private struct MapRouteSegment {
            let start: MKMapPoint
            let end: MKMapPoint
            let unitX: Double
            let unitY: Double

            init?(start: MKMapPoint, end: MKMapPoint) {
                let deltaX = end.x - start.x
                let deltaY = end.y - start.y
                let length = hypot(deltaX, deltaY)
                guard length > 0.000_001 else { return nil }
                self.start = start
                self.end = end
                self.unitX = deltaX / length
                self.unitY = deltaY / length
            }
        }

        func mapView(
            _ mapView: MKMapView,
            rendererFor overlay: MKOverlay
        ) -> MKOverlayRenderer {
            if let pulse = overlay as? RoutePulseOverlay {
                let renderer = MKMultiPolylineRenderer(multiPolyline: pulse)
                renderer.strokeColor = pulse.color.withAlphaComponent(0.5)
                renderer.lineWidth = 18
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            guard let routeOverlay = overlay as? RouteLaneOverlay else {
                return MKOverlayRenderer(overlay: overlay)
            }
            return RouteLaneRenderer(overlay: routeOverlay)
        }

        func mapView(
            _ mapView: MKMapView,
            viewFor annotation: MKAnnotation
        ) -> MKAnnotationView? {
            switch annotation {
            case let routeStop as RouteStopMapAnnotation:
                let identifier = "route-stop"
                let view: RouteStopAnnotationView
                if let reused = mapView.dequeueReusableAnnotationView(
                    withIdentifier: identifier
                ) as? RouteStopAnnotationView {
                    view = reused
                } else {
                    view = RouteStopAnnotationView(
                        annotation: routeStop,
                        reuseIdentifier: identifier
                    )
                }
                view.annotation = routeStop
                view.configure(with: routeStop)
                view.setZoomVisibility(
                    routeStopVisibility(for: routeStop, on: mapView),
                    zoomScale: currentZoomScale(in: mapView)
                )
                return view

            case let destination as DestinationMapAnnotation:
                let identifier = "destination"
                let view: DestinationAnnotationView
                if let reused = mapView.dequeueReusableAnnotationView(
                    withIdentifier: identifier
                ) as? DestinationAnnotationView {
                    view = reused
                } else {
                    view = DestinationAnnotationView(
                        annotation: destination,
                        reuseIdentifier: identifier
                    )
                }
                view.annotation = destination
                view.configure(with: destination)
                return view

            case let cluster as StopClusterMapAnnotation:
                let identifier = "stop-cluster"
                let view: StopClusterAnnotationView
                if let reused = mapView.dequeueReusableAnnotationView(
                    withIdentifier: identifier
                ) as? StopClusterAnnotationView {
                    view = reused
                } else {
                    view = StopClusterAnnotationView(
                        annotation: cluster,
                        reuseIdentifier: identifier
                    )
                }
                view.annotation = cluster
                view.configure(with: cluster)
                return view

            case let ladderStop as LadderStopMapAnnotation:
                let identifier = "ladder-stop"
                let view: LadderStopAnnotationView
                if let reused = mapView.dequeueReusableAnnotationView(
                    withIdentifier: identifier
                ) as? LadderStopAnnotationView {
                    view = reused
                } else {
                    view = LadderStopAnnotationView(
                        annotation: ladderStop,
                        reuseIdentifier: identifier
                    )
                }
                view.annotation = ladderStop
                view.configure(with: ladderStop)
                return view

            default:
                return nil
            }
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let destination = view.annotation as? DestinationMapAnnotation {
                parent.onSelectJourney(destination.journey.id)
                mapView.deselectAnnotation(destination, animated: false)
            } else if let cluster = view.annotation as? StopClusterMapAnnotation {
                parent.onSelectStop(
                    cluster.stop.id,
                    cluster.routeIDs,
                    cluster.journeyIDs
                )
                mapView.deselectAnnotation(cluster, animated: false)
            } else if let ladder = view.annotation as? LadderStopMapAnnotation {
                mapView.deselectAnnotation(ladder, animated: false)
            }
        }

        @objc func didTapMap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let mapView = recognizer.view as? MKMapView
            else { return }
            let tapPoint = recognizer.location(in: mapView)
            let zoomScale = MKZoomScale(
                Double(mapView.bounds.width)
                    / max(1, mapView.visibleMapRect.size.width)
            )
            let zoomDetailProgress = RouteMapStyle.detailProgress(for: zoomScale)
            let trunkProgress = 1 - zoomDetailProgress
            var best: (journeyID: Int, distance: CGFloat)?

            for overlay in routeOverlays {
                let detailProgress = overlay.isSelected ? 1 : zoomDetailProgress
                let laneOffsetScale = RouteMapStyle.laneOffsetScale(
                    for: zoomScale
                ) * detailProgress
                let rawPoints = overlay.coordinates.map {
                    mapView.convert($0, toPointTo: mapView)
                }
                let rawLaneOffsets = overlay.laneOffsetPoints.map {
                    CGFloat($0 * laneOffsetScale)
                }
                let laneSamples = deduplicatedRouteLaneSamples(
                    points: rawPoints,
                    offsets: rawLaneOffsets,
                    sharedVertices: overlay.sharedCorridorVertices,
                    trunkOwnerVertices: overlay.trunkOwnerVertices,
                    minimumDistance: 0.245
                )
                // Use the same fanning geometry and visibility rules as drawing.
                let offsetLanePoints = stableRouteOffsetPoints(
                    laneSamples.points,
                    offsets: laneSamples.offsets
                )
                guard offsetLanePoints.count >= 2 else { continue }

                func considerSegment(from start: CGPoint, to end: CGPoint) {
                    let distance = distanceFromPoint(
                        tapPoint,
                        toSegmentFrom: start,
                        to: end
                    )
                    if best.map({ distance < $0.distance }) ?? true {
                        best = (overlay.journeyID, distance)
                    }
                }

                let tapSegmentCount = offsetLanePoints.count - 1
                let tapSharedSegments = (0..<tapSegmentCount).map { segmentIndex in
                    laneSamples.sharedVertices[segmentIndex]
                        && laneSamples.sharedVertices[segmentIndex + 1]
                }
                // Same far-zoom fan pinch the renderer applies, so a route is
                // tappable exactly where it is drawn.
                let lanePoints = LaneRibbonPinch.pinchedRibbon(
                    centre: laneSamples.points.map {
                        (x: Double($0.x), y: Double($0.y))
                    },
                    ribbon: offsetLanePoints.map {
                        (x: Double($0.x), y: Double($0.y))
                    },
                    sharedSegments: tapSharedSegments,
                    minimumStreetWidth: RouteMapStyle.lineWidth(
                        baseWidth: overlay.lineWidth,
                        zoomScale: zoomScale
                    ) + RouteMapStyle.separatorWidth
                ).map { CGPoint(x: $0.x, y: $0.y) }
                let tapBoundaryJoints = (0..<tapSegmentCount).map { segmentIndex in
                    tapSharedSegments[segmentIndex]
                        && ((segmentIndex > 0
                                && !tapSharedSegments[segmentIndex - 1])
                            || (segmentIndex + 1 < tapSegmentCount
                                && !tapSharedSegments[segmentIndex + 1]))
                }
                for index in 0..<tapSegmentCount {
                    let isShared = tapSharedSegments[index]
                    let hasIsolatedCoverage =
                        laneSamples.isolatedVertices[index]
                        && laneSamples.isolatedVertices[index + 1]
                    // Mirror the renderer: any segment still carrying isolated
                    // geometry is drawn at full strength at every zoom, so it
                    // is always tappable. Boundary joints (shared segments
                    // touching an isolated neighbor) are drawn full for the
                    // same reason.
                    let touchesIsolatedNeighbor =
                        (index > 0 && !tapSharedSegments[index - 1])
                        || (index + 1 < tapSegmentCount
                            && !tapSharedSegments[index + 1])
                    let isCornerZone = tapBoundaryJoints[index]
                        || (index > 0 && tapBoundaryJoints[index - 1])
                        || (index + 1 < tapSegmentCount
                            && tapBoundaryJoints[index + 1])
                    if !isShared || hasIsolatedCoverage || touchesIsolatedNeighbor {
                        considerSegment(
                            from: lanePoints[index],
                            to: lanePoints[index + 1]
                        )
                        if !isShared { continue }
                    }
                    if detailProgress > 0.05 {
                        considerSegment(
                            from: lanePoints[index],
                            to: lanePoints[index + 1]
                        )
                    }
                    let ownsTrunk = laneSamples.trunkOwnerVertices[index]
                        && laneSamples.trunkOwnerVertices[index + 1]
                    if ownsTrunk, !isCornerZone, trunkProgress > 0.05 {
                        considerSegment(
                            from: laneSamples.points[index],
                            to: laneSamples.points[index + 1]
                        )
                    }
                }
            }

            if let best, best.distance <= 18,
               parent.journeys.contains(where: { $0.id == best.journeyID }) {
                parent.onSelectJourney(best.journeyID)
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            var view: UIView? = touch.view
            while let current = view {
                if current is MKAnnotationView { return false }
                view = current.superview
            }
            return true
        }

        private func distanceFromPoint(
            _ point: CGPoint,
            toSegmentFrom start: CGPoint,
            to end: CGPoint
        ) -> CGFloat {
            let deltaX = end.x - start.x
            let deltaY = end.y - start.y
            let lengthSquared = deltaX * deltaX + deltaY * deltaY
            guard lengthSquared > 0 else {
                return hypot(point.x - start.x, point.y - start.y)
            }
            let progress = max(
                0,
                min(1, ((point.x - start.x) * deltaX
                    + (point.y - start.y) * deltaY) / lengthSquared)
            )
            let projection = CGPoint(
                x: start.x + progress * deltaX,
                y: start.y + progress * deltaY
            )
            return hypot(point.x - projection.x, point.y - projection.y)
        }
    }
}

// MARK: - Screen-space route lanes

/// A transient wide halo over the selected route's flagship shape. Purely
/// attentional: it exists for under a second after selection to answer
/// "which of these strands did I just pick?"
private final class RoutePulseOverlay: MKMultiPolyline {
    var color: UIColor = .systemBlue
}

private final class RouteLaneOverlay: NSObject, MKOverlay {
    let coordinates: [CLLocationCoordinate2D]
    let journeyID: Int
    let color: UIColor
    let opacity: Double
    let lineWidth: Double
    let laneOffsetPoints: [Double]
    let sharedCorridorVertices: [Bool]
    let trunkOwnerVertices: [Bool]
    let isSelected: Bool
    let dashed: Bool
    private let polyline: MKPolyline

    var coordinate: CLLocationCoordinate2D { polyline.coordinate }
    var boundingMapRect: MKMapRect {
        // Pad for screen-space stroke widths and lane offsets so strokes are
        // not clipped at tile edges (~6 km covers them down to city-overview
        // zoom). The old ±1,000,000-point inflation made every map tile within
        // ~150 km run this overlay's full draw pipeline — dozens of large
        // temporary arrays per tile per overlay — which multiplied CPU and
        // memory for no visual benefit.
        polyline.boundingMapRect.insetBy(dx: -40_000, dy: -40_000)
    }

    init(
        coordinates: [CLLocationCoordinate2D],
        journeyID: Int,
        color: UIColor,
        opacity: Double,
        lineWidth: Double,
        laneOffsetPoints: [Double],
        sharedCorridorVertices: [Bool],
        trunkOwnerVertices: [Bool],
        isSelected: Bool,
        dashed: Bool
    ) {
        self.coordinates = coordinates
        self.journeyID = journeyID
        self.color = color
        self.opacity = opacity
        self.lineWidth = lineWidth
        self.laneOffsetPoints = laneOffsetPoints
        self.sharedCorridorVertices = sharedCorridorVertices
        self.trunkOwnerVertices = trunkOwnerVertices
        self.isSelected = isSelected
        self.dashed = dashed
        self.polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        super.init()
    }
}

private final class RouteLaneRenderer: MKOverlayRenderer {
    private var routeOverlay: RouteLaneOverlay { overlay as! RouteLaneOverlay }

    override func draw(
        _ mapRect: MKMapRect,
        zoomScale: MKZoomScale,
        in context: CGContext
    ) {
        let coordinates = routeOverlay.coordinates
        guard coordinates.count >= 2 else { return }
        let rawPoints = coordinates.map { point(for: MKMapPoint($0)) }
        let zoomDetailProgress = RouteMapStyle.detailProgress(for: zoomScale)
        // A selected journey never disappears into the far-zoom trunk. It stays
        // individually traceable while all unselected shared routes consolidate.
        let detailProgress = routeOverlay.isSelected ? 1 : zoomDetailProgress
        let fullLaneOffsetScale = RouteMapStyle.laneOffsetScale(for: zoomScale)
        let laneOffsetScale = fullLaneOffsetScale * detailProgress
        let rawLaneOffsets = routeOverlay.laneOffsetPoints.map {
            CGFloat($0 * laneOffsetScale) / zoomScale
        }
        guard rawPoints.count == rawLaneOffsets.count else { return }
        let laneSamples = deduplicatedRouteLaneSamples(
            points: rawPoints,
            offsets: rawLaneOffsets,
            sharedVertices: routeOverlay.sharedCorridorVertices,
            trunkOwnerVertices: routeOverlay.trunkOwnerVertices,
            minimumDistance: 0.245 / zoomScale
        )
        guard laneSamples.points.count >= 2 else { return }

        // Apply the corridor lanes before simplifying. Geometry-only RDP can
        // otherwise discard every interior sample on a straight shared road and
        // accidentally put all of its routes back on the same centerline.
        let offsetPoints = stableRouteOffsetPoints(
            laneSamples.points,
            offsets: laneSamples.offsets
        )
        let segmentCount = offsetPoints.count - 1
        let hasSharedState = laneSamples.sharedVertices.count == offsetPoints.count
        let hasOwnerState = laneSamples.trunkOwnerVertices.count == offsetPoints.count
        let sharedSegments = (0..<segmentCount).map { index in
            hasSharedState
                && laneSamples.sharedVertices[index]
                && laneSamples.sharedVertices[index + 1]
        }
        // A segment keeps drawing at full strength whenever it still contains
        // any non-interlined geometry. At far zoom the dedup radius spans whole
        // blocks, so a merged vertex can carry both shared and isolated
        // coverage — treating those as purely shared made entire routes fade
        // with the detail cross-fade even though most of that stretch was not
        // interlined at all.
        // A shared segment straddling a corridor boundary — the turn itself
        // at a fork — reads as the route's own corner, not corridor
        // interior. Its isolated neighbors draw at full strength at every
        // zoom; if the joint faded with the detail cross-fade instead, each
        // turning line would break into a little X at mid-zoom. Keep
        // boundary joints fully drawn on their own lane, and keep the
        // corridor trunk off them: the trunk's single centerline cannot
        // represent each route's own turn, so drawing both ghosts the
        // corner.
        let boundaryJointSegments = (0..<segmentCount).map { index in
            sharedSegments[index]
                && ((index > 0 && !sharedSegments[index - 1])
                    || (index + 1 < segmentCount
                        && !sharedSegments[index + 1]))
        }
        // The trunk's centerline legs would stab through each route's own
        // lane-V at the corner, so the trunk stays off boundary joints and
        // their immediate arms. Run interiors keep their spine.
        let cornerZoneSegments = (0..<segmentCount).map { index in
            boundaryJointSegments[index]
                || (index > 0 && boundaryJointSegments[index - 1])
                || (index + 1 < segmentCount
                    && boundaryJointSegments[index + 1])
        }
        let isolatedSegments = (0..<segmentCount).map { index in
            !sharedSegments[index]
                || (laneSamples.isolatedVertices[index]
                    && laneSamples.isolatedVertices[index + 1])
                || boundaryJointSegments[index]
        }
        let lineWidth = RouteMapStyle.lineWidth(
            baseWidth: routeOverlay.lineWidth,
            zoomScale: zoomScale
        )
        // Far-zoom fan pinch. The corridor's lanes fan out at a constant
        // on-screen spacing while the street they are drawn on stays the same
        // width, so wherever a route doubles back its own two legs end up
        // close together on the ground and the lane offset reaches across
        // and folds the ribbon over itself — the saltire X at a downtown
        // loop. Pull that run's lane back inside its own street.
        //
        // The scale is uniform over the whole shared run: the lane stays
        // parallel to its corridor neighbours instead of pinching locally, no
        // lane braids across another, and the route keeps every vertex so
        // coverage cannot open a gap. Runs that are already simple, runs whose
        // centerline folds (a route doubling back along one street), and city
        // scale where there are no lane offsets at all are left untouched.
        let drawnPoints: [CGPoint]
        if detailProgress > 0.001 {
            drawnPoints = LaneRibbonPinch.pinchedRibbon(
                centre: laneSamples.points.map {
                    (x: Double($0.x), y: Double($0.y))
                },
                ribbon: offsetPoints.map {
                    (x: Double($0.x), y: Double($0.y))
                },
                sharedSegments: sharedSegments,
                minimumStreetWidth: lineWidth + RouteMapStyle.separatorWidth
            ).map { CGPoint(x: $0.x, y: $0.y) }
        } else {
            drawnPoints = offsetPoints
        }
        let ownedTrunkSegments = (0..<segmentCount).map { index in
            sharedSegments[index]
                && hasOwnerState
                && laneSamples.trunkOwnerVertices[index]
                && laneSamples.trunkOwnerVertices[index + 1]
                && !cornerZoneSegments[index]
        }
        // Sub-point RDP cleanup after the lane offset is applied. With
        // tube-map-wide strokes the tolerance grows slightly so residual
        // shape noise cannot wiggle a strand's edge into its neighbor.
        let tolerance = 0.9 / zoomScale
        let isolatedPath = routeSegmentPath(
            points: drawnPoints,
            includedSegments: isolatedSegments,
            tolerance: tolerance
        )
        let detailPath = routeSegmentPath(
            points: drawnPoints,
            includedSegments: sharedSegments,
            tolerance: tolerance
        )
        // The owning route draws the consolidated path on the aligned corridor
        // centerline, not on its close-zoom lane.
        let trunkPath = routeSegmentPath(
            points: laneSamples.points,
            includedSegments: ownedTrunkSegments,
            tolerance: tolerance
        )

        let trunkProgress = 1 - zoomDetailProgress
        let baseOpacity = routeOverlay.opacity
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if routeOverlay.dashed {
            context.setLineDash(
                phase: 0,
                lengths: [8 / zoomScale, 7 / zoomScale]
            )
        }

        // City scale: one smooth shared trunk, colored by the route with the most
        // catchable departures in the selected planning window.
        if trunkPath.hasContent, trunkProgress > 0.001 {
            let trunkOpacity = baseOpacity * trunkProgress
            context.addPath(trunkPath.path)
            context.setStrokeColor(
                UIColor.black.withAlphaComponent(
                    CGFloat(min(0.66, trunkOpacity * 0.66))
                ).cgColor
            )
            context.setLineWidth(
                CGFloat(
                    RouteMapStyle.trunkLineWidth
                        + RouteMapStyle.trunkCasingExpansion
                ) / zoomScale
            )
            context.strokePath()

            context.addPath(trunkPath.path)
            context.setStrokeColor(
                routeOverlay.color.withAlphaComponent(CGFloat(trunkOpacity)).cgColor
            )
            context.setLineWidth(
                CGFloat(RouteMapStyle.trunkLineWidth) / zoomScale
            )
            context.strokePath()
        }

        // Neighborhood scale: shared colors cross-fade in while their offsets fan
        // smoothly from the centerline into the compact subway-style ribbon.
        if detailPath.hasContent, detailProgress > 0.001 {
            let detailOpacity = baseOpacity * detailProgress
            context.addPath(detailPath.path)
            context.setStrokeColor(
                UIColor.black.withAlphaComponent(
                    CGFloat(min(0.72, detailOpacity * 0.72))
                ).cgColor
            )
            context.setLineWidth(
                CGFloat(lineWidth + RouteMapStyle.separatorWidth) / zoomScale
            )
            context.strokePath()

            context.addPath(detailPath.path)
            context.setStrokeColor(
                routeOverlay.color.withAlphaComponent(CGFloat(detailOpacity)).cgColor
            )
            context.setLineWidth(CGFloat(lineWidth) / zoomScale)
            context.strokePath()
        }

        // Branches never become gray or disappear. Their persistent route color,
        // edge destination tag, and selected-route emphasis preserve where each
        // service goes even while only shared geometry is consolidated. The ink
        // casing matches the shared ribbon's: where two branches' GTFS shapes
        // run close without sharing a corridor, the overlap reads as a clean
        // crossing instead of a color blend.
        if isolatedPath.hasContent {
            context.addPath(isolatedPath.path)
            context.setStrokeColor(
                UIColor.black.withAlphaComponent(
                    CGFloat(min(0.72, baseOpacity * 0.72))
                ).cgColor
            )
            context.setLineWidth(
                CGFloat(lineWidth + RouteMapStyle.separatorWidth) / zoomScale
            )
            context.strokePath()

            context.addPath(isolatedPath.path)
            context.setStrokeColor(
                routeOverlay.color.withAlphaComponent(CGFloat(baseOpacity)).cgColor
            )
            context.setLineWidth(CGFloat(lineWidth) / zoomScale)
            context.strokePath()
        }
        context.restoreGState()
    }
}

private struct RouteSegmentPath {
    let path: CGPath
    let hasContent: Bool
}

private func routeSegmentPath(
    points: [CGPoint],
    includedSegments: [Bool],
    tolerance: CGFloat
) -> RouteSegmentPath {
    guard points.count >= 2,
          includedSegments.count == points.count - 1
    else {
        return RouteSegmentPath(path: CGMutablePath(), hasContent: false)
    }

    let path = CGMutablePath()
    var run: [CGPoint] = []
    var hasContent = false

    func appendRun() {
        guard run.count >= 2 else { return }
        let simplified = simplifiedRoutePoints(run, tolerance: tolerance)
        guard simplified.count >= 2 else { return }
        path.move(to: simplified[0])
        for point in simplified.dropFirst() {
            path.addLine(to: point)
        }
        hasContent = true
    }

    for index in includedSegments.indices {
        if includedSegments[index] {
            if run.isEmpty { run.append(points[index]) }
            run.append(points[index + 1])
        } else if !run.isEmpty {
            appendRun()
            run.removeAll(keepingCapacity: true)
        }
    }
    appendRun()
    return RouteSegmentPath(path: path, hasContent: hasContent)
}

private struct RouteLaneSamples {
    var points: [CGPoint]
    var offsets: [CGFloat]
    var sharedVertices: [Bool]
    var isolatedVertices: [Bool]
    var trunkOwnerVertices: [Bool]
}

/// Remove coincident GTFS samples without throwing away their corridor state.
/// Lane offsets must be applied before geometric simplification, but applying
/// them to zero-length segments can create spikes and crossbars.
///
/// Shared and isolated coverage are tracked independently. At far zoom the
/// merge distance spans whole blocks, and collapsing an isolated stretch into
/// a vertex that also absorbed shared samples must not reclassify that stretch
/// as interlined — that is what made entire routes fade when zooming out.
/// A merged vertex therefore remembers "contains shared geometry" and
/// "contains isolated geometry" separately, and a run keeps full opacity as
/// long as it has isolated coverage.
private func deduplicatedRouteLaneSamples(
    points: [CGPoint],
    offsets: [CGFloat],
    sharedVertices: [Bool] = [],
    trunkOwnerVertices: [Bool] = [],
    minimumDistance: CGFloat
) -> RouteLaneSamples {
    guard points.count == offsets.count else {
        return RouteLaneSamples(
            points: points,
            offsets: Array(repeating: 0, count: points.count),
            sharedVertices: Array(repeating: false, count: points.count),
            isolatedVertices: Array(repeating: true, count: points.count),
            trunkOwnerVertices: Array(repeating: false, count: points.count)
        )
    }
    let hasSharedState = sharedVertices.count == points.count
    let hasTrunkOwnerState = trunkOwnerVertices.count == points.count
    var result = RouteLaneSamples(
        points: [],
        offsets: [],
        sharedVertices: [],
        isolatedVertices: [],
        trunkOwnerVertices: []
    )

    for index in points.indices {
        let point = points[index]
        let isShared = hasSharedState ? sharedVertices[index] : false
        let isTrunkOwner = hasTrunkOwnerState ? trunkOwnerVertices[index] : false
        if let previous = result.points.last,
           hypot(point.x - previous.x, point.y - previous.y) <= minimumDistance {
            let lastIndex = result.points.count - 1
            if abs(offsets[index]) >= abs(result.offsets[lastIndex]) {
                result.offsets[lastIndex] = offsets[index]
            }
            result.sharedVertices[lastIndex] =
                result.sharedVertices[lastIndex] || isShared
            result.isolatedVertices[lastIndex] =
                result.isolatedVertices[lastIndex] || !isShared
            result.trunkOwnerVertices[lastIndex] =
                result.trunkOwnerVertices[lastIndex] || isTrunkOwner
            continue
        }
        result.points.append(point)
        result.offsets.append(offsets[index])
        result.sharedVertices.append(isShared)
        result.isolatedVertices.append(!isShared)
        result.trunkOwnerVertices.append(isTrunkOwner)
    }
    return result
}

/// A small screen-space simplification removes residual shape noise after the
/// screen-space lane offset has been applied.
private func simplifiedRoutePoints(
    _ points: [CGPoint],
    tolerance: CGFloat
) -> [CGPoint] {
    guard points.count > 2 else { return points }
    var deduplicated: [CGPoint] = []
    for point in points {
        if let previous = deduplicated.last,
           hypot(point.x - previous.x, point.y - previous.y) <= tolerance * 0.35 {
            continue
        }
        deduplicated.append(point)
    }
    guard deduplicated.count > 2 else { return deduplicated }

    func simplifyRange(_ start: Int, _ end: Int) -> [CGPoint] {
        guard end > start + 1 else {
            return [deduplicated[start], deduplicated[end]]
        }
        var maximumDistance: CGFloat = 0
        var splitIndex: Int?
        for index in (start + 1)..<end {
            let distance = routePerpendicularDistance(
                deduplicated[index],
                from: deduplicated[start],
                to: deduplicated[end]
            )
            if distance > maximumDistance {
                maximumDistance = distance
                splitIndex = index
            }
        }
        guard maximumDistance > tolerance, let splitIndex else {
            return [deduplicated[start], deduplicated[end]]
        }
        let first = simplifyRange(start, splitIndex)
        let second = simplifyRange(splitIndex, end)
        return Array(first.dropLast()) + second
    }

    return simplifyRange(0, deduplicated.count - 1)
}

private func stableRouteOffsetPoints(
    _ points: [CGPoint],
    offsets: [CGFloat]
) -> [CGPoint] {
    guard points.count >= 2,
          offsets.count == points.count,
          offsets.contains(where: { abs($0) > 0.0001 })
    else { return points }
    var directions: [CGPoint] = []
    var lengths: [CGFloat] = []
    var previousDirection: CGPoint?

    for index in 0..<(points.count - 1) {
        let deltaX = points[index + 1].x - points[index].x
        let deltaY = points[index + 1].y - points[index].y
        let rawLength = hypot(deltaX, deltaY)
        let length = max(0.0001, rawLength)
        var direction = CGPoint(x: deltaX / length, y: deltaY / length)

        // An abrupt reversal is almost always duplicate GTFS shape sampling.
        // Keep the lane normal on the same side instead of drawing a rung
        // across all of the parallel strands.
        if let previousDirection,
           direction.x * previousDirection.x
                + direction.y * previousDirection.y < -0.8 {
            direction.x *= -1
            direction.y *= -1
        }
        directions.append(direction)
        lengths.append(rawLength)
        previousDirection = direction
    }

    // Pass 1: the natural mitered offset at every vertex, with the 1.75x
    // miter limit. Also records each vertex's sin(beta) and drawn miter
    // reach for the collapse pass below.
    var natural: [CGPoint] = []
    var sines: [CGFloat] = []
    var miterReach: [CGFloat] = []
    natural.reserveCapacity(points.count)
    sines.reserveCapacity(points.count)
    miterReach.reserveCapacity(points.count)
    for index in points.indices {
        let previousDirection = directions[index == 0 ? 0 : index - 1]
        let nextDirection = directions[
            index == points.count - 1 ? directions.count - 1 : index
        ]
        let previousNormal = CGPoint(
            x: -previousDirection.y,
            y: previousDirection.x
        )
        let nextNormal = CGPoint(x: -nextDirection.y, y: nextDirection.x)
        let sumX = previousNormal.x + nextNormal.x
        let sumY = previousNormal.y + nextNormal.y
        let sumLength = hypot(sumX, sumY)

        let localOffset = offsets[index]
        var normal = nextNormal
        var scale = localOffset
        var sine: CGFloat = 0
        if sumLength > 0.001 {
            normal = CGPoint(x: sumX / sumLength, y: sumY / sumLength)
            let denominator = normal.x * nextNormal.x + normal.y * nextNormal.y
            if denominator > 0.25 {
                scale = localOffset / denominator
            }
            if index > 0, index < points.count - 1 {
                sine = sqrt(max(0, 1 - denominator * denominator))
            }
        }
        let maximumMiter = abs(localOffset) * 1.75
        if localOffset >= 0 {
            scale = max(0, min(maximumMiter, scale))
        } else {
            scale = min(0, max(-maximumMiter, scale))
        }
        natural.append(CGPoint(
            x: points[index].x + normal.x * scale,
            y: points[index].y + normal.y * scale
        ))
        sines.append(sine)
        miterReach.append(abs(scale))
    }

    // Pass 2: collapse vertices a corner miter overshoots. A miter sits
    // scale * sin(beta) along each adjacent leg from the apex; when that
    // reach passes a straight neighbor vertex (route 5's 96° downtown
    // corner: 22 m of miter reach on 12/14.5 m legs at street scale, and
    // more as constant-screen lane offsets outgrow ground-fixed legs when
    // zooming out), the neighbor's plain lateral shift lands past the
    // offset lines' crossing, and the polyline folds back over itself
    // into a little X at the apex. The neighbor is redundant — the entry
    // line already runs through the miter — so collapse it onto the
    // miter instead. The walk runs outward while the miter's reach covers
    // plain contiguous joints, so wide mid-zoom miters cascade past every
    // vertex they overshoot. The corner keeps its full sharp miter; only
    // overshot straight joints move. Apexes stand on their own miters,
    // endpoints keep their coverage, and a vertex claimed from several
    // sides takes the centroid, so the pass is order-free and never
    // changes the point count.
    var output = natural
    if points.count > 2 {
        var claims: [[CGPoint]] = Array(
            repeating: [],
            count: points.count
        )
        for apex in 1..<(points.count - 1) {
            guard sines[apex] > 0.02 else { continue }
            let reach = miterReach[apex] * sines[apex]
            for direction in [-1, 1] {
                var pathDistance: CGFloat = 0
                var cursor = apex
                while true {
                    let next = cursor + direction
                    guard next > 0, next < points.count - 1,
                          sines[next] <= 0.1
                    else { break }
                    pathDistance += lengths[min(cursor, next)]
                    guard pathDistance < reach else { break }
                    claims[next].append(natural[apex])
                    cursor = next
                }
            }
        }
        for middle in 1..<(points.count - 1) {
            if claims[middle].count == 1 {
                output[middle] = claims[middle][0]
            } else if claims[middle].count > 1 {
                let count = CGFloat(claims[middle].count)
                output[middle] = CGPoint(
                    x: claims[middle].map(\.x).reduce(0, +) / count,
                    y: claims[middle].map(\.y).reduce(0, +) / count
                )
            }
        }
    }
    return output
}

private func routePerpendicularDistance(
    _ point: CGPoint,
    from start: CGPoint,
    to end: CGPoint
) -> CGFloat {
    let deltaX = end.x - start.x
    let deltaY = end.y - start.y
    let lengthSquared = deltaX * deltaX + deltaY * deltaY
    guard lengthSquared > 0 else {
        return hypot(point.x - start.x, point.y - start.y)
    }
    let progress = max(
        0,
        min(1, ((point.x - start.x) * deltaX
            + (point.y - start.y) * deltaY) / lengthSquared)
    )
    let projection = CGPoint(
        x: start.x + progress * deltaX,
        y: start.y + progress * deltaY
    )
    return hypot(point.x - projection.x, point.y - projection.y)
}

// MARK: - Map annotations

private enum DestinationViewportEdge {
    case inside
    case top
    case right
    case bottom
    case left
}

private final class DestinationMapAnnotation: NSObject, MKAnnotation {
    let journey: RouteJourney
    let edge: DestinationViewportEdge
    let rank: Int
    let isSelected: Bool
    let isDimmed: Bool
    let viewCenterOffset: CGPoint
    let pinCenter: CGPoint
    dynamic var coordinate: CLLocationCoordinate2D
    var title: String? { journey.destinationName }

    init(
        journey: RouteJourney,
        coordinate: CLLocationCoordinate2D,
        edge: DestinationViewportEdge,
        rank: Int,
        isSelected: Bool,
        isDimmed: Bool,
        viewCenterOffset: CGPoint,
        pinCenter: CGPoint
    ) {
        self.journey = journey
        self.coordinate = coordinate
        self.edge = edge
        self.rank = rank
        self.isSelected = isSelected
        self.isDimmed = isDimmed
        self.viewCenterOffset = viewCenterOffset
        self.pinCenter = pinCenter
    }
}

private final class RouteStopMapAnnotation: NSObject, MKAnnotation {
    let name: String
    let routeIDs: Set<Int>
    let colors: [UIColor]
    let isDimmed: Bool
    dynamic var coordinate: CLLocationCoordinate2D
    var title: String? { name }

    init(
        coordinate: CLLocationCoordinate2D,
        name: String,
        routeIDs: Set<Int>,
        colors: [UIColor],
        isDimmed: Bool
    ) {
        self.coordinate = coordinate
        self.name = name
        self.routeIDs = routeIDs
        self.colors = colors
        self.isDimmed = isDimmed
    }
}

private final class StopClusterMapAnnotation: NSObject, MKAnnotation {
    let stop: TransitStop
    let sourceStopIDs: Set<Int>
    let routeIDs: Set<Int>
    let journeyIDs: Set<Int>
    let routeNumbers: [String]
    let colors: [UIColor]
    let isDimmed: Bool
    let isSelected: Bool
    dynamic var coordinate: CLLocationCoordinate2D { stop.coordinate }
    var title: String? { stop.name }
    var routeCount: Int { routeIDs.count }

    init(
        stop: TransitStop,
        sourceStopIDs: Set<Int>,
        routeIDs: Set<Int>,
        journeyIDs: Set<Int>,
        routeNumbers: [String],
        colors: [UIColor],
        isDimmed: Bool,
        isSelected: Bool
    ) {
        self.stop = stop
        self.sourceStopIDs = sourceStopIDs
        self.routeIDs = routeIDs
        self.journeyIDs = journeyIDs
        self.routeNumbers = routeNumbers
        self.colors = colors
        self.isDimmed = isDimmed
        self.isSelected = isSelected
    }
}

private final class LadderStopMapAnnotation: NSObject, MKAnnotation {
    let stop: JourneyStop
    let journey: RouteJourney
    dynamic var coordinate: CLLocationCoordinate2D { stop.coordinate }
    var title: String? { stop.name }

    init(stop: JourneyStop, journey: RouteJourney) {
        self.stop = stop
        self.journey = journey
    }
}

private final class DestinationAnnotationView: MKAnnotationView {
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        collisionMode = .rectangle
        displayPriority = .defaultHigh
        canShowCallout = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with annotation: DestinationMapAnnotation) {
        subviews.forEach { $0.removeFromSuperview() }
        // Must match destinationTagCandidates' size: the layout frame is
        // what collision-testing sees, this view is what draws.
        let width: CGFloat = 184
        let height: CGFloat = 54
        frame = CGRect(x: 0, y: 0, width: width, height: height)
        centerOffset = annotation.viewCenterOffset
        alpha = annotation.isDimmed ? 0.24 : 1
        displayPriority = annotation.isSelected
            ? .required
            : (annotation.rank < 3 ? .defaultHigh : .defaultLow)

        let routeColor = UIColor(annotation.journey.route.color)
        let card = UIView(frame: CGRect(x: 4, y: 4, width: 176, height: 46))
        card.backgroundColor = UIColor(
            red: 0.965, green: 0.945, blue: 0.89, alpha: 0.97
        )
        card.layer.cornerRadius = 11
        card.layer.borderWidth = 1
        card.layer.borderColor = routeColor.cgColor
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.12
        card.layer.shadowRadius = 3
        card.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(card)

        let colorBar = UIView(frame: CGRect(x: 0, y: 0, width: 6, height: 46))
        colorBar.backgroundColor = routeColor
        colorBar.layer.cornerRadius = 3
        card.addSubview(colorBar)

        let routePrefix = annotation.journey.route.routeNumber.map { "\($0) · " } ?? ""
        let destinationLabel = UILabel(frame: CGRect(x: 12, y: 5, width: 158, height: 19))
        destinationLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        destinationLabel.textColor = UIColor(
            red: 0.14, green: 0.19, blue: 0.18, alpha: 1
        )
        // The tag's one job is naming the place. The compact landmark form
        // ("Camino Real Marketplace") survives 158 points; the full stop name
        // usually truncates into "Hollister & Camin…", which names nothing.
        destinationLabel.text = routePrefix
            + annotation.journey.compactDestinationName
        destinationLabel.lineBreakMode = .byTruncatingTail
        card.addSubview(destinationLabel)

        let timeLabel = UILabel(frame: CGRect(x: 12, y: 25, width: 158, height: 16))
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .bold)
        timeLabel.textColor = routeColor
        let arrivalTime = annotation.journey.arrivalDate.formatted(
            date: .omitted,
            time: .shortened
        )
        timeLabel.text = "Arrive \(arrivalTime) · \(annotation.journey.totalMinutes) min"
        card.addSubview(timeLabel)

        let pin = UIView(
            frame: CGRect(
                x: annotation.pinCenter.x - 4.5,
                y: annotation.pinCenter.y - 4.5,
                width: 9,
                height: 9
            )
        )
        pin.backgroundColor = routeColor
        pin.layer.cornerRadius = 4.5
        pin.layer.borderWidth = 2
        pin.layer.borderColor = UIColor.white.cgColor
        addSubview(pin)

        accessibilityLabel = "\(annotation.journey.route.fullDisplayName) to \(annotation.journey.destinationName), \(annotation.journey.totalMinutes) minutes total"
    }
}

private final class RouteStopAnnotationView: MKAnnotationView {
    private var colors: [UIColor] = []
    private var configuredAlpha: CGFloat = 0.92

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 14, height: 14)
        centerOffset = .zero
        collisionMode = .none
        displayPriority = .required
        zPriority = .min
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with annotation: RouteStopMapAnnotation) {
        colors = annotation.colors
        configuredAlpha = annotation.isDimmed ? 0.18 : 0.92
        alpha = configuredAlpha
        setNeedsDisplay()
    }

    func setZoomVisibility(_ progress: Double, zoomScale: MKZoomScale) {
        let clampedProgress = max(0, min(1, progress))
        alpha = configuredAlpha * CGFloat(clampedProgress)
        isHidden = clampedProgress < 0.01
        // Stop dots are the rider's close-zoom interface; they grow steadily
        // toward street level instead of staying pin-sized.
        let scale = CGFloat(RouteMapStyle.stopSizeScale(for: zoomScale))
        transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let outerCircle = rect.insetBy(dx: 0.5, dy: 0.5)
        context.setFillColor(
            UIColor(red: 0.965, green: 0.945, blue: 0.89, alpha: 1).cgColor
        )
        context.fillEllipse(in: outerCircle)

        let markerCircle = rect.insetBy(dx: 3, dy: 3)
        let visibleColors = colors.isEmpty
            ? [UIColor.systemGray] : Array(colors.prefix(6))
        if visibleColors.count == 1 {
            context.setFillColor(visibleColors[0].cgColor)
            context.fillEllipse(in: markerCircle)
        } else {
            let center = CGPoint(x: markerCircle.midX, y: markerCircle.midY)
            let radius = markerCircle.width / 2
            let arc = CGFloat.pi * 2 / CGFloat(visibleColors.count)
            for (index, color) in visibleColors.enumerated() {
                context.beginPath()
                context.move(to: center)
                context.addArc(
                    center: center,
                    radius: radius,
                    startAngle: -CGFloat.pi / 2 + CGFloat(index) * arc,
                    endAngle: -CGFloat.pi / 2 + CGFloat(index + 1) * arc,
                    clockwise: false
                )
                context.closePath()
                context.setFillColor(color.cgColor)
                context.fillPath()
            }
        }
    }
}

private final class StopClusterAnnotationView: MKAnnotationView {
    private let routeLabel = UILabel()
    private let horizontalInset: CGFloat = 8
    private let verticalInset: CGFloat = 5

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        centerOffset = .zero
        collisionMode = .rectangle
        displayPriority = .defaultHigh
        zPriority = .max
        canShowCallout = false

        backgroundColor = UIColor.white.withAlphaComponent(0.97)
        layer.borderColor = UIColor(WayboundPalette.ink).withAlphaComponent(0.16).cgColor
        layer.borderWidth = 0.75
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1.5)

        routeLabel.textAlignment = .center
        routeLabel.numberOfLines = 1
        addSubview(routeLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        routeLabel.frame = bounds.insetBy(dx: horizontalInset, dy: verticalInset)
    }

    // Keep the marker compact while preserving a forgiving touch target.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -10, dy: -10).contains(point)
    }

    func configure(with annotation: StopClusterMapAnnotation) {
        var seenNumbers = Set<String>()
        let numberColors = zip(annotation.routeNumbers, annotation.colors)
            .filter { seenNumbers.insert($0.0).inserted }

        let text = NSMutableAttributedString()
        for (index, item) in numberColors.enumerated() {
            if index > 0 {
                text.append(
                    NSAttributedString(
                        string: "  ",
                        attributes: [.kern: -1.5]
                    )
                )
            }
            text.append(
                NSAttributedString(
                    string: item.0,
                    attributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .black),
                        .foregroundColor: item.1,
                    ]
                )
            )
        }
        routeLabel.attributedText = text

        let labelSize = routeLabel.sizeThatFits(
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: 24)
        )
        bounds.size = CGSize(
            width: max(30, ceil(labelSize.width) + horizontalInset * 2),
            height: 28
        )
        setNeedsLayout()

        alpha = annotation.isDimmed ? 0.22 : 1
        transform = annotation.isSelected
            ? CGAffineTransform(scaleX: 1.12, y: 1.12)
            : .identity
        let numbers = numberColors.map { $0.0 }.joined(separator: ", ")
        accessibilityLabel = "\(annotation.stop.name), routes \(numbers)"
        accessibilityValue = annotation.isSelected ? "Selected" : nil
    }
}

private final class LadderStopAnnotationView: MKAnnotationView {
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        collisionMode = .rectangle
        displayPriority = .required
        zPriority = .max
        canShowCallout = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with annotation: LadderStopMapAnnotation) {
        subviews.forEach { $0.removeFromSuperview() }
        frame = CGRect(x: 0, y: 0, width: 200, height: 34)
        centerOffset = CGPoint(x: 94, y: 0)

        let dot = UIView(frame: CGRect(x: 0, y: 10.5, width: 13, height: 13))
        dot.backgroundColor = UIColor(annotation.journey.route.color)
        dot.layer.cornerRadius = 6.5
        dot.layer.borderColor = UIColor.white.cgColor
        dot.layer.borderWidth = 2
        addSubview(dot)

        let label = UILabel(frame: CGRect(x: 17, y: 3, width: 179, height: 28))
        label.backgroundColor = UIColor(red: 0.965, green: 0.945, blue: 0.89, alpha: 0.92)
        label.layer.cornerRadius = 8
        label.layer.masksToBounds = true
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = UIColor(red: 0.14, green: 0.19, blue: 0.18, alpha: 1)
        label.text = "  +\(annotation.stop.minutesFromBoarding)  \(annotation.stop.name)"
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        accessibilityLabel = "\(annotation.stop.name), \(annotation.stop.minutesFromBoarding) minutes after boarding"
    }
}
