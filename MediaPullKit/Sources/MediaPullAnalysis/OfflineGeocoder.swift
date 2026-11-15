import Foundation
import MediaPullCore

/// Place names from a bundled GeoNames table, without any network access (R-3605, D-59).
/// The table is `places.tsv`: name, region, country, latitude, longitude, population, one place per line.
public final class OfflineGeocoder: Sendable {
    struct Place: Sendable {
        var lat: Float
        var lon: Float
        var population: Int32
        var name: String
        var region: String
        var country: String
    }

    let places: [Place]
    /// Place indexes by whole-degree cell.
    let cells: [Int: [Int32]]
    public static let maximumDistance = 50.0

    public init?(table url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var places: [Place] = []
        places.reserveCapacity(200_000)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 6, let lat = Float(f[3]), let lon = Float(f[4]) else { continue }
            places.append(Place(
                lat: lat,
                lon: lon,
                population: Int32(f[5]) ?? 0,
                name: String(f[0]),
                region: String(f[1]),
                country: String(f[2])
            ))
        }
        guard !places.isEmpty else { return nil }
        var cells: [Int: [Int32]] = [:]
        for (i, p) in places.enumerated() {
            cells[Self.cell(Double(p.lat), Double(p.lon)), default: []].append(Int32(i))
        }
        self.places = places
        self.cells = cells
    }

    static func cell(_ lat: Double, _ lon: Double) -> Int {
        let la = Int(floor(lat)) + 90, lo = (Int(floor(lon)) + 180 + 360) % 360
        return la * 360 + lo
    }

    static func distanceKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371.0, p = Double.pi / 180
        let a = sin((lat2 - lat1) * p / 2), b = sin((lon2 - lon1) * p / 2)
        let h = a * a + cos(lat1 * p) * cos(lat2 * p) * b * b
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// The nearest place within 50 km, leaning slightly towards larger places when several are close.
    public func place(latitude: Double, longitude: Double) -> PlaceName? {
        guard (-90 ... 90).contains(latitude), (-180 ... 180).contains(longitude) else { return nil }
        let latSpan = 1
        let lonSpan = Int(ceil(0.5 / max(0.05, cos(latitude * .pi / 180)))) + 1
        var best: (score: Double, index: Int)?
        for dLat in -latSpan ... latSpan {
            for dLon in -lonSpan ... lonSpan {
                guard let list = cells[Self.cell(latitude + Double(dLat), longitude + Double(dLon))] else { continue }
                for i in list {
                    let p = places[Int(i)]
                    let d = Self.distanceKm(latitude, longitude, Double(p.lat), Double(p.lon))
                    guard d <= Self.maximumDistance else { continue }
                    let score = d - 2.5 * log10(Double(max(p.population, 1)))
                    if best == nil || score < best!.score {
                        best = (score, Int(i))
                    }
                }
            }
        }
        guard let index = best?.index else { return nil }
        let p = places[index]
        return PlaceName(city: p.name, region: p.region.isEmpty ? nil : p.region, country: p.country)
    }

    public var count: Int {
        places.count
    }
}
