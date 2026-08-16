import SwiftUI
import MapKit

struct ContentView: View {
    @StateObject private var viewModel = TransitViewModel()
    @State private var cameraPosition: MapCameraPosition = .region(TransitViewModel.defaultRegion)
    @State private var showList = false
    @State private var selectedStop: TransitStop?
    /// Transitland's internal route ID connects route lines to served stops.
    @State private var selectedRouteID: Int?

    private var selectedRoute: TransitRoute? {
        viewModel.routes.first { $0.transitlandID == selectedRouteID }
    }

    private var selectedRouteStopCount: Int {
        guard let selectedRouteID else { return 0 }
        return viewModel.stops.filter {
            $0.routeIDs.contains(selectedRouteID)
        }.count
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // MARK: - Map (iOS 17+ MapContentBuilder API)
            Map(position: $cameraPosition) {
                // Route geometry is drawn first so stop pins stay visible above it.
                ForEach(viewModel.routes) { route in
                    ForEach(route.polylines.indices, id: \.self) { index in
                        MapPolyline(coordinates: route.polylines[index])
                            .stroke(
                                route.color.opacity(
                                    selectedRouteID == nil
                                        || selectedRouteID == route.transitlandID
                                        ? 0.7 : 0.12
                                ),
                                style: StrokeStyle(
                                    lineWidth: selectedRouteID == route.transitlandID ? 6 : 3,
                                    lineCap: .round,
                                    lineJoin: .round
                                )
                            )
                    }
                }

                // User location
                UserAnnotation()

                // Stop annotations
                ForEach(viewModel.stops) { stop in
                    Annotation(stop.name, coordinate: stop.coordinate) {
                        StopAnnotationView(
                            stop: stop,
                            isSelected: selectedStop?.id == stop.id,
                            isDimmed: selectedRouteID.map {
                                !stop.routeIDs.contains($0)
                            } ?? false
                        )
                        .onTapGesture {
                            if let routeID = selectedRouteID,
                               !stop.routeIDs.contains(routeID) {
                                selectedRouteID = nil
                            }
                            selectedStop = stop
                        }
                    }
                }
            }
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .ignoresSafeArea()
            .overlay(alignment: .topTrailing) {
                Button {
                    viewModel.recenter()
                } label: {
                    Image(systemName: "location.fill")
                        .font(.title3)
                        .padding(12)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .shadow(radius: 4)
                }
                .padding()
            }

            // MARK: - Bottom sheet
            VStack(spacing: 0) {
                // Handle bar
                Capsule()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 40, height: 5)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                // Status / title
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedRoute == nil ? "Nearby Transit" : "Selected Route")
                            .font(.headline)
                        if let route = selectedRoute {
                            Text(
                                "\(route.shortName) · \(selectedRouteStopCount) nearby stops · \(route.agencyName)"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        } else {
                            Text("\(viewModel.stops.count) stops · \(viewModel.routes.count) routes within 0.5 mi")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if viewModel.isLoading {
                        ProgressView()
                    } else if selectedRouteID != nil {
                        Button {
                            selectedRouteID = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show all routes")
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)

                Divider()

                // Scrollable list
                if showList {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            // Routes section
                            if !viewModel.routes.isEmpty {
                                SectionHeader(title: "Routes", icon: "tram.fill")
                                ForEach(viewModel.routes) { route in
                                    RouteRow(route: route)
                                        .background(
                                            selectedRouteID == route.transitlandID
                                                ? route.color.opacity(0.14)
                                                : Color.clear
                                        )
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            selectedRouteID =
                                                selectedRouteID == route.transitlandID
                                                ? nil : route.transitlandID
                                            selectedStop = nil
                                            showList = false
                                        }
                                    Divider().padding(.leading)
                                }
                            }
                            // Stops section
                            if !viewModel.stops.isEmpty {
                                SectionHeader(title: "Stops", icon: "mappin.circle.fill")
                                ForEach(viewModel.stops) { stop in
                                    StopRow(stop: stop)
                                        .opacity(
                                            selectedRouteID.map {
                                                stop.routeIDs.contains($0) ? 1 : 0.3
                                            } ?? 1
                                        )
                                        .onTapGesture {
                                            if let routeID = selectedRouteID,
                                               !stop.routeIDs.contains(routeID) {
                                                selectedRouteID = nil
                                            }
                                            selectedStop = stop
                                            withAnimation {
                                                cameraPosition = .region(
                                                    MKCoordinateRegion(
                                                        center: stop.coordinate,
                                                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                                                    )
                                                )
                                            }
                                            showList = false
                                        }
                                    Divider().padding(.leading)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 400)
                }
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 10, y: -5)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    showList.toggle()
                }
            }

