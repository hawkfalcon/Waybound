import SwiftUI
import MapKit

struct ContentView: View {
    @StateObject private var viewModel = TransitViewModel()
    @State private var cameraPosition: MapCameraPosition = .region(TransitViewModel.defaultRegion)
    @State private var showList = false
    @State private var selectedStop: TransitStop?

    var body: some View {
        ZStack(alignment: .bottom) {
            // MARK: - Map (iOS 17+ MapContentBuilder API)
            Map(position: $cameraPosition) {
                // User location
                UserAnnotation()

                // Stop annotations
                ForEach(viewModel.stops) { stop in
                    Annotation(stop.name, coordinate: stop.coordinate) {
                        StopAnnotationView(
                            stop: stop,
                            isSelected: selectedStop?.id == stop.id
                        )
                        .onTapGesture { selectedStop = stop }
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
                        Text("Nearby Transit")
                            .font(.headline)
                        Text("\(viewModel.stops.count) stops · \(viewModel.routes.count) routes within 1 mi")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if viewModel.isLoading {
                        ProgressView()
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
                                    Divider().padding(.leading)
                                }
                            }
                            // Stops section
                            if !viewModel.stops.isEmpty {
                                SectionHeader(title: "Stops", icon: "mappin.circle.fill")
                                ForEach(viewModel.stops) { stop in
                                    StopRow(stop: stop)
                                        .onTapGesture {
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
                StopDetailCard(stop: stop) {
                    selectedStop = nil
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .animation(.easeInOut, value: selectedStop)
        .onChange(of: viewModel.targetRegion) { _, newRegion in
            guard let region = newRegion else { return }
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
        .animation(.spring(), value: isSelected)
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
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            }
            if !stop.routeNames.isEmpty {
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

#Preview {
    ContentView()
}
