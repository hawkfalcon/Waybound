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

struct WayboundMapView: UIViewRepresentable {
    let routes: [TransitRoute]
    let journeys: [RouteJourney]
    let stops: [TransitStop]
    let selectedJourneyID: Int?
    let selectedStopID: Int?
    let highlightedRouteIDs: Set<Int>?
    let showsMapLadder: Bool
    let viewportBottomInset: CGFloat
    let cameraRequest: WayboundCameraRequest
    let onSelectJourney: (Int) -> Void
    let onSelectStop: (Int, Set<Int>) -> Void

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
        mapView.preferredConfiguration = MKStandardMapConfiguration(
            elevationStyle: .flat,
            emphasisStyle: .muted
        )

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
        private var corridorSegmentsByRouteID: [Int: [MapRouteSegment]] = [:]
        private var viewportRefreshWorkItem: DispatchWorkItem?

        init(parent: WayboundMapView) {
            self.parent = parent
        }

        func rebuildMapContent(on mapView: MKMapView) {
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

            guard let routeViewport = routeViewportMapRect(in: mapView),
                  let tagViewport = destinationTagViewportMapRect(in: mapView)
            else { return }
            let selectedID = parent.selectedJourneyID
            let highlightedRouteIDs = parent.highlightedRouteIDs
            corridorSegmentsByRouteID = Dictionary(
                uniqueKeysWithValues: parent.journeys.map { journey in
                    (
                        journey.id,
                        routeSegments(for: journey.flagshipPolylines)
                    )
                }
            )

            for journey in parent.journeys {
                let isSelected = selectedID == journey.id
                let isHighlighted = highlightedRouteIDs?.contains(journey.id) ?? true
                let opacity = isHighlighted ? 0.92 : 0.12
                addOverlays(
                    for: clippedPolylines(
                        journey.flagshipPolylines,
                        to: routeViewport
                    ),
                    routeID: journey.id,
                    color: UIColor(journey.route.color),
                    opacity: opacity,
                    lineWidth: isSelected ? 4.5 : (isHighlighted ? 3 : 2.5),
                    laneOffset: journey.laneOffsetPoints,
                    dashed: false,
                    to: mapView
                )

                if isSelected && parent.showsMapLadder {
                    addOverlays(
                        for: clippedPolylines(
                            journey.continuationPolylines,
                            to: routeViewport
                        ),
                        routeID: journey.id,
                        color: UIColor(journey.route.color),
                        opacity: 0.58,
                        lineWidth: 3,
                        laneOffset: journey.laneOffsetPoints,
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
                        isDimmed: highlightedRouteIDs.map {
                            !$0.contains(journey.id)
                        } ?? false,
                        viewCenterOffset: layout.centerOffset,
                        pinCenter: layout.pinCenter
                    )
                )
            }
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

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            viewportRefreshWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self, weak mapView] in
                guard let self, let mapView else { return }
                self.refreshViewportContent(on: mapView)
            }
            viewportRefreshWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: workItem)
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
                let sortedJourneys = group.map(\.journey).sorted {
                    $0.route.fullDisplayName.localizedStandardCompare(
                        $1.route.fullDisplayName
                    ) == .orderedAscending
                }
                var seenRouteIDs: Set<Int> = []
                let uniqueJourneys = sortedJourneys.filter {
                    seenRouteIDs.insert($0.id).inserted
                }
                let routeIDs = Set(uniqueJourneys.map(\.id))
                let isDimmed = parent.highlightedRouteIDs.map {
                    routeIDs.isDisjoint(with: $0)
                } ?? false
                return RouteStopMapAnnotation(
                    coordinate: coordinate,
                    name: first.stop.name,
                    routeIDs: routeIDs,
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
                let routeIDs = Set(sortedJourneys.map(\.id))
                let colors = sortedJourneys.map { UIColor($0.route.color) }
                let isDimmed = parent.highlightedRouteIDs.map {
                    routeIDs.isDisjoint(with: $0)
                } ?? false
                return StopClusterMapAnnotation(
                    stop: representative.boardingStop,
                    sourceStopIDs: Set(group.map { $0.boardingStop.id }),
                    routeIDs: routeIDs,
                    routeNumbers: sortedJourneys.map { $0.route.shortName },
                    colors: colors,
                    isDimmed: isDimmed,
                    isSelected: group.contains {
                        $0.boardingStop.id == parent.selectedStopID
                    }
                )
            }
        }

        private func addOverlays(
            for polylines: [[CLLocationCoordinate2D]],
            routeID: Int,
            color: UIColor,
            opacity: Double,
            lineWidth: Double,
            laneOffset: Double,
            dashed: Bool,
            to mapView: MKMapView
        ) {
            for coordinates in polylines where coordinates.count >= 2 {
                let offsetFactors = sharedCorridorOffsetFactors(
                    for: coordinates,
                    excluding: routeID
                )
                let overlay = RouteLaneOverlay(
                    coordinates: coordinates,
                    routeID: routeID,
                    color: color,
                    opacity: opacity,
                    lineWidth: lineWidth,
                    laneOffsetPoints: laneOffset,
                    laneOffsetFactors: offsetFactors,
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

        /// A route stays on its authoritative GTFS centerline by default. Its
        /// rank-based lane offset fades in only where another displayed route
        /// follows the same, parallel street corridor. This avoids shifting an
        /// isolated route (such as route 2 on Anapamu) off its actual street.
        private func sharedCorridorOffsetFactors(
            for coordinates: [CLLocationCoordinate2D],
            excluding routeID: Int
        ) -> [Double] {
            guard coordinates.count >= 2 else {
                return Array(repeating: 0, count: coordinates.count)
            }

            let otherSegments = corridorSegmentsByRouteID.flatMap {
                entry -> [MapRouteSegment] in
                entry.key == routeID ? [] : entry.value
            }
            guard !otherSegments.isEmpty else {
                return Array(repeating: 0, count: coordinates.count)
            }

            let points = coordinates.map { MKMapPoint($0) }
            var sharedSegments = Array(
                repeating: false,
                count: points.count - 1
            )
            for index in sharedSegments.indices {
                guard let segment = MapRouteSegment(
                    start: points[index],
                    end: points[index + 1]
                ) else { continue }
                let midpoint = MKMapPoint(
                    x: (segment.start.x + segment.end.x) / 2,
                    y: (segment.start.y + segment.end.y) / 2
                )

                // Requiring proximity at the midpoint and one endpoint rejects
                // incidental line crossings while tolerating different GTFS
                // sampling intervals along a truly shared street.
                let midpointIsShared = hasParallelCorridor(
                    near: midpoint,
                    direction: segment,
                    among: otherSegments
                )
                let endpointIsShared = hasParallelCorridor(
                    near: segment.start,
                    direction: segment,
                    among: otherSegments
                ) || hasParallelCorridor(
                    near: segment.end,
                    direction: segment,
                    among: otherSegments
                )
                sharedSegments[index] = midpointIsShared && endpointIsShared
            }

            var factors = Array(repeating: 0.0, count: points.count)
            for index in sharedSegments.indices where sharedSegments[index] {
                factors[index] = 1
                factors[index + 1] = 1
            }

            // A short geographic taper prevents a visible sideways jog where
            // parallel lanes merge back onto the street centerline.
            let taperDistance: CLLocationDistance = 42
            if factors.count > 1 {
                for index in 1..<factors.count {
                    let distance = points[index - 1].distance(to: points[index])
                    factors[index] = max(
                        factors[index],
                        factors[index - 1] - distance / taperDistance
                    )
                }
                for index in stride(from: factors.count - 2, through: 0, by: -1) {
                    let distance = points[index].distance(to: points[index + 1])
                    factors[index] = max(
                        factors[index],
                        factors[index + 1] - distance / taperDistance
                    )
                }
            }
            return factors.map { max(0, min(1, $0)) }
        }

        private func hasParallelCorridor(
            near point: MKMapPoint,
            direction: MapRouteSegment,
            among candidates: [MapRouteSegment]
        ) -> Bool {
            let maximumSeparation: CLLocationDistance = 20
            let minimumParallelDot = 0.93
            return candidates.contains { candidate in
                abs(direction.unitX * candidate.unitX
                    + direction.unitY * candidate.unitY) >= minimumParallelDot
                    && mapDistance(
                        from: point,
                        to: candidate
                    ) <= maximumSeparation
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
                parent.onSelectStop(cluster.stop.id, cluster.routeIDs)
                mapView.deselectAnnotation(cluster, animated: false)
            }
        }

        @objc func didTapMap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let mapView = recognizer.view as? MKMapView
            else { return }
            let tapPoint = recognizer.location(in: mapView)
            var best: (routeID: Int, distance: CGFloat)?

            for overlay in routeOverlays {
                let rawPoints = overlay.coordinates.map {
                    mapView.convert($0, toPointTo: mapView)
                }
                let basePoints = simplifiedRoutePoints(
                    rawPoints,
                    tolerance: 0.7
                )
                let factors = simplifiedRouteValues(
                    for: basePoints,
                    originalPoints: rawPoints,
                    originalValues: overlay.laneOffsetFactors.map { CGFloat($0) }
                )
                let lanePoints = stableRouteOffsetPoints(
                    basePoints,
                    offset: CGFloat(overlay.laneOffsetPoints),
                    factors: factors
                )
                guard lanePoints.count >= 2 else { continue }

                for index in 0..<(lanePoints.count - 1) {
                    let distance = distanceFromPoint(
                        tapPoint,
                        toSegmentFrom: lanePoints[index],
                        to: lanePoints[index + 1]
                    )
                    if best.map({ distance < $0.distance }) ?? true {
                        best = (overlay.routeID, distance)
                    }
                }
            }

            if let best, best.distance <= 14,
               parent.journeys.contains(where: { $0.id == best.routeID }) {
                parent.onSelectJourney(best.routeID)
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

private final class RouteLaneOverlay: NSObject, MKOverlay {
    let coordinates: [CLLocationCoordinate2D]
    let routeID: Int
    let color: UIColor
    let opacity: Double
    let lineWidth: Double
    let laneOffsetPoints: Double
    let laneOffsetFactors: [Double]
    let dashed: Bool
    private let polyline: MKPolyline

    var coordinate: CLLocationCoordinate2D { polyline.coordinate }
    var boundingMapRect: MKMapRect {
        polyline.boundingMapRect.insetBy(dx: -1_000_000, dy: -1_000_000)
    }

    init(
        coordinates: [CLLocationCoordinate2D],
        routeID: Int,
        color: UIColor,
        opacity: Double,
        lineWidth: Double,
        laneOffsetPoints: Double,
        laneOffsetFactors: [Double],
        dashed: Bool
    ) {
        self.coordinates = coordinates
        self.routeID = routeID
        self.color = color
        self.opacity = opacity
        self.lineWidth = lineWidth
        self.laneOffsetPoints = laneOffsetPoints
        self.laneOffsetFactors = laneOffsetFactors
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
        let basePoints = simplifiedRoutePoints(
            rawPoints,
            tolerance: 0.7 / zoomScale
        )
        guard basePoints.count >= 2 else { return }
        let offset = CGFloat(routeOverlay.laneOffsetPoints) / zoomScale
        let factors = simplifiedRouteValues(
            for: basePoints,
            originalPoints: rawPoints,
            originalValues: routeOverlay.laneOffsetFactors.map { CGFloat($0) }
        )
        let offsetPoints = stableRouteOffsetPoints(
            basePoints,
            offset: offset,
            factors: factors
        )

        let path = CGMutablePath()
        path.move(to: offsetPoints[0])
        for point in offsetPoints.dropFirst() {
            path.addLine(to: point)
        }

        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if routeOverlay.dashed {
            context.setLineDash(
                phase: 0,
                lengths: [8 / zoomScale, 7 / zoomScale]
            )
        }

        // A narrow cream casing keeps adjacent route colors discrete even when
        // several trips share exactly the same source shape.
        context.addPath(path)
        context.setStrokeColor(
            UIColor(red: 0.965, green: 0.945, blue: 0.89, alpha: routeOverlay.opacity)
                .cgColor
        )
        context.setLineWidth(
            CGFloat(routeOverlay.lineWidth + 2) / zoomScale
        )
        context.strokePath()

        context.addPath(path)
        context.setStrokeColor(
            routeOverlay.color.withAlphaComponent(routeOverlay.opacity).cgColor
        )
        context.setLineWidth(CGFloat(routeOverlay.lineWidth) / zoomScale)
        context.strokePath()
        context.restoreGState()
    }
}

/// A small screen-space simplification removes duplicate/backtracking shape
/// samples before lane offsets can magnify them into visible crossbars.
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

/// Ramer–Douglas–Peucker retains source points, so carry each retained point's
/// corridor factor through the same ordered sequence. The nearest fallback is
/// only for sub-pixel floating-point differences in MapKit conversion.
private func simplifiedRouteValues(
    for simplifiedPoints: [CGPoint],
    originalPoints: [CGPoint],
    originalValues: [CGFloat]
) -> [CGFloat] {
    guard originalPoints.count == originalValues.count,
          !originalPoints.isEmpty
    else { return Array(repeating: 0, count: simplifiedPoints.count) }

    var cursor = 0
    return simplifiedPoints.map { point in
        if cursor < originalPoints.count,
           let match = originalPoints[cursor...].firstIndex(of: point) {
            cursor = match + 1
            return originalValues[match]
        }
        let nearestIndex = originalPoints.indices.min { first, second in
            hypot(
                point.x - originalPoints[first].x,
                point.y - originalPoints[first].y
            ) < hypot(
                point.x - originalPoints[second].x,
                point.y - originalPoints[second].y
            )
        } ?? 0
        return originalValues[nearestIndex]
    }
}

private func stableRouteOffsetPoints(
    _ points: [CGPoint],
    offset: CGFloat,
    factors: [CGFloat]? = nil
) -> [CGPoint] {
    guard points.count >= 2, abs(offset) > 0.0001 else { return points }
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

        let factor = factors.flatMap { values in
            values.indices.contains(index) ? values[index] : nil
        } ?? 1
        let localOffset = offset * max(0, min(1, factor))
        var normal = nextNormal
        var scale = localOffset
        if sumLength > 0.001 {
            normal = CGPoint(x: sumX / sumLength, y: sumY / sumLength)
            let denominator = normal.x * nextNormal.x + normal.y * nextNormal.y
            if abs(denominator) > 0.25 {
                scale = localOffset / denominator
            }
        }
        let maximumMiter = abs(localOffset) * 1.75
        scale = max(-maximumMiter, min(maximumMiter, scale))
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
        routeNumbers: [String],
        colors: [UIColor],
        isDimmed: Bool,
        isSelected: Bool
    ) {
        self.stop = stop
        self.sourceStopIDs = sourceStopIDs
        self.routeIDs = routeIDs
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
        destinationLabel.text = routePrefix + annotation.journey.destinationName
        destinationLabel.lineBreakMode = .byTruncatingTail
        card.addSubview(destinationLabel)

        let timeLabel = UILabel(frame: CGRect(x: 10, y: 18, width: 134, height: 13))
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        timeLabel.textColor = routeColor
        timeLabel.text = "\(annotation.journey.totalMinutes) min total"
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

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 9, height: 9)
        centerOffset = .zero
        collisionMode = .none
        displayPriority = .required
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with annotation: RouteStopMapAnnotation) {
        colors = annotation.colors
        alpha = annotation.isDimmed ? 0.18 : 0.92
        setNeedsDisplay()
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
        canShowCallout = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with annotation: LadderStopMapAnnotation) {
        subviews.forEach { $0.removeFromSuperview() }
        frame = CGRect(x: 0, y: 0, width: 170, height: 28)
        centerOffset = CGPoint(x: 76, y: -14)

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
