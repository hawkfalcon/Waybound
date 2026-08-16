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

        init(parent: WayboundMapView) {
            self.parent = parent
        }

        func rebuildMapContent(on mapView: MKMapView) {
            mapView.removeOverlays(mapView.overlays)
            mapView.removeAnnotations(
                mapView.annotations.filter { !($0 is MKUserLocation) }
            )
            routeOverlays = []

            let selectedID = parent.selectedJourneyID
            let highlightedRouteIDs = parent.highlightedRouteIDs

            // The render model contains only the capped, boardable journeys.
            // Never fall back to drawing every route associated with nearby stops.
            for journey in parent.journeys {
                let isSelected = selectedID == journey.id
                let isHighlighted = highlightedRouteIDs?.contains(journey.id) ?? true
                let opacity = isHighlighted ? 0.92 : 0.12
                addOverlays(
                    for: journey.flagshipPolylines,
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
                        for: journey.continuationPolylines,
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

            // Mark only the stops the retained journeys actually board at. Nearby
            // source records within one map-marker footprint become one badge.
            mapView.addAnnotations(boardingStopAnnotations())

            for (rank, journey) in parent.journeys.enumerated()
            where selectedID == nil || journey.id == selectedID {
                mapView.addAnnotation(
                    DestinationMapAnnotation(
                        journey: journey,
                        rank: rank,
                        isSelected: journey.id == selectedID,
                        isDimmed: highlightedRouteIDs.map {
                            !$0.contains(journey.id)
                        } ?? false
                    )
                )
            }

            if parent.showsMapLadder,
               let selectedID,
               let journey = parent.journeys.first(where: { $0.id == selectedID }) {
                for stop in journey.stops where !stop.isBoarding && !stop.isFlagship {
                    mapView.addAnnotation(
                        LadderStopMapAnnotation(stop: stop, journey: journey)
                    )
                }
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
                let overlay = RouteLaneOverlay(
                    coordinates: coordinates,
                    routeID: routeID,
                    color: color,
                    opacity: opacity,
                    lineWidth: lineWidth,
                    laneOffsetPoints: laneOffset,
                    dashed: dashed
                )
                routeOverlays.append(overlay)
                mapView.addOverlay(overlay, level: .aboveRoads)
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
                let coordinates = overlay.coordinates
                guard coordinates.count >= 2 else { continue }
                for index in 0..<(coordinates.count - 1) {
                    var start = mapView.convert(
                        coordinates[index],
                        toPointTo: mapView
                    )
                    var end = mapView.convert(
                        coordinates[index + 1],
                        toPointTo: mapView
                    )
                    let deltaX = end.x - start.x
                    let deltaY = end.y - start.y
                    let length = hypot(deltaX, deltaY)
                    if length > 0 {
                        let laneOffset = CGFloat(overlay.laneOffsetPoints)
                        let offsetX = -deltaY / length * laneOffset
                        let offsetY = deltaX / length * laneOffset
                        start.x += offsetX
                        start.y += offsetY
                        end.x += offsetX
                        end.y += offsetY
                    }
                    let distance = distanceFromPoint(
                        tapPoint,
                        toSegmentFrom: start,
                        to: end
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
        dashed: Bool
    ) {
        self.coordinates = coordinates
        self.routeID = routeID
        self.color = color
        self.opacity = opacity
        self.lineWidth = lineWidth
        self.laneOffsetPoints = laneOffsetPoints
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
        let basePoints = coordinates.map { point(for: MKMapPoint($0)) }
        let offset = CGFloat(routeOverlay.laneOffsetPoints) / zoomScale
        var offsetPoints: [CGPoint] = []

        for index in basePoints.indices {
            let previous = basePoints[index == 0 ? index : index - 1]
            let next = basePoints[index == basePoints.count - 1 ? index : index + 1]
            let deltaX = next.x - previous.x
            let deltaY = next.y - previous.y
            let length = max(0.0001, hypot(deltaX, deltaY))
            let normalX = -deltaY / length
            let normalY = deltaX / length
            offsetPoints.append(
                CGPoint(
                    x: basePoints[index].x + normalX * offset,
                    y: basePoints[index].y + normalY * offset
                )
            )
        }

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

// MARK: - Map annotations

private final class DestinationMapAnnotation: NSObject, MKAnnotation {
    let journey: RouteJourney
    let rank: Int
    let isSelected: Bool
    let isDimmed: Bool
    dynamic var coordinate: CLLocationCoordinate2D { journey.destinationCoordinate }
    var title: String? { journey.destinationName }

    init(
        journey: RouteJourney,
        rank: Int,
        isSelected: Bool,
        isDimmed: Bool
    ) {
        self.journey = journey
        self.rank = rank
        self.isSelected = isSelected
        self.isDimmed = isDimmed
    }
}

private final class StopClusterMapAnnotation: NSObject, MKAnnotation {
    let stop: TransitStop
    let sourceStopIDs: Set<Int>
    let routeIDs: Set<Int>
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
        colors: [UIColor],
        isDimmed: Bool,
        isSelected: Bool
    ) {
        self.stop = stop
        self.sourceStopIDs = sourceStopIDs
        self.routeIDs = routeIDs
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
        frame = CGRect(x: 0, y: 0, width: 210, height: 72)
        centerOffset = CGPoint(x: 0, y: -34)
        alpha = annotation.isDimmed ? 0.28 : 1
        displayPriority = annotation.isSelected
            ? .required
            : (annotation.rank < 3 ? .defaultHigh : .defaultLow)

        let card = UIView(frame: CGRect(x: 5, y: 0, width: 200, height: 62))
        card.backgroundColor = UIColor(red: 0.965, green: 0.945, blue: 0.89, alpha: 0.98)
        card.layer.cornerRadius = 12
        card.layer.borderWidth = 1.5
        card.layer.borderColor = UIColor(annotation.journey.route.color).cgColor
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.14
        card.layer.shadowRadius = 4
        card.layer.shadowOffset = CGSize(width: 0, height: 2)
        addSubview(card)

        let colorBar = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 62))
        colorBar.backgroundColor = UIColor(annotation.journey.route.color)
        colorBar.layer.cornerRadius = 4
        card.addSubview(colorBar)

        let destinationLabel = UILabel(
            frame: CGRect(x: 16, y: 5, width: 176, height: 34)
        )
        destinationLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        destinationLabel.textColor = UIColor(
            red: 0.14, green: 0.19, blue: 0.18, alpha: 1
        )
        destinationLabel.text = annotation.journey.destinationName
        destinationLabel.numberOfLines = 2
        destinationLabel.lineBreakMode = .byTruncatingTail
        card.addSubview(destinationLabel)

        let timeLabel = UILabel(frame: CGRect(x: 16, y: 40, width: 176, height: 17))
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        timeLabel.textColor = UIColor(annotation.journey.route.color)
        timeLabel.text = "\(annotation.journey.totalMinutes) min total"
        card.addSubview(timeLabel)

        let pin = UIView(frame: CGRect(x: 99, y: 59, width: 12, height: 12))
        pin.backgroundColor = UIColor(annotation.journey.route.color)
        pin.layer.cornerRadius = 6
        pin.layer.borderWidth = 2
        pin.layer.borderColor = UIColor.white.cgColor
        addSubview(pin)

        accessibilityLabel = "\(annotation.journey.route.fullDisplayName) to \(annotation.journey.destinationName), \(annotation.journey.totalMinutes) minutes total"
    }
}

private final class StopClusterAnnotationView: MKAnnotationView {
    private var colors: [UIColor] = []
    private var routeCount = 0

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 34, height: 34)
        centerOffset = CGPoint(x: 0, y: 0)
        collisionMode = .circle
        displayPriority = .defaultHigh
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with annotation: StopClusterMapAnnotation) {
        colors = annotation.colors
        routeCount = annotation.routeCount
        alpha = annotation.isDimmed ? 0.22 : 1
        transform = annotation.isSelected
            ? CGAffineTransform(scaleX: 1.22, y: 1.22)
            : .identity
        accessibilityLabel = "\(annotation.stop.name), \(routeCount) routes"
        accessibilityValue = annotation.isSelected ? "Selected" : nil
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let circleRect = rect.insetBy(dx: 4, dy: 4)
        context.setFillColor(UIColor(red: 0.965, green: 0.945, blue: 0.89, alpha: 1).cgColor)
        context.fillEllipse(in: circleRect)

        let visibleColors = colors.isEmpty
            ? [UIColor.systemGray] : Array(colors.prefix(6))
        let arc = CGFloat.pi * 2 / CGFloat(visibleColors.count)
        context.setLineWidth(4)
        for (index, color) in visibleColors.enumerated() {
            context.setStrokeColor(color.cgColor)
            context.addArc(
                center: CGPoint(x: rect.midX, y: rect.midY),
                radius: 12,
                startAngle: -CGFloat.pi / 2 + CGFloat(index) * arc,
                endAngle: -CGFloat.pi / 2 + CGFloat(index + 1) * arc,
                clockwise: false
            )
            context.strokePath()
        }

        let text = "\(routeCount)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold),
            .foregroundColor: UIColor(red: 0.14, green: 0.19, blue: 0.18, alpha: 1),
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
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
