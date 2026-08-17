import SwiftUI
import MapKit

private enum RouteExpansionPrototype: String, CaseIterable {
    case sheet
    case map

    var title: String {
        switch self {
        case .sheet: "Stops in sheet"
        case .map: "Stops on map"
        }
    }

    var icon: String {
        switch self {
        case .sheet: "list.bullet"
        case .map: "map"
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = TransitViewModel()
    @State private var cameraRequest = WayboundCameraRequest(
        region: TransitViewModel.defaultRegion
    )
    @State private var selectedJourneyID: Int?
    @State private var selectedStopID: Int?
    @State private var selectedStopRouteIDs: Set<Int>?
    @State private var expansionPrototype: RouteExpansionPrototype = .sheet

    private var selectedJourney: RouteJourney? {
        viewModel.journeys.first { $0.id == selectedJourneyID }
    }

    private var selectedStop: TransitStop? {
        viewModel.stops.first { $0.id == selectedStopID }
    }

    private var displayedJourneys: [RouteJourney] {
        guard let selectedStopRouteIDs else { return viewModel.journeys }
        return viewModel.journeys.filter {
            selectedStopRouteIDs.contains($0.id)
        }
    }

    private var highlightedRouteIDs: Set<Int>? {
        if let selectedJourneyID { return [selectedJourneyID] }
        return selectedStopRouteIDs
    }

    private var routesWithoutJourneys: [TransitRoute] {
        let journeyRouteIDs = Set(viewModel.journeys.map(\.id))
        return viewModel.routes.filter {
            !journeyRouteIDs.contains($0.transitlandID)
                && (selectedStopRouteIDs?.contains($0.transitlandID) ?? true)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let bottomSheetHeight = sheetHeight(for: geometry.size.height)
            ZStack(alignment: .bottom) {
                WayboundMapView(
                    routes: viewModel.routes,
                    journeys: displayedJourneys,
                    stops: viewModel.stops,
                    selectedJourneyID: selectedJourneyID,
                    selectedStopID: selectedStopID,
                    highlightedRouteIDs: highlightedRouteIDs,
                    showsMapLadder: selectedJourney != nil
                        && expansionPrototype == .map,
                    viewportBottomInset: bottomSheetHeight,
                    cameraRequest: cameraRequest,
                    onSelectJourney: selectJourney,
                    onSelectStop: { stopID, routeIDs in
                        selectStop(stopID, routeIDs: routeIDs)
                    }
                )
                .ignoresSafeArea()

                destinationSheet
                    .frame(
                        maxHeight: bottomSheetHeight,
                        alignment: .bottom
                    )
            }
        }
        .background(WayboundPalette.cream)
        .onChange(of: viewModel.targetRegion) { _, region in
            guard let region else { return }
            selectedJourneyID = nil
            selectedStopID = nil
            selectedStopRouteIDs = nil
            cameraRequest = WayboundCameraRequest(region: region)
        }
        .onChange(of: expansionPrototype) { _, prototype in
            guard prototype == .map, let selectedJourney else { return }
            cameraRequest = WayboundCameraRequest(
                region: expandedRegion(for: selectedJourney)
            )
        }
        .alert("Transit data unavailable", isPresented: $viewModel.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage)
        }
    }

    private var destinationSheet: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(WayboundPalette.ink.opacity(0.22))
                .frame(width: 34, height: 4)
                .padding(.top, 6)
                .padding(.bottom, 5)

            if let selectedJourney {
                JourneyDetailSheet(
                    journey: selectedJourney,
                    prototype: $expansionPrototype,
                    onBack: clearSelection,
                    onRecenter: recenterMap
                )
            } else {
                JourneyOverviewSheet(
                    journeys: displayedJourneys,
                    unavailableRoutes: routesWithoutJourneys,
                    isLoading: viewModel.isLoading || viewModel.isLoadingJourneys,
                    highlightedRouteIDs: highlightedRouteIDs,
                    selectedStopName: selectedStop?.name,
                    onSelect: selectJourney,
                    onClearStop: clearStopSelection,
                    onRecenter: recenterMap
                )
            }
        }
        .background(WayboundPalette.cream.opacity(0.985))
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 28,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 28,
                style: .continuous
            )
        )
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(
                topLeadingRadius: 28,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 28,
                style: .continuous
            )
            .stroke(WayboundPalette.ink.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 18, y: -5)
        .ignoresSafeArea(edges: .bottom)
    }

    private func sheetHeight(for screenHeight: CGFloat) -> CGFloat {
        if selectedJourney != nil {
            return expansionPrototype == .sheet
                ? min(570, screenHeight * 0.62)
                : min(285, screenHeight * 0.32)
        }
        // Preserve most of the screen for spatial context. The overview is a
        // compact chooser, not a second full-height content surface.
        return min(300, max(228, screenHeight * 0.30))
    }

    private func selectJourney(_ routeID: Int) {
        guard let journey = viewModel.journeys.first(where: { $0.id == routeID })
        else { return }
        withAnimation(.snappy(duration: 0.3)) {
            // Keep a stop filter underneath route detail so Back returns to the
            // same stop-specific context instead of restoring every nearby route.
            selectedJourneyID = routeID
        }
        if expansionPrototype == .map {
            cameraRequest = WayboundCameraRequest(
                region: expandedRegion(for: journey)
            )
        }
    }

    private func selectStop(_ stopID: Int, routeIDs: Set<Int>) {
        guard viewModel.stops.contains(where: { $0.id == stopID }) else { return }
        withAnimation(.snappy(duration: 0.3)) {
            selectedJourneyID = nil
            selectedStopID = stopID
            selectedStopRouteIDs = routeIDs
        }
    }

    private func clearStopSelection() {
        withAnimation(.snappy(duration: 0.3)) {
            selectedStopID = nil
            selectedStopRouteIDs = nil
        }
    }

    private func clearSelection() {
        // Route expansion does not own the camera or transit-data lifecycle.
        // Closing detail should leave both exactly where the rider put them.
        withAnimation(.snappy(duration: 0.3)) {
            selectedJourneyID = nil
        }
    }

    private func recenterMap() {
        viewModel.recenter()
        if let region = viewModel.targetRegion {
            cameraRequest = WayboundCameraRequest(region: region)
        }
    }

    private func expandedRegion(for journey: RouteJourney) -> MKCoordinateRegion {
        region(
            containing: [viewModel.userCoordinate]
                + journey.stops.map(\.coordinate),
            reservesBottomSheet: true
        )
    }

    private func region(
        containing coordinates: [CLLocationCoordinate2D],
        reservesBottomSheet: Bool
    ) -> MKCoordinateRegion {
        guard let first = coordinates.first else {
            return TransitViewModel.defaultRegion
        }
        var rect = MKMapRect(
            x: MKMapPoint(first).x,
            y: MKMapPoint(first).y,
            width: 1,
            height: 1
        )
        for coordinate in coordinates.dropFirst() {
            let point = MKMapPoint(coordinate)
            rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
        }

        let minimumMapPoints = MKMapPointsPerMeterAtLatitude(first.latitude) * 1_200
        let contentWidth = max(rect.size.width, minimumMapPoints)
        let contentHeight = max(rect.size.height, minimumMapPoints)
        let horizontalPadding = contentWidth * 0.20
        let topPadding = contentHeight * 0.20
        let bottomPadding = reservesBottomSheet
            ? contentHeight * 0.95 : contentHeight * 0.20
        let padded = MKMapRect(
            x: rect.midX - contentWidth / 2 - horizontalPadding,
            y: rect.midY - contentHeight / 2 - topPadding,
            width: contentWidth + horizontalPadding * 2,
            height: contentHeight + topPadding + bottomPadding
        )
        return MKCoordinateRegion(padded)
    }
}

