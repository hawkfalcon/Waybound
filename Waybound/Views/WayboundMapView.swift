import SwiftUI
import MapKit
import UIKit

struct WayboundCameraRequest: Equatable {
    let id = UUID()
    let region: MKCoordinateRegion

    static func == (lhs: WayboundCameraRequest, rhs: WayboundCameraRequest) -> Bool {
        lhs.id == rhs.id
    }
}

private enum RouteMapStyle {
    static let standardLineWidth: Double = 3.4
    static let selectedLineWidth: Double = 3.65
    /// The hairline ink gap drawn between interlined lanes. Several routes in
    /// one hue family can share a corridor; the thin dark separator — not
    /// color — is what keeps adjacent strands countable without clutter.
    static let separatorWidth: Double = 0.8
    static let trunkLineWidth: Double = 4.4
    static let trunkCasingExpansion: Double = 0.9
    static let laneSpacingPoints = standardLineWidth + separatorWidth

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

    static func laneSpacing(for zoomScale: MKZoomScale) -> Double {
        // Lanes grow at only three quarters of the line-width expansion, so
        // strands thicken as the rider zooms in without the whole ribbon
        // ballooning wider than the street it represents.
        standardLineWidth + zoomLineExpansion(for: zoomScale) * 0.75
            + separatorWidth
    }

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
    /// layouts) to a JSON file; the URL comes back via onDiagnosticsFile.
    /// Diagnostics only — never set from production UI.
    var diagnosticsRequestID: Int = 0
    var onDiagnosticsFile: ((URL?) -> Void)? = nil

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
        if context.coordinator.lastDiagnosticsRequestID != diagnosticsRequestID {
            context.coordinator.lastDiagnosticsRequestID = diagnosticsRequestID
            context.coordinator.onDiagnosticsFile = onDiagnosticsFile
            let url = context.coordinator.exportLaneDiagnostics()
            onDiagnosticsFile?(url)
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
        var lastDiagnosticsRequestID: Int?
        fileprivate var onDiagnosticsFile: ((URL?) -> Void)?
        /// Full-polyline lane layouts, computed once per corridor-content change
        /// and only clipped per viewport tick. Recomputing these on every pan
        /// frame was O(routes² × segments²) and drove the memory spikes that got
        /// the app jettisoned.
        private var laneLayoutsByJourneyID: [Int: [CorridorLaneLayout]] = [:]
        /// Anchored-lane schedule: one lane sample per (journey, flagship
        /// polyline, densified segment), computed once per corridor-content
        /// change alongside the layouts. Live departures never re-trigger it.
        private var corridorLaneSchedule:
            [CorridorStrandKey: [Int: CorridorScheduledLaneSample]] = [:]
        private var heldUnitDirectionsByStrand:
            [CorridorStrandKey: [(x: Double, y: Double)]] = [:]
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
            recomputeCorridorLaneSchedule()

            laneLayoutsByJourneyID = [:]
            for journey in parent.journeys {
                let densified =
                    densifiedFlagshipCoordinatesByJourneyID[journey.id] ?? []
                laneLayoutsByJourneyID[journey.id] = densified.enumerated()
                    .compactMap { polylineIndex, coordinates in
                        guard coordinates.count >= 2 else { return nil }
                        return sharedCorridorLaneLayout(
                            for: coordinates,
                            journeyID: journey.id,
                            polylineIndex: polylineIndex
                        )
                    }
            }
        }

        /// Dump the corridor lane state to a JSON file for offline
        /// diagnosis: per journey the densified flagship coordinates (the
        /// scheduler's exact input), the anchored-lane schedule (offset,
        /// spine direction, reference per strand segment), and the final
        /// per-vertex layouts the renderer consumes. tools/replay/ingest.py
        /// rebuilds and renders the same shapes, so a reported visual can be
        /// reproduced numerically.
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
                        : (isHighlighted ? RouteMapStyle.standardLineWidth : 2.5),
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
            var occupiedTagFrames: [CGRect] = []
            var insertedTagCount = 0
            let tagBudget = destinationTagBudget(in: mapView)
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
                let layout = destinationTagLayout(
                    at: anchorPoint,
                    edge: anchor.edge,
                    in: mapView
                )
                let collisionFrame = layout.frame.insetBy(dx: -5, dy: -4)
                guard selectedID != nil || occupiedTagFrames.allSatisfy({
                    !$0.intersects(collisionFrame)
                }) else { continue }

                occupiedTagFrames.append(collisionFrame)
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

