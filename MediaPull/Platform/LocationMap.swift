import MapKit
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
