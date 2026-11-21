import Foundation

/// Where files were taken, gathered into pins for the map (R-4402): one per cell of a grid over the area shown, so a
/// zoomed-out map never draws thousands of pins. Pure, so it is tested without a map.
public enum MapClusters {
    public struct Point: Sendable, Hashable {
        public var id: String
        public var latitude: Double
        public var longitude: Double

        public init(id: String, latitude: Double, longitude: Double) {
            self.id = id
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    public struct Cluster: Sendable, Hashable, Identifiable {
        public var latitude: Double
        public var longitude: Double
        public var ids: [String]
        public var id: String { ids.first ?? "\(latitude),\(longitude)" }
    }

    /// An area on the map: its south-west and north-east corners.
    public struct Area: Sendable, Equatable {
        public var south: Double
        public var west: Double
        public var north: Double
        public var east: Double

        public init(south: Double, west: Double, north: Double, east: Double) {
            self.south = min(south, north)
            self.north = max(south, north)
            self.west = west
            self.east = east
        }

        /// Crossing the date line (west east of east) is handled.
        public func contains(latitude: Double, longitude: Double) -> Bool {
            guard latitude >= south, latitude <= north else { return false }
            return west <= east ? longitude >= west && longitude <= east : longitude >= west || longitude <= east
        }
    }

    /// Points inside `area`, joined per grid cell (`cells` across the area's width), at most `limit` pins: the grid
    /// coarsens until they fit. Each pin sits at its points' average.
    public static func clusters(_ points: [Point], in area: Area, cells: Int = 24, limit: Int = 500) -> [Cluster] {
        let inside = points.filter { area.contains(latitude: $0.latitude, longitude: $0.longitude) }
        var cells = max(cells, 1)
        while true {
            let width = (area.east >= area.west ? area.east - area.west : area.east + 360 - area.west) / Double(cells)
            let height = max(area.north - area.south, 1e-9) / Double(cells)
            var buckets: [Int: [Point]] = [:]
            for point in inside {
                var x = point.longitude - area.west
                if x < 0 { x += 360 }
                let column = min(Int(x / max(width, 1e-9)), cells - 1)
                let row = min(Int((point.latitude - area.south) / height), cells - 1)
                buckets[row * cells + column, default: []].append(point)
            }
            if buckets.count <= limit || cells == 1 {
                return buckets.keys.sorted().map { key in
                    let members = buckets[key] ?? []
                    let lat = members.map(\.latitude).reduce(0, +) / Double(members.count)
                    let lon = members.map(\.longitude).reduce(0, +) / Double(members.count)
                    return Cluster(latitude: lat, longitude: lon, ids: members.map(\.id).sorted())
                }
            }
            cells = max(cells / 2, 1)
        }
    }
}

/// Files counted per day, month or year for the timeline strip (R-4403).
public enum Timeline {
    public enum Scale: String, Sendable, CaseIterable {
        case day, month, year

        public var label: String {
            switch self {
            case .day: "Days"
            case .month: "Months"
            case .year: "Years"
            }
        }

        var component: Calendar.Component {
            switch self {
            case .day: .day
            case .month: .month
            case .year: .year
            }
        }
    }

    public struct Bucket: Sendable, Hashable, Identifiable {
        public var start: Date
        public var end: Date
        public var ids: [String]
        public var id: Date { start }
    }

    /// The scale that keeps the strip readable for this span: days up to two months, months up to six years, else years.
    public static func scale(from first: Date, to last: Date) -> Scale {
        let days = last.timeIntervalSince(first) / 86400
        return days <= 62 ? .day : days <= 6 * 366 ? .month : .year
    }

    /// One bucket per day, month or year from the first file's to the last's, empty ones included, so gaps show.
    public static func buckets(_ dated: [(id: String, date: Date)], scale: Scale, calendar: Calendar = .current) -> [Bucket] {
        guard let first = dated.map(\.date).min(), let last = dated.map(\.date).max(),
              var start = calendar.dateInterval(of: scale.component, for: first)?.start
        else { return [] }
        var byStart: [Date: [String]] = [:]
        for item in dated {
            guard let bucket = calendar.dateInterval(of: scale.component, for: item.date)?.start else { continue }
            byStart[bucket, default: []].append(item.id)
        }
        var out: [Bucket] = []
        while start <= last, out.count < 5000 {
            guard let end = calendar.date(byAdding: scale.component, value: 1, to: start) else { break }
            out.append(Bucket(start: start, end: end, ids: byStart[start] ?? []))
            start = end
        }
        return out
    }
}
