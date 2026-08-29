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
        let progress = max(0, min(1, (zoomLevel - 13.75) / 3.25))
        return progress * 2.2
    }

    static func lineWidth(
        baseWidth: Double,
        zoomScale: MKZoomScale
    ) -> Double {
        baseWidth + zoomLineExpansion(for: zoomScale)
    }

    static func laneSpacing(for zoomScale: MKZoomScale) -> Double {
        standardLineWidth + zoomLineExpansion(for: zoomScale) + separatorWidth
    }

    static func laneOffsetScale(for zoomScale: MKZoomScale) -> Double {
        laneSpacing(for: zoomScale) / laneSpacingPoints
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
        /// Full-polyline lane layouts, computed once per corridor-content change
        /// and only clipped per viewport tick. Recomputing these on every pan
        /// frame was O(routes² × segments²) and drove the memory spikes that got
        /// the app jettisoned.
        private var laneLayoutsByJourneyID: [Int: [CorridorLaneLayout]] = [:]

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
            corridorGeometryByJourneyID = Dictionary(
                uniqueKeysWithValues: parent.journeys.enumerated().map {
                    index, journey in
                    (
                        journey.id,
                        CorridorJourneyGeometry(
                            stackOrder: index,
                            routeNumber: journey.route.routeNumber
                                ?? journey.route.shortName,
                            agencyName: journey.route.agencyName,
                            directionID: journey.directionID,
                            observedDepartureCount: journey.observedDepartureCount,
                            segmentIndex: CorridorSegmentIndex(
                                segments: routeSegments(
                                    for: journey.flagshipPolylines.map {
                                        densifiedRouteCoordinates($0)
                                    }
                                )
                            )
                        )
                    )
                }
            )

            laneLayoutsByJourneyID = [:]
            for journey in parent.journeys {
                // Regular samples give branch merges enough geometry to fan
                // over distance. Sparse GTFS vertices otherwise force an entire
                // ribbon to change lane at one sharp point.
                laneLayoutsByJourneyID[journey.id] = journey.flagshipPolylines
                    .filter { $0.count >= 2 }
                    .map {
                        sharedCorridorLaneLayout(
                            for: densifiedRouteCoordinates($0),
                            journeyID: journey.id
                        )
                    }
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

        private func updateRouteStopVisibility(on mapView: MKMapView) {
            for annotation in mapView.annotations {
                guard let routeStop = annotation as? RouteStopMapAnnotation,
                      let view = mapView.view(for: routeStop)
                        as? RouteStopAnnotationView
                else { continue }
                view.setZoomVisibility(
                    routeStopVisibility(for: routeStop, on: mapView)
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

        private func routeSegments(
            for polylines: [[CLLocationCoordinate2D]]
        ) -> [MapRouteSegment] {
            polylines.flatMap { polyline -> [MapRouteSegment] in
                guard polyline.count >= 2 else { return [] }
                return (0..<(polyline.count - 1)).compactMap { index in
                    MapRouteSegment(
                        start: MKMapPoint(polyline[index]),
                        end: MKMapPoint(polyline[index + 1])
                    )
                }
            }
        }

        private func densifiedRouteCoordinates(
            _ coordinates: [CLLocationCoordinate2D]
        ) -> [CLLocationCoordinate2D] {
            let maximumSegmentLength: CLLocationDistance = 18
            guard coordinates.count >= 2 else { return coordinates }
            var result = [coordinates[0]]

            for index in 0..<(coordinates.count - 1) {
                let start = MKMapPoint(coordinates[index])
                let end = MKMapPoint(coordinates[index + 1])
                let distance = start.distance(to: end)
                let subdivisionCount = max(
                    1,
                    Int(ceil(distance / maximumSegmentLength))
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
        private func sharedCorridorLaneLayout(
            for coordinates: [CLLocationCoordinate2D],
            journeyID: Int
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
                        journeyID: journeyID
                    )
                )
            }

            // A parallel shape seen for only a few meters is normally an
            // intersection, a terminal bay, or a near-parallel turn—not a shared
            // road. Refusing those tiny runs removes one-vertex side-steps without
            // deleting any authoritative route geometry.
            removeShortCorridorRuns(
                points: points,
                layouts: &segmentLayouts
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
                offsets: &offsets
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
                deltaY: &alignmentDeltaY
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
                        )
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
                        )
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
            layouts: inout [CorridorSegmentLayout?]
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
            offsets: inout [Double]
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
            deltaY: inout [Double]
        ) {
            // Matches the corridor-continuation distance used when stabilizing
            // run offsets: a dropout short enough to hold its lane through is
            // also short enough to bridge, so the ribbon stays straight instead
            // of pinching to the centerline and fanning back out. The gates
            // below (same reference shape, same side, at most one lane of
            // change) still prevent bridging across a genuine turn.
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
                    )
                    if explicitlyStacked[rightIndex] { break }
                    rightIndex += 1
                }

                guard rightIndex < points.count else { break }
                defer { leftIndex = rightIndex }
                guard rightIndex > leftIndex + 1,
                      gapDistance <= maximumGapDistance,
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
            journeyID: Int
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
                    among: geometry.segmentIndex.segments(near: midpoint)
                ),
                      hasParallelCorridor(
                        near: segment.start,
                        direction: segment,
                        among: geometry.segmentIndex.segments(
                            near: segment.start
                        )
                      ),
                      hasParallelCorridor(
                        near: segment.end,
                        direction: segment,
                        among: geometry.segmentIndex.segments(near: segment.end)
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
            var claimedRouteKeys: Set<String> = []
            let laneMemberIDs = memberIDs.filter {
                claimedRouteKeys.insert(publicRouteKey(for: $0)).inserted
            }
            let laneJourneyID = laneMemberIDs.first {
                publicRouteKey(for: $0) == publicRouteKey(for: journeyID)
            } ?? journeyID
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
            guard let referenceID = memberIDs.first,
                  let referenceSegment = localSegmentByJourneyID[referenceID]
            else { return nil }

            // Partition every local corridor by physical travel direction. When
            // both directions are present they start in adjacent fixed-width lanes
            // on opposite sides of the GTFS centerline; additional same-direction
            // routes stack outward rather than crossing through the other group.
            let alignedIDs = laneMemberIDs.filter { memberID in
                guard let member = localSegmentByJourneyID[memberID] else {
                    return false
                }
                return member.unitX * referenceSegment.unitX
                    + member.unitY * referenceSegment.unitY >= 0
            }
            let reverseIDs = laneMemberIDs.filter { !alignedIDs.contains($0) }

            let laneSpacing = RouteMapStyle.laneSpacingPoints
            let physicalOffset: Double
            let enteringPhysicalOffset: Double
            if !reverseIDs.isEmpty {
                if let laneIndex = alignedIDs.firstIndex(of: journeyID) {
                    physicalOffset = laneSpacing / 2
                        + Double(laneIndex) * laneSpacing
                    enteringPhysicalOffset = laneSpacing / 2
                        + Double(alignedIDs.count - 1) * laneSpacing
                } else if let laneIndex = reverseIDs.firstIndex(of: journeyID) {
                    physicalOffset = -laneSpacing / 2
                        - Double(laneIndex) * laneSpacing
                    enteringPhysicalOffset = -laneSpacing / 2
                        - Double(reverseIDs.count - 1) * laneSpacing
                } else {
                    return nil
                }
            } else {
                guard let laneIndex = alignedIDs.firstIndex(of: journeyID) else {
                    return nil
                }
                physicalOffset = (
                    Double(laneIndex) - Double(alignedIDs.count - 1) / 2
                ) * laneSpacing
                // A new strand enters from the nearest outside edge rather than
                // inserting itself between established colors. This intentionally
                // lets topology override natural-number order at that one merge.
                let joinsLowerEdge = laneIndex * 2 < alignedIDs.count - 1
                let edgeSign: Double = joinsLowerEdge ? -1 : 1
                let edgeMagnitude = Double(alignedIDs.count) / 2 * laneSpacing
                enteringPhysicalOffset = edgeSign * edgeMagnitude
            }

            let alignedStart: MKMapPoint
            let alignedEnd: MKMapPoint
            if referenceID == journeyID {
                alignedStart = segment.start
                alignedEnd = segment.end
            } else {
                // Project both endpoints onto the same locally matched segment.
                // Searching again per endpoint can select two different parallel
                // pieces of a terminal loop and manufacture a sideways jog.
                alignedStart = corridorProjection(
                    of: segment.start,
                    onto: referenceSegment
                )
                alignedEnd = corridorProjection(
                    of: segment.end,
                    onto: referenceSegment
                )
            }

            // Screen-space offset normals reverse with polyline direction. Convert
            // the canonical physical side back into this journey's local scalar.
            let directionDot = segment.unitX * referenceSegment.unitX
                + segment.unitY * referenceSegment.unitY
            let directionSign: Double = directionDot >= 0 ? 1 : -1
            return CorridorSegmentLayout(
                offset: physicalOffset * directionSign,
                enteringOffset: enteringPhysicalOffset * directionSign,
                alignedStart: alignedStart,
                alignedEnd: alignedEnd,
                referenceID: referenceID,
                isTrunkOwner: journeyID == dominantID
            )
        }

        /// Remove only perpendicular drift from a member shape. Both endpoints of
        /// one short sample use the same reference segment, preserving longitudinal
        /// progress and preventing a dense terminal loop from becoming a shortcut.
        private func corridorProjection(
            of point: MKMapPoint,
            onto reference: MapRouteSegment
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
            // Alignment only corrects small feed-to-feed centerline drift. Larger
            // moves are a different street, bay, or branch and stay authoritative.
            return point.distance(to: projection) <= 20 ? projection : point
        }

        private func hasParallelCorridor(
            near point: MKMapPoint,
            direction: MapRouteSegment,
            among candidates: [MapRouteSegment]
        ) -> Bool {
            parallelCorridorSegment(
                near: point,
                direction: direction,
                among: candidates
            ) != nil
        }

        private func parallelCorridorSegment(
            near point: MKMapPoint,
            direction: MapRouteSegment,
            among candidates: [MapRouteSegment]
        ) -> MapRouteSegment? {
            // Two feeds can publish centerlines on different parts of the same
            // street. Twenty meters still covers that drift without treating a
            // nearby terminal bay or parallel downtown street as one corridor.
            let maximumSeparation: CLLocationDistance = 20
            let minimumParallelDot = 0.93
            return candidates
                .filter { candidate in
                    abs(direction.unitX * candidate.unitX
                        + direction.unitY * candidate.unitY) >= minimumParallelDot
                        && mapDistance(
                            from: point,
                            to: candidate
                        ) <= maximumSeparation
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
            private var segmentIndicesByCell: [UInt64: [Int32]] = [:]

            init(segments: [MapRouteSegment]) {
                self.segments = segments
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
                    routeStopVisibility(for: routeStop, on: mapView)
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
        frame = CGRect(x: 0, y: 0, width: 9, height: 9)
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

    func setZoomVisibility(_ progress: Double) {
        let clampedProgress = max(0, min(1, progress))
        alpha = configuredAlpha * CGFloat(clampedProgress)
        isHidden = clampedProgress < 0.01
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let outerCircle = rect.insetBy(dx: 0.5, dy: 0.5)
        context.setFillColor(
            UIColor(red: 0.965, green: 0.945, blue: 0.89, alpha: 1).cgColor
        )
        context.fillEllipse(in: outerCircle)

        let markerCircle = rect.insetBy(dx: 2, dy: 2)
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

        let dot = UIView(frame: CGRect(x: 0, y: 9, width: 10, height: 10))
        dot.backgroundColor = UIColor(annotation.journey.route.color)
        dot.layer.cornerRadius = 5
        dot.layer.borderColor = UIColor.white.cgColor
        dot.layer.borderWidth = 2
        addSubview(dot)

        let label = UILabel(frame: CGRect(x: 14, y: 2, width: 152, height: 24))
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