// MARK: - Overview

private struct JourneyOverviewSheet: View {
    let journeys: [RouteJourney]
    let unavailableRoutes: [TransitRoute]
    let isLoading: Bool
    let highlightedRouteIDs: Set<Int>?
    let selectedStopName: String?
    let onSelect: (Int) -> Void
    let onClearStop: () -> Void
    let onRecenter: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Where these routes go")
                        .font(
                            .system(size: 20, weight: .black, design: .rounded)
                            .width(.condensed)
                        )
                        .foregroundStyle(WayboundPalette.ink)
                    Text(
                        selectedStopName.map { "Routes serving \($0)" }
                            ?? "Up to six nearest boardable routes · one destination each"
                    )
                    .font(.system(size: 10.5, weight: .regular, design: .rounded))
                    .foregroundStyle(WayboundPalette.ink.opacity(0.62))
                    .lineLimit(1)
                }
                Spacer()
                if selectedStopName != nil {
                    Button(action: onClearStop) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(WayboundPalette.ink)
                            .frame(width: 27, height: 27)
                            .background(.white.opacity(0.66))
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("Show all routes")
                } else if isLoading {
                    ProgressView()
                        .tint(WayboundPalette.ink)
                }

                Button(action: onRecenter) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(WayboundPalette.ink)
                        .frame(width: 29, height: 29)
                        .background(.white.opacity(0.72))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Center on my location")
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)

            if journeys.isEmpty && !isLoading {
                ContentUnavailableView {
                    Label("No boardable trips", systemImage: "bus")
                } description: {
                    Text("No real trip with a trusted street shape departs in the next 3 hours.")
                }
                .fontDesign(.rounded)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(journeys) { journey in
                            Button {
                                onSelect(journey.id)
                            } label: {
                                JourneyRow(journey: journey)
                            }
                            .buttonStyle(.plain)
                            .opacity(
                                highlightedRouteIDs.map {
                                    $0.contains(journey.id) ? 1 : 0.28
                                } ?? 1
                            )
                        }

                        if !unavailableRoutes.isEmpty && !isLoading {
                            HStack {
                                Text("No boardable trip in the next 3 hours")
                                    .font(
                                        .system(
                                            size: 13,
                                            weight: .bold,
                                            design: .rounded
                                        ).width(.condensed)
                                    )
                                    .textCase(nil)
                                Spacer()
                                Text("\(unavailableRoutes.count) routes")
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            .foregroundStyle(WayboundPalette.ink.opacity(0.55))
                            .padding(.top, 5)

                            ForEach(unavailableRoutes) { route in
                                UnavailableRouteRow(route: route)
                                    .opacity(
                                        highlightedRouteIDs.map {
                                            $0.contains(route.transitlandID) ? 1 : 0.28
                                        } ?? 1
                                    )
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 14)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

private struct JourneyRow: View {
    let journey: RouteJourney

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            RouteBadge(route: journey.route, size: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(journey.destinationName)
                        .font(.system(size: 14.5, weight: .bold, design: .rounded))
                        .foregroundStyle(WayboundPalette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 3)
                    Text("\(journey.totalMinutes) min")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(journey.route.color)
                }

                HStack(spacing: 4) {
                    Text("Bus in \(journey.departureMinutesFromNow)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(journey.route.color)
                    TimingChip(icon: "figure.walk", label: "walk", minutes: journey.walkMinutes)
                    TimingChip(icon: "hourglass", label: "wait", minutes: journey.waitMinutes)
                    TimingChip(icon: "bus.fill", label: "ride", minutes: journey.rideMinutes)
                    Spacer(minLength: 0)
                    if journey.departureIsRealtime {
                        LiveBadge()
                    }
                }
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(WayboundPalette.ink.opacity(0.34))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(journey.route.color.opacity(0.28), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(journey.route.fullDisplayName) to \(journey.destinationName). Bus in \(journey.departureMinutesFromNow) minutes. Walk \(journey.walkMinutes), wait \(journey.waitMinutes), ride \(journey.rideMinutes), \(journey.totalMinutes) minutes total."
        )
    }
}

private struct UnavailableRouteRow: View {
    let route: TransitRoute

    var body: some View {
        HStack(spacing: 10) {
            RouteBadge(route: route, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(route.fullDisplayName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(route.agencyName)
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Later")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(WayboundPalette.ink.opacity(0.72))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(0.36))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Expanded route prototypes

private struct JourneyDetailSheet: View {
    let journey: RouteJourney
    @Binding var prototype: RouteExpansionPrototype
    let onBack: () -> Void
    let onRecenter: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(WayboundPalette.ink)
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.65))
                        .clipShape(Circle())
                }
                .accessibilityLabel("Back to all destinations")

                RouteBadge(route: journey.route, size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(journey.destinationName)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(WayboundPalette.ink)
                        .lineLimit(1)
                    Text("\(journey.totalMinutes) min total · bus in \(journey.departureMinutesFromNow) min")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(journey.route.color)
                }
                Spacer()
                Button(action: onRecenter) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(WayboundPalette.ink)
                        .frame(width: 29, height: 29)
                        .background(.white.opacity(0.72))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Center on my location")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            HStack(spacing: 8) {
                ForEach(RouteExpansionPrototype.allCases, id: \.self) { option in
                    Button {
                        withAnimation(.snappy(duration: 0.25)) {
                            prototype = option
                        }
                    } label: {
                        Label(option.title, systemImage: option.icon)
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(
                                prototype == option ? Color.white : WayboundPalette.ink
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                prototype == option
                                    ? journey.route.color
                                    : Color.white.opacity(0.58)
                            )
                            .clipShape(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(prototype == option ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            HStack(spacing: 6) {
                TimingChip(icon: "figure.walk", label: "walk", minutes: journey.walkMinutes)
                TimingChip(icon: "hourglass", label: "wait", minutes: journey.waitMinutes)
                TimingChip(icon: "bus.fill", label: "ride", minutes: journey.rideMinutes)
                Spacer()
                if journey.departureIsRealtime {
                    LiveBadge()
                    Text("departure · scheduled ride")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Scheduled departure and ride")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if prototype == .sheet {
                Divider().opacity(0.45)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(journey.stops) { stop in
                            StopLadderRow(
                                stop: stop,
                                routeColor: journey.route.color
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "map.fill")
                        .foregroundStyle(journey.route.color)
                    Text("All \(max(0, journey.stops.count - 1)) downstream stops are now labeled on the map. Other routes step aside; the flagship stays pinned.")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(WayboundPalette.ink.opacity(0.72))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
    }
}

private struct StopLadderRow: View {
    let stop: JourneyStop
    let routeColor: Color

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(stop.isBoarding ? Color.clear : routeColor.opacity(0.34))
                    .frame(width: 2, height: 8)
                ZStack {
                    Circle()
                        .fill(stop.isFlagship ? routeColor : WayboundPalette.cream)
                        .frame(
                            width: stop.isFlagship ? 18 : 12,
                            height: stop.isFlagship ? 18 : 12
                        )
                    Circle()
                        .stroke(routeColor, lineWidth: 2)
                        .frame(
                            width: stop.isFlagship ? 18 : 12,
                            height: stop.isFlagship ? 18 : 12
                        )
                    if stop.isFlagship {
                        Image(systemName: "star.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(.white)
                    }
                }
                Rectangle()
                    .fill(routeColor.opacity(0.34))
                    .frame(width: 2, height: 26)
            }
            .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(stop.name)
                    .font(
                        .system(
                            size: 13,
                            weight: stop.isFlagship ? .bold : .medium,
                            design: .rounded
                        )
                    )
                    .foregroundStyle(WayboundPalette.ink)
                    .lineLimit(2)
                if stop.isBoarding {
                    Text("Board here")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(routeColor)
                } else if stop.isFlagship {
                    Text("Flagship destination")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(routeColor)
                }
            }
            Spacer()
            Text(stop.isBoarding ? "now" : "+\(stop.minutesFromBoarding) min")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(stop.isFlagship ? routeColor : WayboundPalette.ink.opacity(0.58))
                .padding(.top, 1)
        }
        .frame(minHeight: 48)
        .background(
            stop.isFlagship ? routeColor.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Reusable visual language

private struct RouteBadge: View {
    let route: TransitRoute
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(route.color)
            .frame(width: size, height: size)
            .overlay {
                if let number = route.routeNumber {
                    Text(String(number.prefix(4)))
                        .font(
                            .system(
                                size: size * 0.31,
                                weight: .black,
                                design: .rounded
                            ).width(.condensed)
                        )
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.55)
                        .padding(2)
                } else {
                    Image(systemName: "bus.fill")
                        .font(.system(size: size * 0.34, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .shadow(color: route.color.opacity(0.22), radius: 4, y: 2)
    }
}

private struct TimingChip: View {
    let icon: String
    let label: String
    let minutes: Int

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 7.5, weight: .semibold))
            Text("\(label) \(minutes)")
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(WayboundPalette.ink.opacity(0.68))
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(WayboundPalette.ink.opacity(0.055))
        .clipShape(Capsule())
        .accessibilityLabel("\(label) \(minutes) minutes")
    }
}

private struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(Color.green)
                .frame(width: 5, height: 5)
            Text("Live")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(WayboundPalette.ink.opacity(0.72))
        .accessibilityLabel("Live departure estimate")
    }
}

#Preview {
    ContentView()
}