        private func destinationTagLayout(
            at anchor: CGPoint,
            edge: DestinationViewportEdge,
            in mapView: MKMapView
        ) -> DestinationTagLayout {
            let width: CGFloat = 158
            let height: CGFloat = 42
            let preferredOffset: CGPoint
            switch edge {
            case .inside, .bottom:
                preferredOffset = CGPoint(x: 0, y: -height / 2)
            case .top:
                preferredOffset = CGPoint(x: 0, y: height / 2)
            case .right:
                preferredOffset = CGPoint(x: -width / 2, y: 0)
            case .left:
                preferredOffset = CGPoint(x: width / 2, y: 0)
            }

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
                    x: max(3.5, min(width - 3.5, anchor.x - frame.minX)),
                    y: max(3.5, min(height - 3.5, anchor.y - frame.minY))
                )
            )
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
                width: max(158, mapView.bounds.width - horizontalMargin * 2),
                height: max(42, bottom - top)
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

        private enum CorridorLaneScheduling {
            static let laneSpacing = RouteMapStyle.laneSpacingPoints
            static let joinMinimum: Double = 30
            static let gapBridge: Double = 150
            static let gapChordRatio: Double = 0.75
            static let sideLookahead: Double = 45
            static let centreClearance = laneSpacing / 4
            static let slotClearance = 0.6 * laneSpacing
        }

        private struct CorridorStrandKey: Hashable {
            let journeyID: Int
            let polylineIndex: Int
        }

        private struct CorridorSegmentLocation: Equatable {
            let polylineIndex: Int
            let segmentIndex: Int
        }

        private struct CorridorScheduledLaneSample {
            let offset: Double
            let directionX: Double
            let directionY: Double
            let referenceID: Int
        }

        private struct CorridorSchedStrand {
            let key: CorridorStrandKey
            let points: [MKMapPoint]
            let segments: [MapRouteSegment?]
            let arc: [Double]
            let metersPerMapPoint: Double
        }

        private struct CorridorMemberMatch {
            let segment: MapRouteSegment
            let location: CorridorSegmentLocation
        }

        private struct CorridorLaneRun {
            let strand: CorridorStrandKey
            let start: Int
            let end: Int
        }

        private func corridorPublicRouteKey(for journeyID: Int) -> String {
            guard let geometry = corridorGeometryByJourneyID[journeyID] else {
                return "id:\(journeyID)"
            }
            return "\(geometry.agencyName)|\(geometry.routeNumber)"
        }

        /// Rebuild the anchored-lane schedule and the held-direction chains
        /// from the current densified flagship strands. Called only inside
        /// the corridor-content signature gate.
        private func recomputeCorridorLaneSchedule() {
            var strands: [CorridorStrandKey: CorridorSchedStrand] = [:]
            var held: [CorridorStrandKey: [(x: Double, y: Double)]] = [:]

            for journeyID in densifiedFlagshipCoordinatesByJourneyID.keys {
                guard let densified =
                    densifiedFlagshipCoordinatesByJourneyID[journeyID]
                else { continue }
                for (polylineIndex, coordinates) in densified.enumerated() {
                    guard coordinates.count >= 2 else { continue }
                    let points = coordinates.map { MKMapPoint($0) }
                    let metersPerMapPoint = TripPathGeometry
                        .metersPerMapPoint(atLatitude: coordinates[0].latitude)
                    var segments: [MapRouteSegment?] = []
                    var arc: [Double] = [0]
                    for index in 0..<(points.count - 1) {
                        segments.append(
                            MapRouteSegment(
                                start: points[index],
                                end: points[index + 1]
                            )
                        )
                        arc.append(
                            arc[index]
                                + points[index].distance(to: points[index + 1])
                                    * metersPerMapPoint
                        )
                    }
                    let key = CorridorStrandKey(
                        journeyID: journeyID,
                        polylineIndex: polylineIndex
                    )
                    strands[key] = CorridorSchedStrand(
                        key: key,
                        points: points,
                        segments: segments,
                        arc: arc,
                        metersPerMapPoint: metersPerMapPoint
                    )

                    var directions: [(x: Double, y: Double)] = []
                    var previous: (x: Double, y: Double)?
                    for segment in segments {
                        if let segment {
                            var unitX = segment.unitX
                            var unitY = segment.unitY
                            if let previous,
                               unitX * previous.x + unitY * previous.y < -0.8 {
                                unitX = -unitX
                                unitY = -unitY
                            }
                            directions.append((unitX, unitY))
                            previous = (unitX, unitY)
                        } else {
                            directions.append(previous ?? (x: 1, y: 0))
                        }
                    }
                    held[key] = directions
                }
            }

            heldUnitDirectionsByStrand = held
            corridorLaneSchedule = buildCorridorLaneSchedule(strands)
        }

        private func buildCorridorLaneSchedule(
            _ strands: [CorridorStrandKey: CorridorSchedStrand]
        ) -> [CorridorStrandKey: [Int: CorridorScheduledLaneSample]] {
            guard !strands.isEmpty else { return [:] }
            let scan = corridorMembershipScan(strands)
            var schedule:
                [CorridorStrandKey: [Int: CorridorScheduledLaneSample]] = [:]

            // Runs: maximal sharing stretches per strand, >= 30 m.
            var runs: [CorridorLaneRun] = []
            for (key, strand) in strands.sorted(by: {
                ($0.key.journeyID, $0.key.polylineIndex)
                    < ($1.key.journeyID, $1.key.polylineIndex)
            }) {
                let rows = scan[key] ?? []
                var index = 0
                while index < rows.count {
                    if rows[index].isEmpty {
                        index += 1
                        continue
                    }
                    var end = index + 1
                    while end < rows.count && !rows[end].isEmpty {
                        end += 1
                    }
                    if strand.arc[end] - strand.arc[index]
                        >= CorridorLaneScheduling.joinMinimum {
                        runs.append(
                            CorridorLaneRun(strand: key, start: index, end: end)
                        )
                    }
                    index = end
                }
            }

            // Corridor groups: union runs whose journeys share members.
            var parent = Array(runs.indices)
            func find(_ x: Int) -> Int {
                var root = x
                while parent[root] != root {
                    parent[root] = parent[parent[root]]
                    root = parent[root]
                }
                return root
            }
            var runsByJourney: [Int: [Int]] = [:]
            for (index, run) in runs.enumerated() {
                runsByJourney[run.strand.journeyID, default: []].append(index)
            }
            for (index, run) in runs.enumerated() {
                let key = run.strand
                let rows = scan[key] ?? []
                var members = Set<Int>()
                for si in run.start..<run.end {
                    members.formUnion(rows[si].keys)
                }
                members.insert(key.journeyID)
                for memberID in members {
                    for otherIndex in runsByJourney[memberID] ?? [] {
                        let rootA = find(index)
                        let rootB = find(otherIndex)
                        if rootA != rootB {
                            parent[rootA] = rootB
                        }
                    }
                }
            }
            var groups: [Int: [Int]] = [:]
            for index in runs.indices {
                groups[find(index), default: []].append(index)
            }

            // Longest corridors first, longest runs first inside a corridor.
            for (_, runIndices) in groups.sorted(by: {
                if $0.value.count != $1.value.count {
                    return $0.value.count > $1.value.count
                }
                return $0.key < $1.key
            }) {
                let ordered = runIndices.sorted(by: {
                    let firstLength = runLength(runs[$0], strands: strands)
                    let secondLength = runLength(runs[$1], strands: strands)
                    if firstLength != secondLength {
                        return firstLength > secondLength
                    }
                    return $0 < $1
                })
                var memory: [String: Double] = [:]
                for runIndex in ordered {
                    let outcome = sweepCorridorRun(
                        runs[runIndex],
                        strands: strands,
                        scan: scan,
                        schedule: schedule,
                        memory: memory
                    )
                    schedule = outcome.schedule
                    memory = outcome.memory
                }
            }

            postFillSchedule(strands, scan, &schedule)
            return schedule
        }

        private func runLength(
            _ run: CorridorLaneRun,
            strands: [CorridorStrandKey: CorridorSchedStrand]
        ) -> Double {
            guard let strand = strands[run.strand] else { return 0 }
            return strand.arc[run.end] - strand.arc[run.start]
        }

        /// Per strand, per segment: {other journey: matched segment} — the
        /// same midpoint-plus-endpoints parallel test the layout pass uses.
        private func corridorMembershipScan(
            _ strands: [CorridorStrandKey: CorridorSchedStrand]
        ) -> [CorridorStrandKey: [[Int: CorridorMemberMatch]]] {
            var scan: [CorridorStrandKey: [[Int: CorridorMemberMatch]]] = [:]
            for (key, strand) in strands {
                var rows: [[Int: CorridorMemberMatch]] = []
                rows.reserveCapacity(strand.segments.count)
                for segment in strand.segments {
                    guard let segment else {
                        rows.append([:])
                        continue
                    }
                    let midpoint = MKMapPoint(
                        x: (segment.start.x + segment.end.x) / 2,
                        y: (segment.start.y + segment.end.y) / 2
                    )
                    var members: [Int: CorridorMemberMatch] = [:]
                    for (candidateID, geometry) in corridorGeometryByJourneyID
                    where candidateID != key.journeyID {
                        guard let member = geometry.segmentIndex.parallelMember(
                            near: midpoint,
                            direction: segment,
                            metersPerMapPoint: strand.metersPerMapPoint
                        ),
                            hasParallelCorridor(
                                near: segment.start,
                                direction: segment,
                                among: geometry.segmentIndex.segments(
                                    near: segment.start
                                ),
                                metersPerMapPoint: strand.metersPerMapPoint
                            ),
                            hasParallelCorridor(
                                near: segment.end,
                                direction: segment,
                                among: geometry.segmentIndex.segments(
                                    near: segment.end
                                ),
                                metersPerMapPoint: strand.metersPerMapPoint
                            )
                        else { continue }
                        members[candidateID] = CorridorMemberMatch(
                            segment: member.segment,
                            location: member.location
                        )
                    }
                    rows.append(members)
                }
                scan[key] = rows
            }
            return scan
        }

        private func sweepCorridorRun(
            _ run: CorridorLaneRun,
            strands: [CorridorStrandKey: CorridorSchedStrand],
            scan: [CorridorStrandKey: [[Int: CorridorMemberMatch]]],
            schedule: [CorridorStrandKey: [Int: CorridorScheduledLaneSample]],
            memory: [String: Double]
        ) -> (schedule: [CorridorStrandKey: [Int: CorridorScheduledLaneSample]],
              memory: [String: Double]) {
            let key = run.strand
            guard let strand = strands[key] else {
                return (schedule, memory)
            }
            let rows = scan[key] ?? []
            let s0 = run.start
            let s1 = run.end
            var schedule = schedule
            var memory = memory

            // Presence stretches of every member over this sweep, debounced.
            var presence: [Int: [(Int, Int)]] = [
                key.journeyID: [(s0, s1)]
            ]
            var memberIDs = Set<Int>()
            for si in s0..<s1 {
                guard si < rows.count else { break }
                memberIDs.formUnion(rows[si].keys)
            }
            for cid in memberIDs.sorted() {
                let stretches = debouncedPresence(
                    rows, from: s0, to: s1, member: cid, arc: strand.arc
                )
                if !stretches.isEmpty {
                    presence[cid] = stretches
                }
            }

            func segmentDirection(at si: Int) -> (Double, Double) {
                if si >= 0 && si < strand.segments.count,
                   let segment = strand.segments[si] {
                    return (segment.unitX, segment.unitY)
                }
                let fallbackIndex = max(s0, si - 1)
                if fallbackIndex >= 0 && fallbackIndex < strand.segments.count,
                   let fallback = strand.segments[fallbackIndex] {
                    return (fallback.unitX, fallback.unitY)
                }
                return (x: 1, y: 0)
            }

            func matched(_ cid: Int, _ si: Int) -> CorridorMemberMatch? {
                guard si >= 0 && si < rows.count else { return nil }
                return rows[si][cid]
            }

            func ownLocation(_ cid: Int, _ si: Int) -> CorridorSegmentLocation? {
                matched(cid, si)?.location
            }

            func nearestOwnLocation(
                _ cid: Int,
                _ si: Int
            ) -> CorridorSegmentLocation? {
                var best: (distance: Int, probe: Int)?
                for probe in max(s0, si - 24)..<min(s1, si + 24) {
                    guard matched(cid, probe) != nil else { continue }
                    let distance = abs(probe - si)
                    if best == nil || distance < best!.distance {
                        best = (distance, probe)
                    }
                }
                guard let best else { return nil }
                return ownLocation(cid, best.probe)
            }

            func memberStrand(
                _ location: CorridorSegmentLocation,
                _ cid: Int
            ) -> CorridorSchedStrand? {
                strands[
                    CorridorStrandKey(
                        journeyID: cid,
                        polylineIndex: location.polylineIndex
                    )
                ]
            }

            func sideSign(
                of point: MKMapPoint,
                from origin: MKMapPoint,
                direction: (Double, Double)
            ) -> Int? {
                let leftX = -direction.1
                let leftY = direction.0
                let side = (point.x - origin.x) * leftX
                    + (point.y - origin.y) * leftY
                if abs(side) * strand.metersPerMapPoint < 2 {
                    return nil
                }
                return side > 0 ? 1 : -1
            }

            func joinSide(_ cid: Int, _ si: Int) -> Int? {
                guard let location = ownLocation(cid, si),
                      location.segmentIndex > 0,
                      let member = memberStrand(location, cid)
                else { return nil }
                var back = location.segmentIndex
                var travelled = 0.0
                while back > 0 && travelled < CorridorLaneScheduling
                    .sideLookahead {
                    travelled += member.points[back - 1]
                        .distance(to: member.points[back])
                        * strand.metersPerMapPoint
                    back -= 1
                }
                guard si > 0 || strand.segments[si] != nil else { return nil }
                let segment = strand.segments[si] ?? strand.segments[si - 1]
                guard let segment else { return nil }
                return sideSign(
                    of: member.points[back],
                    from: segment.start,
                    direction: segmentDirection(at: si)
                )
            }

            func exitSide(_ cid: Int, _ outSi: Int) -> Int? {
                var probe: Int?
                var match: CorridorMemberMatch?
                var index = min(outSi, s1 - 1)
                while index >= s0 {
                    if let candidate = matched(cid, index) {
                        match = candidate
                        probe = index
                        break
                    }
                    index -= 1
                }
                guard let match, let probe else { return nil }
                guard let member = memberStrand(match.location, cid),
                      match.location.segmentIndex < member.points.count - 1
                else { return nil }
                var forward = match.location.segmentIndex
                var travelled = 0.0
                while forward < member.points.count - 1
                        && travelled < CorridorLaneScheduling.sideLookahead {
                    travelled += member.points[forward]
                        .distance(to: member.points[forward + 1])
                        * strand.metersPerMapPoint
                    forward += 1
                }
                guard let segment = strand.segments[probe] else { return nil }
                return sideSign(
                    of: member.points[forward],
                    from: segment.start,
                    direction: segmentDirection(at: probe)
                )
            }

            func groupSign(_ cid: Int, _ si: Int) -> Int {
                guard let location = ownLocation(cid, si),
                      let member = memberStrand(location, cid),
                      let segment = member.segments[
                          min(location.segmentIndex,
                              member.segments.count - 1)
                      ]
                else { return 1 }
                let direction = segmentDirection(at: si)
                let dot = segment.unitX * direction.0
                    + segment.unitY * direction.1
                return dot >= 0 ? 1 : -1
            }

            // Sweep state.
            var slots: [String: Double] = [:]
            var slotGroups: [String: Int] = [:]
            var stickyReferenceID: Int?

            func presentJourneys(_ si: Int) -> [Int] {
                presence.keys
                    .filter { cid in
                        (presence[cid] ?? []).contains {
                            $0.0 <= si && si < $0.1
                        }
                    }
                    .sorted(by: corridorLaneComesBefore)
            }

            func presentKeys(_ si: Int) -> [String] {
                var seen = Set<String>()
                var keys: [String] = []
                for cid in presentJourneys(si) {
                    let key = corridorPublicRouteKey(for: cid)
                    if seen.insert(key).inserted {
                        keys.append(key)
                    }
                }
                return keys
            }

            func occupied() -> [Double] {
                Array(slots.values)
            }

            func freeSlot(_ candidate: Double, step: Double) -> Double {
                var slot = candidate
                while occupied().contains(where: { taken in
                    abs(slot - taken) < CorridorLaneScheduling.slotClearance
                }) {
                    slot += step
                }
                return slot
            }

            func crossesCentre(_ candidate: Double, gsign: Int) -> Bool {
                guard slotGroups.values.contains(-gsign) else { return false }
                return candidate * Double(gsign)
                    < CorridorLaneScheduling.centreClearance
            }

            func groupOffsets(_ gsign: Int) -> [Double] {
                slots.filter { slotGroups[$0.key] == gsign }.map(\.value)
            }

            func outermost(_ offsets: [Double], outward: Int) -> Double {
                outward > 0 ? offsets.max() ?? 0 : offsets.min() ?? 0
            }

            func innermost(_ offsets: [Double], outward: Int) -> Double {
                outward > 0 ? offsets.min() ?? 0 : offsets.max() ?? 0
            }

            func numericRank(_ present: [Int], _ cid: Int) -> Int {
                var rank = 0
                for other in present where other != cid {
                    guard slots[corridorPublicRouteKey(for: other)] == nil
                    else { continue }
                    if corridorLaneComesBefore(other, cid) {
                        rank += 1
                    }
                }
                return rank
            }

            func place(_ cid: Int, side: Int?, gsign: Int, rank: Int) -> Double {
                let offsets = groupOffsets(gsign)
                let outward = gsign >= 0 ? 1 : -1
                if offsets.isEmpty {
                    let firstSlot = CorridorLaneScheduling.laneSpacing / 2
                        * Double(gsign)
                    if occupied().allSatisfy({ abs(firstSlot - $0)
                        >= CorridorLaneScheduling.slotClearance }) {
                        return firstSlot
                    }
                    return freeSlot(
                        firstSlot,
                        step: CorridorLaneScheduling.laneSpacing / 2
                            * Double(outward)
                    )
                }
                if side == nil {
                    let ordered = offsets.sorted()
                    let target: Double
                    if rank >= ordered.count {
                        target = outermost(offsets, outward: outward)
                            + CorridorLaneScheduling.laneSpacing * Double(outward)
                    } else if outward > 0 {
                        target = ordered[rank]
                    } else {
                        target = ordered.reversed()[rank]
                    }
                    if occupied().allSatisfy({ abs(target - $0)
                        >= CorridorLaneScheduling.slotClearance }) {
                        return target
                    }
                    return freeSlot(
                        target,
                        step: CorridorLaneScheduling.laneSpacing / 2
                            * Double(outward)
                    )
                }
                if side == outward {
                    let base = outermost(offsets, outward: outward)
                        + CorridorLaneScheduling.laneSpacing * Double(outward)
                    return freeSlot(
                        base,
                        step: CorridorLaneScheduling.laneSpacing / 2
                            * Double(outward)
                    )
                }
                let innerBase = innermost(offsets, outward: outward)
                    - CorridorLaneScheduling.laneSpacing * Double(outward)
                if !crossesCentre(innerBase, gsign: gsign) {
                    let candidate = freeSlot(
                        innerBase,
                        step: -CorridorLaneScheduling.laneSpacing / 2
                            * Double(outward)
                    )
                    if !crossesCentre(candidate, gsign: gsign) {
                        return candidate
                    }
                }
                let outerBase = outermost(offsets, outward: outward)
                    + CorridorLaneScheduling.laneSpacing * Double(outward)
                return freeSlot(
                    outerBase,
                    step: CorridorLaneScheduling.laneSpacing / 2
                        * Double(outward)
                )
            }

            func nearestScheduledSample(
                _ cid: Int,
                _ location: CorridorSegmentLocation
            ) -> CorridorScheduledLaneSample? {
                let memberKey = CorridorStrandKey(
                    journeyID: cid,
                    polylineIndex: location.polylineIndex
                )
                let entries = schedule[memberKey] ?? [:]
                let si = location.segmentIndex
                for delta in 0..<12 {
                    for probe in [si - delta, si + delta] where probe >= 0 {
                        if let sample = entries[probe] {
                            return sample
                        }
                    }
                }
                return nil
            }

            func adoptExisting(_ si: Int) {
                for cid in presentJourneys(si) {
                    let slotKey = corridorPublicRouteKey(for: cid)
                    guard slots[slotKey] == nil else { continue }
                    let own: CorridorSegmentLocation
                    if cid == key.journeyID {
                        own = CorridorSegmentLocation(
                            polylineIndex: key.polylineIndex,
                            segmentIndex: si
                        )
                    } else {
                        guard let location = ownLocation(cid, si)
                            ?? nearestOwnLocation(cid, si)
                        else { continue }
                        own = location
                    }
                    guard let sample = nearestScheduledSample(cid, own)
                    else { continue }
                    let direction = segmentDirection(at: si)
                    let sign: Double = sample.directionX * direction.0
                        + sample.directionY * direction.1 >= 0 ? 1 : -1
                    slots[slotKey] = sample.offset * sign
                    slotGroups[slotKey] = groupSign(cid, si)
                }
            }

            func exitAwareSide(
                for cid: Int,
                at si: Int
            ) -> Int? {
                if let side = joinSide(cid, si) {
                    return side
                }
                // A strand born on the corridor (trip start / boarding stop)
                // appears in place, so any free slot is crossing free: prefer
                // the side it will peel off toward, so a fork's strands sit
                // adjacent, subway-style. Includes presence that runs to the
                // sweep end: the spine's last partner peels there too.
                let outSi = presence[cid]?
                    .first { $0.0 <= si && si < $0.1 }?.1 ?? s1
                return exitSide(cid, min(outSi, s1))
            }

            func birth(_ si: Int) {
                if !slots.isEmpty {
                    // Chained sweep start where earlier lanes exist.
                    for cid in presentJourneys(si) {
                        let key = corridorPublicRouteKey(for: cid)
                        guard slots[key] == nil else { continue }
                        let gsign = groupSign(cid, si)
                        slotGroups[key] = gsign
                        let rank = numericRank(presentJourneys(si), cid)
                        let side = exitAwareSide(for: cid, at: si)
                        slots[key] = place(
                            cid,
                            side: side,
                            gsign: gsign,
                            rank: rank
                        )
                    }
                    return
                }
                struct CohortMember {
                    let journeyID: Int
                    let key: String
                    let gsign: Int
                    let outSi: Int
                    let side: Int?
                }
                var cohort: [CohortMember] = []
                for cid in presentJourneys(si) {
                    let key = corridorPublicRouteKey(for: cid)
                    guard slots[key] == nil else { continue }
                    let gsign = groupSign(cid, si)
                    let outSi = presence[cid]?
                        .first { $0.0 <= si && si < $0.1 }?.1
                        ?? s1
                    // Presence running to the sweep end usually means this
                    // strand is the spine's last partner: the run ended
                    // because it left. exitSide walks the strand's own
                    // continuation past its last match, so calling it at the
                    // run end still tells peel-off (a side) from a true
                    // stayer that carries on along the street (nil).
                    let side = exitSide(cid, min(outSi, s1))
                    cohort.append(
                        CohortMember(
                            journeyID: cid,
                            key: key,
                            gsign: gsign,
                            outSi: outSi,
                            side: side
                        )
                    )
                    slotGroups[key] = gsign
                }
                let withGroup = cohort.filter { $0.gsign >= 0 }
                let against = cohort.filter { $0.gsign < 0 }
                let both = !withGroup.isEmpty && !against.isEmpty

                func ordered(
                    _ group: [CohortMember],
                    sign: Int
                ) -> [CohortMember] {
                    let leavingLeft = group
                        .filter { $0.side == 1 }
                        .sorted { $0.outSi < $1.outSi }
                    let leavingRight = group
                        .filter { $0.side == -1 }
                        .sorted { $0.outSi < $1.outSi }
                    let staying = group
                        .filter { $0.side == nil }
                        .sorted { corridorLaneComesBefore($0.journeyID, $1.journeyID) }
                    return sign >= 0
                        ? leavingRight + staying + leavingLeft.reversed()
                        : leavingLeft + staying + leavingRight.reversed()
                }

                for (group, sign) in [(withGroup, 1), (against, -1)] {
                    let sequence = ordered(group, sign: sign)
                    guard !sequence.isEmpty else { continue }
                    if !both {
                        let count = sequence.count
                        for (index, member) in sequence.enumerated() {
                            slots[member.key] =
                                (Double(index) - Double(count - 1) / 2)
                                    * CorridorLaneScheduling.laneSpacing
                                    * (sign >= 0 ? 1 : -1)
                        }
                        continue
                    }
                    var slot = CorridorLaneScheduling.laneSpacing / 2
                        * Double(sign)
                    for member in sequence {
                        slots[member.key] = slot
                        slot += CorridorLaneScheduling.laneSpacing
                            * Double(sign)
                    }
                }
            }

            func record(_ bstart: Int, _ bend: Int, _ siRef: Int) {
                let present = presentJourneys(siRef)
                let referenceKeys = Set(
                    present.map { corridorPublicRouteKey(for: $0) }
                )
                if let current = stickyReferenceID,
                   referenceKeys.contains(
                       corridorPublicRouteKey(for: current)
                   ) {
                    stickyReferenceID = current
                } else {
                    stickyReferenceID = present.first
                }
                guard let referenceID = stickyReferenceID else { return }
                for si in bstart..<bend {
                    let direction = segmentDirection(at: si)
                    let spineKey = corridorPublicRouteKey(for: key.journeyID)
                    if let spineSlot = slots[spineKey],
                       schedule[key]?[si] == nil {
                        schedule[key, default: [:]][si] =
                            CorridorScheduledLaneSample(
                                offset: spineSlot,
                                directionX: direction.0,
                                directionY: direction.1,
                                referenceID: referenceID
                            )
                    }
                    for cid in present {
                        guard let offset = slots[
                            corridorPublicRouteKey(for: cid)
                        ] else { continue }
                        guard let location = ownLocation(cid, si)
                        else { continue }
                        let memberKey = CorridorStrandKey(
                            journeyID: cid,
                            polylineIndex: location.polylineIndex
                        )
                        guard schedule[memberKey]?[location.segmentIndex]
                            == nil else { continue }
                        schedule[memberKey, default: [:]][location.segmentIndex] =
                            CorridorScheduledLaneSample(
                                offset: offset,
                                directionX: direction.0,
                                directionY: direction.1,
                                referenceID: referenceID
                            )
                    }
                }
            }

            // Event bounds: run ends plus every presence stretch edge.
            var bounds = Set([s0, s1])
            for stretches in presence.values {
                for (start, end) in stretches {
                    if s0 <= start && start <= s1 {
                        bounds.insert(start)
                    }
                    if s0 <= end && end <= s1 {
                        bounds.insert(end)
                    }
                }
            }
            let orderedBounds = bounds.sorted()

            var previous: Int?
            for index in 0..<(orderedBounds.count - 1) {
                let bstart = orderedBounds[index]
                let bend = orderedBounds[index + 1]
                guard bend > bstart else { continue }
                let si = bstart
                adoptExisting(si)
                if previous == nil {
                    birth(si)
                } else {
                    let before = presentKeys(previous!)
                    let after = presentKeys(si)
                    for key in before
                    where !after.contains(key) && slots[key] != nil {
                        memory[key] = slots.removeValue(forKey: key)
                        slotGroups.removeValue(forKey: key)
                    }
                    for cid in presentJourneys(si) {
                        let key = corridorPublicRouteKey(for: cid)
                        guard slots[key] == nil else { continue }
                        slotGroups[key] = groupSign(cid, si)
                        if let remembered = memory[key],
                           occupied().allSatisfy({ abs(remembered - $0)
                               >= CorridorLaneScheduling.slotClearance }) {
                            slots[key] = remembered
                            continue
                        }
                        let rank = numericRank(presentJourneys(si), cid)
                        let side = exitAwareSide(for: cid, at: si)
                        slots[key] = place(
                            cid,
                            side: side,
                            gsign: slotGroups[key] ?? 1,
                            rank: rank
                        )
                    }
                }
                record(bstart, bend, si)
                previous = si
            }

            return (schedule, memory)
        }

        /// Presence stretches of one member over a sweep: dropouts up to
        /// `gapBridge` merge, stretches under `joinMinimum` drop.
        private func debouncedPresence(
            _ rows: [[Int: CorridorMemberMatch]],
            from s0: Int,
            to s1: Int,
            member cid: Int,
            arc: [Double]
        ) -> [(Int, Int)] {
            var stretches: [(Int, Int)] = []
            var index = s0
            while index < s1 && index < rows.count {
                if rows[index][cid] != nil {
                    var end = index + 1
                    while end < s1 && end < rows.count
                            && rows[end][cid] != nil {
                        end += 1
                    }
                    stretches.append((index, end))
                    index = end
                } else {
                    index += 1
                }
            }
            guard !stretches.isEmpty else { return [] }
            var bridged = [stretches[0]]
            for stretch in stretches.dropFirst() {
                let previousEnd = bridged[bridged.count - 1].1
                if arc[stretch.0] - arc[previousEnd]
                    <= CorridorLaneScheduling.gapBridge {
                    bridged[bridged.count - 1].1 =
                        max(previousEnd, stretch.1)
                } else {
                    bridged.append(stretch)
                }
            }
            return bridged.filter {
                arc[$0.1] - arc[$0.0]
                    >= CorridorLaneScheduling.joinMinimum
            }
        }

        /// Hold a lane through short schedule dropouts inside a strand's
        /// shared run (same distance and straightness gates as the gap
        /// bridge downstream), but only when both anchors agree.
        private func postFillSchedule(
            _ strands: [CorridorStrandKey: CorridorSchedStrand],
            _ scan: [CorridorStrandKey: [[Int: CorridorMemberMatch]]],
            _ schedule: inout [CorridorStrandKey: [Int: CorridorScheduledLaneSample]]
        ) {
            for (key, strand) in strands.sorted(by: {
                ($0.key.journeyID, $0.key.polylineIndex)
                    < ($1.key.journeyID, $1.key.polylineIndex)
            }) {
                let rows = scan[key] ?? []
                var index = 0
                while index < rows.count {
                    if rows[index].isEmpty {
                        index += 1
                        continue
                    }
                    var end = index + 1
                    while end < rows.count && !rows[end].isEmpty {
                        end += 1
                    }
                    let entries = schedule[key] ?? [:]
                    let assigned = (index..<end).filter { entries[$0] != nil }
                    if let first = assigned.first, let last = assigned.last,
                       first < last {
                        for slot in (first + 1)..<last {
                            guard entries[slot] == nil else { continue }
                            let left = assigned.filter { $0 < slot }.max()!
                            let right = assigned.filter { $0 > slot }.min()!
                            guard let before = entries[left],
                                  let after = entries[right]
                            else { continue }
                            guard abs(before.offset - after.offset) < 0.0005,
                                  before.referenceID == after.referenceID
                            else { continue }
                            let path = strand.arc[slot] - strand.arc[left]
                            let chord = strand.points[left]
                                .distance(to: strand.points[slot])
                                    * strand.metersPerMapPoint
                            if path <= CorridorLaneScheduling.gapBridge,
                               chord >= CorridorLaneScheduling.gapChordRatio
                                    * max(path, 1e-6) {
                                schedule[key, default: [:]][slot] = before
                            }
                        }
                    }
                    index = end
                }
            }
        }

        private func sharedCorridorLaneLayout(
            for coordinates: [CLLocationCoordinate2D],
            journeyID: Int,
            polylineIndex: Int
        ) -> CorridorLaneLayout {
            guard coordinates.count >= 2 else {
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
            // All physical thresholds in the corridor pass are meters; map
            // points are projected units (~8.1 per meter in Santa Barbara).
            let metersPerMapPoint = TripPathGeometry.metersPerMapPoint(
                atLatitude: coordinates[0].latitude
            )
            var segmentLayouts: [CorridorSegmentLayout?] = []
            segmentLayouts.reserveCapacity(points.count - 1)
            for index in 0..<(points.count - 1) {
                guard let segment = MapRouteSegment(
                    start: points[index],
                    end: points[index + 1]
                ) else {
                    segmentLayouts.append(nil)
                    continue
                }
                segmentLayouts.append(
                    sharedCorridorSegmentLayout(
                        for: segment,
                        journeyID: journeyID,
                        polylineIndex: polylineIndex,
                        segmentIndex: index,
                        metersPerMapPoint: metersPerMapPoint
                    )
                )
            }

            // A parallel shape seen for only a few meters is normally an
            // intersection, a terminal bay, or a near-parallel turn—not a shared
            // road. Refusing those tiny runs removes one-vertex side-steps without
            // deleting any authoritative route geometry.
            removeShortCorridorRuns(
                points: points,
                layouts: &segmentLayouts,
                metersPerMapPoint: metersPerMapPoint
            )

            var offsetSums = Array(repeating: 0.0, count: points.count)
            var offsetCounts = Array(repeating: 0, count: points.count)
            var alignmentDeltaX = Array(repeating: 0.0, count: points.count)
            var alignmentDeltaY = Array(repeating: 0.0, count: points.count)
            var trunkOwnerVotes = Array(repeating: 0, count: points.count)
            var referenceVotes = Array(
                repeating: [Int: Int](),
                count: points.count
            )

            for (index, optionalLayout) in segmentLayouts.enumerated() {
                guard let layout = optionalLayout else { continue }
                offsetSums[index] += layout.offset
                offsetSums[index + 1] += layout.offset
                offsetCounts[index] += 1
                offsetCounts[index + 1] += 1
                alignmentDeltaX[index] += layout.alignedStart.x - points[index].x
                alignmentDeltaY[index] += layout.alignedStart.y - points[index].y
                alignmentDeltaX[index + 1] += layout.alignedEnd.x - points[index + 1].x
                alignmentDeltaY[index + 1] += layout.alignedEnd.y - points[index + 1].y
                referenceVotes[index][layout.referenceID, default: 0] += 1
                referenceVotes[index + 1][layout.referenceID, default: 0] += 1
                if layout.isTrunkOwner {
                    trunkOwnerVotes[index] += 1
                    trunkOwnerVotes[index + 1] += 1
                }
            }

            var offsets = offsetSums.indices.map { index in
                guard offsetCounts[index] > 0 else { return 0.0 }
                alignmentDeltaX[index] /= Double(offsetCounts[index])
                alignmentDeltaY[index] /= Double(offsetCounts[index])
                return offsetSums[index] / Double(offsetCounts[index])
            }
            var explicitlyStacked = offsetCounts.map { $0 > 0 }
            var trunkOwnerVertices = trunkOwnerVotes.map { $0 > 0 }
            var corridorReferenceIDs = referenceVotes.map { votes -> Int? in
                votes.keys.sorted { firstID, secondID in
                    let firstVotes = votes[firstID] ?? 0
                    let secondVotes = votes[secondID] ?? 0
                    if firstVotes != secondVotes {
                        return firstVotes > secondVotes
                    }
                    return corridorLaneComesBefore(firstID, secondID)
                }.first
            }

            // The first shared section establishes this strand's lane. Hold that
            // lane for the whole contiguous corridor: another route entering or
            // leaving is not allowed to recenter continuing strands. A route that
            // joins later takes an outside lane of its own and tapers into it.
            stabilizeCorridorRunOffsets(
                points: points,
                layouts: segmentLayouts,
                offsets: &offsets,
                metersPerMapPoint: metersPerMapPoint
            )

            // Fill only small misses that return to the same physical spine and
            // nearly the same lane. Broad bridging was able to pull a strand across
            // a downtown turn and create the diagonal jogs visible in testing.
            bridgeShortCorridorGaps(
                points: points,
                explicitlyStacked: &explicitlyStacked,
                trunkOwnerVertices: &trunkOwnerVertices,
                corridorReferenceIDs: &corridorReferenceIDs,
                offsets: &offsets,
                deltaX: &alignmentDeltaX,
                deltaY: &alignmentDeltaY,
                metersPerMapPoint: metersPerMapPoint
            )

            // Centerline corrections still follow bends, but cannot jump laterally
            // when the locally preferred reference shape changes.
            stabilizeSharedAlignmentTransitions(
                points: points,
                explicitlyStacked: explicitlyStacked,
                deltaX: &alignmentDeltaX,
                deltaY: &alignmentDeltaY
            )

            // Fade both the lane and the small centerline correction back to the
            // route's own shape. Branches peel away gradually instead of gaining a
            // diagonal connector where a shared corridor starts or ends.
            let taperDistance: CLLocationDistance = 58
            if offsets.count > 1 {
                var i = 0
                while i < offsets.count {
                    while i < offsets.count && !explicitlyStacked[i] {
                        i += 1
                    }
                    guard i < offsets.count else { break }
                    let runStart = i
                    while i < offsets.count && explicitlyStacked[i] {
                        i += 1
                    }
                    let runEnd = i - 1

                    // Backward taper before runStart
                    var backwardAccumulated: CLLocationDistance = 0
                    let startOffset = offsets[runStart]
                    let startDeltaX = alignmentDeltaX[runStart]
                    let startDeltaY = alignmentDeltaY[runStart]
                    for backIndex in stride(from: runStart - 1, through: 0, by: -1) {
                        if explicitlyStacked[backIndex] { break }
                        backwardAccumulated += points[backIndex].distance(
                            to: points[backIndex + 1]
                        ) * metersPerMapPoint
                        if backwardAccumulated >= taperDistance { break }
                        let factor = 1.0 - (backwardAccumulated / taperDistance)
                        applyTaperedLayout(
                            factor: factor,
                            sourceOffset: startOffset,
                            sourceDeltaX: startDeltaX,
                            sourceDeltaY: startDeltaY,
                            destinationIndex: backIndex,
                            offsets: &offsets,
                            deltaX: &alignmentDeltaX,
                            deltaY: &alignmentDeltaY
                        )
                    }

                    // Forward taper after runEnd
                    var forwardAccumulated: CLLocationDistance = 0
                    let endOffset = offsets[runEnd]
                    let endDeltaX = alignmentDeltaX[runEnd]
                    let endDeltaY = alignmentDeltaY[runEnd]
                    for forwardIndex in (runEnd + 1)..<offsets.count {
                        if explicitlyStacked[forwardIndex] { break }
                        forwardAccumulated += points[forwardIndex - 1].distance(
                            to: points[forwardIndex]
                        ) * metersPerMapPoint
                        if forwardAccumulated >= taperDistance { break }
                        let factor = 1.0 - (forwardAccumulated / taperDistance)
                        applyTaperedLayout(
                            factor: factor,
                            sourceOffset: endOffset,
                            sourceDeltaX: endDeltaX,
                            sourceDeltaY: endDeltaY,
                            destinationIndex: forwardIndex,
                            offsets: &offsets,
                            deltaX: &alignmentDeltaX,
                            deltaY: &alignmentDeltaY
                        )
                    }
                }
            }

            // The locally preferred reference shape can change where a
            // companion route turns off (route 6 leaves Chapala at Sola, so
            // the 12x/24x corridor re-references there). The correction
            // itself is bounded to six meters, but without a rate limit it
            // steps by that full amount within a vertex or two — a one-sided
            // diagonal jog at the corner. Limit the correction to a gentle
            // ramp; a sustained feed-drift correction is unaffected because
            // only the rate of change is clamped. Two passes (forward, then
            // backward) make the limiter symmetric.
            let maximumAlignmentRamp = 0.08  // meters of correction per meter
            if points.count > 2 {
                for index in 1..<points.count {
                    let segmentMeters = points[index - 1].distance(
                        to: points[index]
                    ) * metersPerMapPoint
                    let budget = maximumAlignmentRamp * segmentMeters
                    let stepX = alignmentDeltaX[index] - alignmentDeltaX[index - 1]
                    let stepY = alignmentDeltaY[index] - alignmentDeltaY[index - 1]
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
                    let segmentMeters = points[index].distance(
                        to: points[index + 1]
                    ) * metersPerMapPoint
                    let budget = maximumAlignmentRamp * segmentMeters
                    let stepX = alignmentDeltaX[index] - alignmentDeltaX[index + 1]
                    let stepY = alignmentDeltaY[index] - alignmentDeltaY[index + 1]
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

            let alignedCoordinates = points.indices.map { index in
                MKMapPoint(
                    x: points[index].x + alignmentDeltaX[index],
                    y: points[index].y + alignmentDeltaY[index]
                ).coordinate
            }
            return CorridorLaneLayout(
                coordinates: alignedCoordinates,
                offsets: offsets,
                sharedVertices: explicitlyStacked,
                trunkOwnerVertices: trunkOwnerVertices
            )
        }

        private func removeShortCorridorRuns(
            points: [MKMapPoint],
            layouts: inout [CorridorSegmentLayout?],
            metersPerMapPoint: Double
        ) {
            let minimumSharedDistance: CLLocationDistance = 30
            guard layouts.count == points.count - 1 else { return }
            var runStart = 0

            while runStart < layouts.count {
                while runStart < layouts.count, layouts[runStart] == nil {
                    runStart += 1
                }
                guard runStart < layouts.count else { break }
                var runEnd = runStart + 1
                while runEnd < layouts.count, layouts[runEnd] != nil {
                    runEnd += 1
                }
                let runDistance = (runStart..<runEnd).reduce(0.0) {
                    distance, index in
                    distance + points[index].distance(to: points[index + 1])
                        * metersPerMapPoint
                }
                if runDistance < minimumSharedDistance {
                    for index in runStart..<runEnd {
                        layouts[index] = nil
                    }
                }
                runStart = runEnd
            }
        }

        private func stabilizeCorridorRunOffsets(
            points: [MKMapPoint],
            layouts: [CorridorSegmentLayout?],
            offsets: inout [Double],
            metersPerMapPoint: Double
        ) {
            guard offsets.count == layouts.count + 1,
                  points.count == offsets.count,
                  points.count > 1
            else { return }

            // `offsets` already holds the compact local stack at each vertex.
            // Freezing the first shared lane for the whole run is what left
            // ribbons on the sidewalk after companions turned off — the lane
            // never moved back. Blend only among still-shared vertices so a
            // shrinking stack slides onto the street, while run edges still
            // hand off to the existing centerline taper.
            func vertexIsShared(_ index: Int) -> Bool {
                (index < layouts.count && layouts[index] != nil)
                    || (index > 0 && layouts[index - 1] != nil)
            }

            let transitionDistance: CLLocationDistance = 72
            let original = offsets
            for index in original.indices {
                guard vertexIsShared(index) else { continue }
                var weightedSum = original[index]
                var weightTotal = 1.0

                var distance: CLLocationDistance = 0
                var back = index
                while back > 0 {
                    distance += points[back - 1].distance(to: points[back])
                        * metersPerMapPoint
                    if distance > transitionDistance { break }
                    guard vertexIsShared(back - 1) else { break }
                    let weight = 1.0 - distance / transitionDistance
                    weightedSum += original[back - 1] * weight
                    weightTotal += weight
                    back -= 1
                }

                distance = 0
                var forward = index
                while forward < original.count - 1 {
                    distance += points[forward].distance(to: points[forward + 1])
                        * metersPerMapPoint
                    if distance > transitionDistance { break }
                    guard vertexIsShared(forward + 1) else { break }
                    let weight = 1.0 - distance / transitionDistance
                    weightedSum += original[forward + 1] * weight
                    weightTotal += weight
                    forward += 1
                }

                offsets[index] = weightedSum / weightTotal
            }
        }
        
        private func bridgeShortCorridorGaps(
            points: [MKMapPoint],
            explicitlyStacked: inout [Bool],
            trunkOwnerVertices: inout [Bool],
            corridorReferenceIDs: inout [Int?],
            offsets: inout [Double],
            deltaX: inout [Double],
            deltaY: inout [Double],
            metersPerMapPoint: Double
        ) {
            // Matches the corridor-continuation distance used when stabilizing
            // run offsets: a dropout short enough to hold its lane through is
            // also short enough to bridge, so the ribbon stays straight instead
            // of pinching to the centerline and fanning back out. The gates
            // below (same reference shape, same side, at most one lane of
            // change, and a path that actually runs straight along the
            // corridor) still prevent bridging across a genuine turn.
            let maximumGapDistance: CLLocationDistance = 150
            let maximumLaneChange = RouteMapStyle.laneSpacingPoints * 1.1
            guard points.count > 2,
                  points.count == explicitlyStacked.count,
                  points.count == trunkOwnerVertices.count,
                  points.count == corridorReferenceIDs.count
            else { return }

            var leftIndex = 0
            while leftIndex < points.count - 1 {
                guard explicitlyStacked[leftIndex] else {
                    leftIndex += 1
                    continue
                }

                var rightIndex = leftIndex + 1
                var gapDistance: CLLocationDistance = 0
                while rightIndex < points.count {
                    gapDistance += points[rightIndex - 1].distance(
                        to: points[rightIndex]
                    ) * metersPerMapPoint
                    if explicitlyStacked[rightIndex] { break }
                    rightIndex += 1
                }

                guard rightIndex < points.count else { break }
                defer { leftIndex = rightIndex }
                // A dropout the strand never leaves runs nearly straight along
                // the shared street, so its path length is close to the chord
                // between the stacked anchors. When the path is much longer
                // than that chord the strand swung away — a real detour around
                // a block or a one-way pair — and holding the lane through it
                // would draw the ribbon off the bus's street.
                let gapChordDistance = points[leftIndex].distance(
                    to: points[rightIndex]
                ) * metersPerMapPoint
                guard rightIndex > leftIndex + 1,
                      gapDistance <= maximumGapDistance,
                      gapChordDistance >= 0.75 * gapDistance,
                      let leftReferenceID = corridorReferenceIDs[leftIndex],
                      corridorReferenceIDs[rightIndex] == leftReferenceID
                else { continue }

                let leftOffset = offsets[leftIndex]
                let rightOffset = offsets[rightIndex]
                guard leftOffset * rightOffset >= 0,
                      abs(leftOffset - rightOffset) <= maximumLaneChange
                else { continue }

                let bridgesSameTrunkOwner = trunkOwnerVertices[leftIndex]
                    && trunkOwnerVertices[rightIndex]
                var distanceFromLeft: CLLocationDistance = 0
                for index in (leftIndex + 1)..<rightIndex {
                    distanceFromLeft += points[index - 1].distance(to: points[index])
                        * metersPerMapPoint
                    let progress = gapDistance > 0
                        ? distanceFromLeft / gapDistance : 0
                    offsets[index] = leftOffset
                        + (rightOffset - leftOffset) * progress
                    deltaX[index] = deltaX[leftIndex]
                        + (deltaX[rightIndex] - deltaX[leftIndex]) * progress
                    deltaY[index] = deltaY[leftIndex]
                        + (deltaY[rightIndex] - deltaY[leftIndex]) * progress
                    explicitlyStacked[index] = true
                    trunkOwnerVertices[index] = bridgesSameTrunkOwner
                    corridorReferenceIDs[index] = leftReferenceID
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

        private func applyTaperedLayout(
            factor: Double,
            sourceOffset: Double,
            sourceDeltaX: Double,
            sourceDeltaY: Double,
            destinationIndex: Int,
            offsets: inout [Double],
            deltaX: inout [Double],
            deltaY: inout [Double]
        ) {
            let candidateOffset = sourceOffset * factor
            if abs(candidateOffset) > abs(offsets[destinationIndex]) {
                offsets[destinationIndex] = candidateOffset
            }

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
                // A true shared road remains close and parallel across this entire
                // short sample. Requiring both endpoints eliminates incidental
                // matches at crossings and the inside edge of unrelated turns.
                // The spatial index narrows each test to the handful of
                // candidate segments actually near that point.
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
            // Public route identity—not live utility ranking—defines lateral order.
            // The sheet can reorder by usefulness without making map colors swap.
            let memberIDs = localSegmentByJourneyID.keys.sorted(
                by: corridorLaneComesBefore
            )
            // Both directions of one numbered route are one visual strand.
            func publicRouteKey(for memberID: Int) -> String {
                guard let geometry = corridorGeometryByJourneyID[memberID] else {
                    return "id:\(memberID)"
                }
                return "\(geometry.agencyName)|\(geometry.routeNumber)"
            }
            let dominanceCandidates: [Int]
            if let selectedID = parent.selectedJourneyID,
               memberIDs.contains(selectedID) {
                dominanceCandidates = [selectedID]
            } else if let highlightedIDs = parent.highlightedJourneyIDs {
                let highlightedMembers = memberIDs.filter {
                    highlightedIDs.contains($0)
                }
                dominanceCandidates = highlightedMembers.isEmpty
                    ? memberIDs : highlightedMembers
            } else {
                dominanceCandidates = memberIDs
            }
            guard let dominantID = dominanceCandidates.min(by: {
                firstID, secondID in
                let first = corridorGeometryByJourneyID[firstID]
                let second = corridorGeometryByJourneyID[secondID]
                let firstFrequency = first?.observedDepartureCount ?? 0
                let secondFrequency = second?.observedDepartureCount ?? 0
                if firstFrequency != secondFrequency {
                    return firstFrequency > secondFrequency
                }
                let firstOrder = first?.stackOrder ?? .max
                let secondOrder = second?.stackOrder ?? .max
                if firstOrder != secondOrder { return firstOrder < secondOrder }
                return firstID < secondID
            }) else { return nil }

            // Anchored lane: this segment's lane comes from the global
            // schedule, chosen once when the strand entered this corridor and
            // held while it continues. The previously re-derived stack slid
            // every continuing strand by half a lane at each join or leave —
            // the braiding defect this replaces.
            let strandKey = CorridorStrandKey(
                journeyID: journeyID,
                polylineIndex: polylineIndex
            )
            guard let sample = corridorLaneSchedule[strandKey]?[segmentIndex]
            else { return nil }
            // The schedule stores the offset against the sweeping spine's
            // travel direction; convert into this journey's frame using its
            // held direction chain — the same reversal hold the renderer's
            // offset pass applies — so hairpins keep the physical side.
            let heldDirection = heldUnitDirectionsByStrand[
                strandKey
            ]?[segmentIndex] ?? (x: segment.unitX, y: segment.unitY)
            let frameSign: Double = heldDirection.0 * sample.directionX
                + heldDirection.1 * sample.directionY >= 0 ? 1 : -1
            let localOffset = sample.offset * frameSign

            // Alignment anchors follow the schedule's sticky corridor
            // reference when it is locally matched; a reference not visible
            // from this sample keeps the observer's own vertices (no
            // adoption), matching the scheduler's spine choice downstream.
            let referenceID: Int
            let referenceSegment: MapRouteSegment?
            if let matchedReference = localSegmentByJourneyID[
                sample.referenceID
            ] {
                referenceID = sample.referenceID
                referenceSegment = matchedReference
            } else {
                referenceID = memberIDs.first ?? journeyID
                referenceSegment = localSegmentByJourneyID[referenceID]
            }

            let alignedStart: MKMapPoint
            let alignedEnd: MKMapPoint
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

            // Trunk ownership belongs to the dominant public route, not to one
            // journey of it: both directions project onto the same reference
            // centerline and would otherwise each leave the consolidated
            // city-scale trunk to the other.
            return CorridorSegmentLayout(
                offset: localOffset,
                enteringOffset: localOffset,
                alignedStart: alignedStart,
                alignedEnd: alignedEnd,
                referenceID: referenceID,
                isTrunkOwner: publicRouteKey(for: journeyID)
                    == publicRouteKey(for: dominantID)
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
            // Alignment corrects only small feed-to-feed centerline drift on
            // the same roadway — two publishers sampling the same street a few
            // meters apart. Santa Barbara's shared transit streets are largely
            // divided carriageways 12–20 m apart (Hollister, El Colegio, Calle
            // Real), and freeway ramps braid just as close to their frontage
            // roads. Adopting a "reference" centerline across that gap is what
            // drew the 9 loop, 12x, and 24x onto the wrong side of the street
            // as tapered sideways detours. Partners that far apart still share
            // the corridor and its lanes; they just keep their own
            // authoritative centerline instead of snapping to their neighbor's.
            return point.distance(to: projection) * metersPerMapPoint <= 6
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
                renderer.lineWidth = 14
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
                let lanePoints = stableRouteOffsetPoints(
                    laneSamples.points,
                    offsets: laneSamples.offsets
                )
                guard lanePoints.count >= 2 else { continue }

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

                for index in 0..<(lanePoints.count - 1) {
                    let isShared = laneSamples.sharedVertices[index]
                        && laneSamples.sharedVertices[index + 1]
                    let hasIsolatedCoverage =
                        laneSamples.isolatedVertices[index]
                        && laneSamples.isolatedVertices[index + 1]
                    // Mirror the renderer: any segment still carrying isolated
                    // geometry is drawn at full strength at every zoom, so it
                    // is always tappable.
                    if !isShared || hasIsolatedCoverage {
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
                    if ownsTrunk, trunkProgress > 0.05 {
                        considerSegment(
                            from: laneSamples.points[index],
                            to: laneSamples.points[index + 1]
                        )
                    }
                }
            }

            if let best, best.distance <= 14,
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
        let isolatedSegments = (0..<segmentCount).map { index in
            !sharedSegments[index]
                || (laneSamples.isolatedVertices[index]
                    && laneSamples.isolatedVertices[index + 1])
        }
        let ownedTrunkSegments = (0..<segmentCount).map { index in
            sharedSegments[index]
                && hasOwnerState
                && laneSamples.trunkOwnerVertices[index]
                && laneSamples.trunkOwnerVertices[index + 1]
        }
        let tolerance = 0.7 / zoomScale
        let isolatedPath = routeSegmentPath(
            points: offsetPoints,
            includedSegments: isolatedSegments,
            tolerance: tolerance
        )
        let detailPath = routeSegmentPath(
            points: offsetPoints,
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

        let lineWidth = RouteMapStyle.lineWidth(
            baseWidth: routeOverlay.lineWidth,
            zoomScale: zoomScale
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
        // service goes even while only shared geometry is consolidated.
        if isolatedPath.hasContent {
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
    var previousDirection: CGPoint?

    for index in 0..<(points.count - 1) {
        let deltaX = points[index + 1].x - points[index].x
        let deltaY = points[index + 1].y - points[index].y
        let length = max(0.0001, hypot(deltaX, deltaY))
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
        previousDirection = direction
    }

    return points.indices.map { index in
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
        if sumLength > 0.001 {
            normal = CGPoint(x: sumX / sumLength, y: sumY / sumLength)
            let denominator = normal.x * nextNormal.x + normal.y * nextNormal.y
            if denominator > 0.25 {
                scale = localOffset / denominator
            }
        }
        let maximumMiter = abs(localOffset) * 1.75
        if localOffset >= 0 {
            scale = max(0, min(maximumMiter, scale))
        } else {
            scale = min(0, max(-maximumMiter, scale))
        }
        return CGPoint(
            x: points[index].x + normal.x * scale,
            y: points[index].y + normal.y * scale
        )
    }
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
        let width: CGFloat = 158
        let height: CGFloat = 42
        frame = CGRect(x: 0, y: 0, width: width, height: height)
        centerOffset = annotation.viewCenterOffset
        alpha = annotation.isDimmed ? 0.24 : 1
        displayPriority = annotation.isSelected
            ? .required
            : (annotation.rank < 3 ? .defaultHigh : .defaultLow)

        let routeColor = UIColor(annotation.journey.route.color)
        let card = UIView(frame: CGRect(x: 4, y: 4, width: 150, height: 34))
        card.backgroundColor = UIColor(
            red: 0.965, green: 0.945, blue: 0.89, alpha: 0.97
        )
        card.layer.cornerRadius = 9
        card.layer.borderWidth = 1
        card.layer.borderColor = routeColor.cgColor
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.12
        card.layer.shadowRadius = 3
        card.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(card)

        let colorBar = UIView(frame: CGRect(x: 0, y: 0, width: 5, height: 34))
        colorBar.backgroundColor = routeColor
        colorBar.layer.cornerRadius = 2.5
        card.addSubview(colorBar)

        let routePrefix = annotation.journey.route.routeNumber.map { "\($0) · " } ?? ""
        let destinationLabel = UILabel(frame: CGRect(x: 10, y: 3, width: 134, height: 15))
        destinationLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        destinationLabel.textColor = UIColor(
            red: 0.14, green: 0.19, blue: 0.18, alpha: 1
        )
        // The tag's one job is naming the place. The compact landmark form
        // ("Camino Real Marketplace") survives 134 points; the full stop name
        // usually truncates into "Hollister & Camin…", which names nothing.
        destinationLabel.text = routePrefix
            + annotation.journey.compactDestinationName
        destinationLabel.lineBreakMode = .byTruncatingTail
        card.addSubview(destinationLabel)

        let timeLabel = UILabel(frame: CGRect(x: 10, y: 18, width: 134, height: 13))
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        timeLabel.textColor = routeColor
        let arrivalTime = annotation.journey.arrivalDate.formatted(
            date: .omitted,
            time: .shortened
        )
        timeLabel.text = "Arrive \(arrivalTime) · \(annotation.journey.totalMinutes) min"
        card.addSubview(timeLabel)

        let pin = UIView(
            frame: CGRect(
                x: annotation.pinCenter.x - 3.5,
                y: annotation.pinCenter.y - 3.5,
                width: 7,
                height: 7
            )
        )
        pin.backgroundColor = routeColor
        pin.layer.cornerRadius = 3.5
        pin.layer.borderWidth = 1.5
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
        frame = CGRect(x: 0, y: 0, width: 11, height: 11)
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

        let markerCircle = rect.insetBy(dx: 2.25, dy: 2.25)
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
    private let horizontalInset: CGFloat = 6
    private let verticalInset: CGFloat = 4

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
                        .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .black),
                        .foregroundColor: item.1,
                    ]
                )
            )
        }
        routeLabel.attributedText = text

        let labelSize = routeLabel.sizeThatFits(
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: 20)
        )
        bounds.size = CGSize(
            width: max(25, ceil(labelSize.width) + horizontalInset * 2),
            height: 23
        )
        setNeedsLayout()

        alpha = annotation.isDimmed ? 0.22 : 1
        transform = annotation.isSelected
            ? CGAffineTransform(scaleX: 1.1, y: 1.1)
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
        frame = CGRect(x: 0, y: 0, width: 170, height: 28)
        centerOffset = CGPoint(x: 80, y: 0)

        let dot = UIView(frame: CGRect(x: 0, y: 8.5, width: 11, height: 11))
        dot.backgroundColor = UIColor(annotation.journey.route.color)
        dot.layer.cornerRadius = 5.5
        dot.layer.borderColor = UIColor.white.cgColor
        dot.layer.borderWidth = 2
        addSubview(dot)

        let label = UILabel(frame: CGRect(x: 15, y: 2, width: 151, height: 24))
        label.backgroundColor = UIColor(red: 0.965, green: 0.945, blue: 0.89, alpha: 0.92)
        label.layer.cornerRadius = 7
        label.layer.masksToBounds = true
        label.font = .systemFont(ofSize: 9.5, weight: .medium)
        label.textColor = UIColor(red: 0.14, green: 0.19, blue: 0.18, alpha: 1)
        label.text = "  +\(annotation.stop.minutesFromBoarding)  \(annotation.stop.name)"
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        accessibilityLabel = "\(annotation.stop.name), \(annotation.stop.minutesFromBoarding) minutes after boarding"
    }
}