            // MARK: - Selected stop detail
            if let stop = selectedStop {
                StopDetailCard(
                    stop: stop,
                    routes: viewModel.routes.filter {
                        stop.routeIDs.contains($0.transitlandID)
                    },
                    selectedRouteID: selectedRouteID,
                    onSelectRoute: { routeID in
                        selectedRouteID = selectedRouteID == routeID ? nil : routeID
                    },
                    onDismiss: {
                        selectedStop = nil
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .animation(.easeInOut, value: selectedStop)
        .onChange(of: viewModel.targetRegion) { _, newRegion in
            guard let region = newRegion else { return }
            selectedStop = nil
            selectedRouteID = nil
            withAnimation {
                cameraPosition = .region(region)
            }
        }
        .alert("Location Error", isPresented: $viewModel.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage)
        }
    }
}

// MARK: - Sub-views

struct StopAnnotationView: View {
    let stop: TransitStop
    let isSelected: Bool
    let isDimmed: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelected ? Color.blue : Color.orange)
                .frame(width: isSelected ? 28 : 20, height: isSelected ? 28 : 20)
                .shadow(radius: 3)
            Image(systemName: "bus.fill")
                .font(.system(size: isSelected ? 14 : 10))
                .foregroundColor(.white)
        }
        .opacity(isDimmed ? 0.25 : 1)
        .scaleEffect(isDimmed ? 0.8 : 1)
        .animation(.spring(), value: isSelected)
        .animation(.easeInOut(duration: 0.2), value: isDimmed)
    }
}

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

struct RouteRow: View {
    let route: TransitRoute

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(route.color)
                .frame(width: 36, height: 36)
                .overlay {
                    Text(route.shortName.prefix(3))
                        .font(.caption2.bold())
                        .foregroundColor(.white)
                        .minimumScaleFactor(0.5)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(route.longName)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(route.agencyName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            routeTypeIcon(route.routeType)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    func routeTypeIcon(_ type: Int) -> some View {
        switch type {
        case 0: Image(systemName: "tram.fill")        // Tram
        case 1: Image(systemName: "train.side.front.car") // Subway
        case 2: Image(systemName: "train.side.front.car") // Rail
        case 3: Image(systemName: "bus.fill")          // Bus
        case 4: Image(systemName: "ferry.fill")        // Ferry
        default: Image(systemName: "figure.walk")
        }
    }
}

struct StopRow: View {
    let stop: TransitStop

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .font(.title2)
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(stop.name)
                    .font(.subheadline)
                    .lineLimit(1)
                if !stop.routeNames.isEmpty {
                    Text(stop.routeNames.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

struct StopDetailCard: View {
    let stop: TransitStop
    let routes: [TransitRoute]
    let selectedRouteID: Int?
    let onSelectRoute: (Int) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "mappin.circle.fill")
                    .foregroundColor(.orange)
                Text(stop.name)
                    .font(.headline)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close stop details")
            }

            if !stop.agencyNames.isEmpty {
                Label {
                    Text(
                        (stop.agencyNames.count == 1 ? "Operator: " : "Operators: ")
                            + stop.agencyNames.joined(separator: " · ")
                    )
                } icon: {
                    Image(systemName: "building.2.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if !routes.isEmpty {
                Text("Serving routes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(routes) { route in
                            Button {
                                onSelectRoute(route.transitlandID)
                            } label: {
                                StopRouteBadge(
                                    route: route,
                                    isSelected: selectedRouteID == route.transitlandID
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else if !stop.routeNames.isEmpty {
                Text("Routes: " + stop.routeNames.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Lat: \(stop.coordinate.latitude, specifier: "%.5f")  Lon: \(stop.coordinate.longitude, specifier: "%.5f")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(radius: 8)
        .padding()
        .padding(.bottom, 120)
    }
}

struct StopRouteBadge: View {
    let route: TransitRoute
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 5)
                .fill(route.color)
                .frame(width: 34, height: 34)
                .overlay {
                    Text(route.shortName.prefix(3))
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.5)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(route.longName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(route.agencyName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 190, alignment: .leading)
        .padding(8)
        .background(
            route.color.opacity(isSelected ? 0.18 : 0.06),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    route.color.opacity(isSelected ? 1 : 0.4),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .accessibilityLabel(
            "\(route.shortName), \(route.longName), operated by \(route.agencyName)"
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    ContentView()
}
