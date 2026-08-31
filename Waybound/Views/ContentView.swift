import SwiftUI
import MapKit

private enum RouteExpansionPrototype: String, CaseIterable {
    case sheet
    case map

    var title: String {
        switch self {
        case .sheet: "Stops listed"
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
    @State private var selectedStopJourneyIDs: Set<Int>?
    @State private var expansionPrototype: RouteExpansionPrototype = .sheet
    @State private var isShowingPlanningSettings = false

    private var selectedJourney: RouteJourney? {
        viewModel.journeys.first { $0.id == selectedJourneyID }
    }

    private var selectedStop: TransitStop? {
        viewModel.stops.first { $0.id == selectedStopID }
    }

    private var displayedJourneys: [RouteJourney] {
        guard let selectedStopJourneyIDs else { return viewModel.journeys }
        return viewModel.journeys.filter {
            selectedStopJourneyIDs.contains($0.id)
        }
    }

    private var highlightedJourneyIDs: Set<Int>? {
        if let selectedJourneyID { return [selectedJourneyID] }
        return selectedStopJourneyIDs
    }

    private var routesWithoutJourneys: [TransitRoute] {
        let journeyRouteIDs = Set(
            viewModel.journeys.map { $0.route.transitlandID }
        )
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
                    highlightedJourneyIDs: highlightedJourneyIDs,
                    showsMapLadder: selectedJourney != nil
                        && expansionPrototype == .map,
                    viewportBottomInset: bottomSheetHeight,
                    cameraRequest: cameraRequest,
                    onSelectJourney: selectJourney,
                    onSelectStop: { stopID, routeIDs, journeyIDs in
                        selectStop(
                            stopID,
                            routeIDs: routeIDs,
                            journeyIDs: journeyIDs
                        )
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
            selectedStopJourneyIDs = nil
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
        .sheet(isPresented: $isShowingPlanningSettings) {
            PlanningSettingsSheet(
                planningDate: viewModel.planningDate,
                onApply: applyPlanningDate
            )
            .presentationDetents([.height(370)])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
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
                    planningDate: viewModel.planningDate,
                    onBack: clearSelection,
                    onSettings: { isShowingPlanningSettings = true },
                    onRecenter: recenterMap
                )
            } else {
                JourneyOverviewSheet(
                    journeys: displayedJourneys,
                    unavailableRoutes: routesWithoutJourneys,
                    isLoading: viewModel.isLoading || viewModel.isLoadingJourneys,
                    highlightedJourneyIDs: highlightedJourneyIDs,
                    selectedStopName: selectedStop?.name,
                    planningDate: viewModel.planningDate,
                    journeyWindowMinutes: viewModel.journeyWindowMinutes,
                    onSelect: selectJourney,
                    onClearStop: clearStopSelection,
                    onSettings: { isShowingPlanningSettings = true },
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

    private func selectStop(
        _ stopID: Int,
        routeIDs: Set<Int>,
        journeyIDs: Set<Int>
    ) {
        guard viewModel.stops.contains(where: { $0.id == stopID }) else { return }
        withAnimation(.snappy(duration: 0.3)) {
            selectedJourneyID = nil
            selectedStopID = stopID
            selectedStopRouteIDs = routeIDs
            selectedStopJourneyIDs = journeyIDs
        }
    }

    private func clearStopSelection() {
        withAnimation(.snappy(duration: 0.3)) {
            selectedStopID = nil
            selectedStopRouteIDs = nil
            selectedStopJourneyIDs = nil
        }
    }

    private func clearSelection() {
        // Route expansion does not own the camera or transit-data lifecycle.
        // Closing detail should leave both exactly where the rider put them.
        withAnimation(.snappy(duration: 0.3)) {
            selectedJourneyID = nil
        }
    }

    private func applyPlanningDate(_ date: Date?) {
        // Journey and stop identities belong to the previous schedule result.
        // Clear them without changing the camera before reloading in place.
        withAnimation(.snappy(duration: 0.2)) {
            selectedJourneyID = nil
            selectedStopID = nil
            selectedStopRouteIDs = nil
            selectedStopJourneyIDs = nil
        }
        viewModel.setPlanningDate(date)
    }

    private func recenterMap() {
        viewModel.recenter()
        if let region = viewModel.targetRegion {
            cameraRequest = WayboundCameraRequest(region: region)
        }
    }

    private func expandedRegion(for journey: RouteJourney) -> MKCoordinateRegion {
        // The stop sequence begins at the rider's nearest viable boarding stop.
        // Frame only the first few downstream stops: this gives useful route
        // context without shrinking the map to fit a trip that may run for miles.
        let nearbyRouteStops = journey.stops.prefix(6).map(\.coordinate)
        return region(
            containing: [viewModel.userCoordinate] + nearbyRouteStops,
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

        // 450 m of ground, in this MapKit world's map points. Calibrated
        // rather than MKMapPointsPerMeterAtLatitude, which no longer matches
        // MKMapPoint's scale on the Xcode 26 SDKs' meter-based world.
        let minimumMapPoints = 450 / TripPathGeometry.metersPerMapPoint(
            atLatitude: first.latitude
        )
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

// MARK: - Transit planning

private struct PlanningSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let planningDate: Date?
    let onApply: (Date?) -> Void
    @State private var draftDate: Date

    init(planningDate: Date?, onApply: @escaping (Date?) -> Void) {
        self.planningDate = planningDate
        self.onApply = onApply
        let initialDate = planningDate.map { max($0, Date()) }
            ?? Self.tomorrowMorning()
        _draftDate = State(initialValue: initialDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Transit time")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(WayboundPalette.ink)
                Text("Preview real scheduled departures from a different time.")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(WayboundPalette.ink.opacity(0.62))
            }

            HStack(spacing: 10) {
                quickChoice(
                    title: "Now",
                    detail: "Live service",
                    systemImage: "location.north.circle.fill",
                    isSelected: planningDate == nil
                ) {
                    onApply(nil)
                    dismiss()
                }

                let tomorrow = Self.tomorrowMorning()
                quickChoice(
                    title: "Tomorrow morning",
                    detail: tomorrow.formatted(date: .omitted, time: .shortened),
                    systemImage: "sunrise.fill",
                    isSelected: planningDate.map {
                        Calendar.autoupdatingCurrent.isDate(
                            $0,
                            equalTo: tomorrow,
                            toGranularity: .minute
                        )
                    } ?? false
                ) {
                    onApply(tomorrow)
                    dismiss()
                }
            }

            VStack(spacing: 8) {
                DatePicker(
                    "Date",
                    selection: $draftDate,
                    in: Date()...,
                    displayedComponents: .date
                )
                DatePicker(
                    "Departure time",
                    selection: $draftDate,
                    in: Date()...,
                    displayedComponents: .hourAndMinute
                )
            }
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(WayboundPalette.ink)

            Button {
                onApply(draftDate)
                dismiss()
            } label: {
                Text("Preview this time")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(WayboundPalette.ink)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 18)
        .background(WayboundPalette.cream)
    }

    private func quickChoice(
        title: String,
        detail: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .bold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(detail)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .opacity(0.72)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.white : WayboundPalette.ink)
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                isSelected ? WayboundPalette.ink : Color.white.opacity(0.58)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(WayboundPalette.ink.opacity(0.09), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private static func tomorrowMorning(from date: Date = Date()) -> Date {
        let calendar = Calendar.autoupdatingCurrent
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        return calendar.date(
            bySettingHour: 8,
            minute: 0,
            second: 0,
            of: tomorrow
        ) ?? tomorrow
    }
}

// MARK: - Overview

private struct JourneyOverviewSheet: View {
    let journeys: [RouteJourney]
    let unavailableRoutes: [TransitRoute]
    let isLoading: Bool
    let highlightedJourneyIDs: Set<Int>?
    let selectedStopName: String?
    let planningDate: Date?
    let journeyWindowMinutes: Int
    let onSelect: (Int) -> Void
    let onClearStop: () -> Void
    let onSettings: () -> Void
    let onRecenter: () -> Void

    private var contextDescription: String {
        let routeScope = selectedStopName.map { "Trips serving \($0)" }
            ?? "Buses you can catch nearby"
        guard let planningDate else { return routeScope }
        return "\(planningDate.formatted(date: .abbreviated, time: .shortened)) · \(routeScope)"
    }

    private var journeyWindowText: String {
        if journeyWindowMinutes >= 60 {
            let hours = journeyWindowMinutes / 60
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        return journeyWindowMinutes == 1
            ? "1 minute"
            : "\(journeyWindowMinutes) minutes"
    }

    /// Both useful directions of one route are a single mental object ("the
    /// 11"), so they sit adjacent in the list. Groups keep the ranking of
    /// their best journey; within a group the sooner departure leads.
    private var groupedJourneys: [RouteJourney] {
        var groupOrder: [String] = []
        var groups: [String: [RouteJourney]] = [:]
        for journey in journeys {
            let key = "\(journey.route.agencyName)|"
                + (journey.route.routeNumber ?? journey.route.shortName)
            if groups[key] == nil { groupOrder.append(key) }
            groups[key, default: []].append(journey)
        }
        return groupOrder.flatMap { groups[$0] ?? [] }
    }

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
                    Text(contextDescription)
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

                Button(action: onSettings) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(WayboundPalette.ink)
                            .frame(width: 29, height: 29)
                            .background(.white.opacity(0.72))
                            .clipShape(Circle())
                        if planningDate != nil {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 7, height: 7)
                                .overlay(Circle().stroke(WayboundPalette.cream, lineWidth: 1.5))
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    planningDate == nil
                        ? "Transit time settings, showing now"
                        : "Transit time settings, future preview active"
                )

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
                    Text("No real trip with a trusted street shape departs in the next \(journeyWindowText).")
                }
                .fontDesign(.rounded)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(groupedJourneys) { journey in
                            Button {
                                onSelect(journey.id)
                            } label: {
                                JourneyRow(journey: journey)
                            }
                            .buttonStyle(.plain)
                            .opacity(
                                highlightedJourneyIDs.map {
                                    $0.contains(journey.id) ? 1 : 0.28
                                } ?? 1
                            )
                        }

                        if !unavailableRoutes.isEmpty && !isLoading {
                            HStack {
                                Text("No boardable trip in the next \(journeyWindowText)")
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

    private var arrivalTimeText: String {
        journey.arrivalDate.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // The accent stripe is the same ink as the route's map strand, so
            // scanning between a card and the line it describes needs no
            // reading — the card visually *is* a piece of the route.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(journey.route.color)
                .frame(width: 3.5)
                .padding(.vertical, 2)

            RouteBadge(route: journey.route, size: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(journey.destinationName)
                        .font(.system(size: 14.5, weight: .bold, design: .rounded))
                        .foregroundStyle(WayboundPalette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 3)
                    // The commitment answer: when do I get there? Clock time
                    // is what riders plan around; duration stays for comparing
                    // options against each other.
                    Text("Arrive \(arrivalTimeText)")
                        .font(.system(size: 12.5, weight: .bold, design: .monospaced))
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
                    // Realtime is the norm and earns no marker; only the
                    // exception — a schedule-only estimate — is called out.
                    if !journey.departureIsRealtime {
                        ScheduledBadge()
                    } else {
                        Text("\(journey.totalMinutes) min")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(WayboundPalette.ink.opacity(0.55))
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
            "\(journey.route.fullDisplayName) to \(journey.destinationName). Bus in \(journey.departureMinutesFromNow) minutes, arriving \(arrivalTimeText). Walk \(journey.walkMinutes), wait \(journey.waitMinutes), ride \(journey.rideMinutes), \(journey.totalMinutes) minutes total.\(journey.departureIsRealtime ? "" : " Scheduled estimate.")"
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
    let planningDate: Date?
    let onBack: () -> Void
    let onSettings: () -> Void
    let onRecenter: () -> Void

    private var timingDescription: String {
        let arrivalTime = journey.arrivalDate.formatted(
            date: .omitted,
            time: .shortened
        )
        let relativeTiming = "Arrive \(arrivalTime) · \(journey.totalMinutes) min · bus in \(journey.departureMinutesFromNow)"
        guard let planningDate else { return relativeTiming }
        let previewTime = planningDate.formatted(
            .dateTime.weekday(.abbreviated).hour().minute()
        )
        return "\(relativeTiming) · \(previewTime)"
    }

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
                    Text(timingDescription)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(journey.route.color)
                }
                Spacer()
                Button(action: onSettings) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(WayboundPalette.ink)
                            .frame(width: 29, height: 29)
                            .background(.white.opacity(0.72))
                            .clipShape(Circle())
                        if planningDate != nil {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 7, height: 7)
                                .overlay(Circle().stroke(WayboundPalette.cream, lineWidth: 1.5))
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    planningDate == nil
                        ? "Transit time settings, showing now"
                        : "Transit time settings, future preview active"
                )

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
                    Text("live departure · scheduled ride")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.secondary)
                } else {
                    ScheduledBadge()
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

/// Realtime departures are the expected case and carry no marker. Only the
/// exception — an estimate from the static schedule — earns a flag, so the
/// badge means something when it appears.
private struct ScheduledBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "clock")
                .font(.system(size: 8, weight: .semibold))
            Text("Sched")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(WayboundPalette.ink.opacity(0.55))
        .accessibilityLabel("Scheduled estimate, no live data")
    }
}

#Preview {
    ContentView()
}
