import MapKit
import MediaPullCore
import SwiftUI

/// The map of where a file was taken (D-110, R-514): a pin on Apple's map, the only map in MediaPull. Map images for the
/// area shown come from Apple's map servers, so it is drawn only once the person has allowed maps. Nothing else of MapKit
/// is used here or anywhere: no search, no geocoding.
struct LocationMap: View {
    let latitude: Double
    let longitude: Double
    var title: String
    @State private var position: MapCameraPosition

    init(latitude: Double, longitude: Double, title: String, span: Double = 0.05) {
        self.latitude = latitude
        self.longitude = longitude
        self.title = title
        let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        _position = State(initialValue: .region(MKCoordinateRegion(center: center,
                                                                   span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))))
    }

    var body: some View {
        Map(position: $position, interactionModes: [.pan, .zoom]) {
            Marker(title, coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        }
        .mapControls {
            MapZoomStepper()
            MapCompass()
            MapScaleView()
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
    }
}

/// Choosing where photos were taken (R-4508): a click on the map sets the pin; Use This Place hands it back. Drawn only
/// after the person allows maps, as `LocationMap` is (D-110); nothing is searched.
struct LocationPicker: View {
    var onPick: (Double, Double) -> Void
    var onCancel: () -> Void
    @State private var position: MapCameraPosition
    @State private var chosen: CLLocationCoordinate2D?

    init(latitude: Double?, longitude: Double?, onPick: @escaping (Double, Double) -> Void, onCancel: @escaping () -> Void) {
        self.onPick = onPick
        self.onCancel = onCancel
        if let latitude, let longitude {
            let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            _position = State(initialValue: .region(MKCoordinateRegion(center: center,
                                                                       span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2))))
            _chosen = State(initialValue: center)
        } else {
            _position = State(initialValue: .automatic)
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            MapReader { proxy in
                Map(position: $position, interactionModes: [.pan, .zoom]) {
                    if let chosen { Marker("", coordinate: chosen) }
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll))
                .onTapGesture { point in
                    if let coordinate = proxy.convert(point, from: .local) { chosen = coordinate }
                }
            }
            .frame(minHeight: 220)
            HStack {
                Text(chosen.map { String(format: "%.5f, %.5f", $0.latitude, $0.longitude) } ?? "Click the map where they were taken.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Use This Place") { if let chosen { onPick(chosen.latitude, chosen.longitude) } }
                    .disabled(chosen == nil)
            }
            .controlSize(.small)
        }
    }
}

/// Where many files were taken (R-4402): pins clustered by MediaPull's own grid as the map moves, a count on each, and an
/// area drawn with Select Area. Drawn only after the person allows maps, as `LocationMap` is (D-110); nothing is searched.
struct LocationClusterMap: View {
    let points: [MapClusters.Point]
    /// Files of a chosen pin, or inside a drawn area.
    var onChoose: ([String]) -> Void
    @Binding var selectingArea: Bool
    @State private var position: MapCameraPosition = .automatic
    @State private var area: MapClusters.Area?
    @State private var dragStart: CGPoint?
    @State private var dragNow: CGPoint?

    private static let world = MapClusters.Area(south: -85, west: -180, north: 85, east: 180)

    var body: some View {
        MapReader { proxy in
            Map(position: $position, interactionModes: selectingArea ? [] : [.pan, .zoom]) {
                ForEach(MapClusters.clusters(points, in: area ?? Self.world)) { cluster in
                    Annotation("", coordinate: CLLocationCoordinate2D(latitude: cluster.latitude, longitude: cluster.longitude)) {
                        Button { onChoose(cluster.ids) } label: {
                            Text("\(cluster.ids.count)")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.accentColor))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .help(cluster.ids.count == 1 ? "Select this file" : "Select these \(cluster.ids.count) files")
                    }
                }
            }
            .mapControls {
                MapZoomStepper()
                MapCompass()
                MapScaleView()
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .onMapCameraChange(frequency: .onEnd) { context in
                let region = context.region
                area = MapClusters.Area(south: region.center.latitude - region.span.latitudeDelta / 2,
                                        west: region.center.longitude - region.span.longitudeDelta / 2,
                                        north: region.center.latitude + region.span.latitudeDelta / 2,
                                        east: region.center.longitude + region.span.longitudeDelta / 2)
            }
            .overlay {
                if selectingArea {
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.06).contentShape(Rectangle())
                        if let start = dragStart, let now = dragNow {
                            Rectangle()
                                .strokeBorder(Color.accentColor, lineWidth: 2)
                                .background(Color.accentColor.opacity(0.12))
                                .frame(width: abs(now.x - start.x), height: abs(now.y - start.y))
                                .offset(x: min(start.x, now.x), y: min(start.y, now.y))
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            dragStart = value.startLocation
                            dragNow = value.location
                        }
                        .onEnded { value in
                            defer {
                                dragStart = nil
                                dragNow = nil
                                selectingArea = false
                            }
                            guard let a = proxy.convert(value.startLocation, from: .local),
                                  let b = proxy.convert(value.location, from: .local) else { return }
                            let drawn = MapClusters.Area(south: min(a.latitude, b.latitude), west: min(a.longitude, b.longitude),
                                                         north: max(a.latitude, b.latitude), east: max(a.longitude, b.longitude))
                            onChoose(points.filter { drawn.contains(latitude: $0.latitude, longitude: $0.longitude) }.map(\.id))
                        })
                }
            }
        }
    }
}
