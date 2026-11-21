import Foundation

/// The values a metadata edit changes (section 45).
public enum MetadataField: String, Codable, Sendable, CaseIterable {
    case rating, keywords, taken, location
}

/// The date a photo was taken as its file records it: EXIF text (`yyyy:MM:dd HH:mm:ss`, the camera's clock) and the
/// offset recorded with it, for the original and the digitized date.
public struct TakenDate: Codable, Sendable, Hashable {
    public var original: String?
    public var originalOffset: String?
    public var digitized: String?
    public var digitizedOffset: String?

    public init(original: String? = nil, originalOffset: String? = nil, digitized: String? = nil, digitizedOffset: String? = nil) {
        self.original = original
        self.originalOffset = originalOffset
        self.digitized = digitized
        self.digitizedOffset = digitizedOffset
    }

    public var isEmpty: Bool {
        original == nil && digitized == nil
    }
}

/// Some of a file's editable values: only the fields in `fields` count, and one of them with no value means the file has
/// none (written as a removal). Undo keeps the values before an edit this way, never the earlier bytes (R-4505).
public struct MetadataValues: Codable, Sendable, Hashable {
    public var fields: Set<MetadataField>
    public var rating: Int?
    /// The rating as written when it is not one to five stars (`-1`, which marks a rejected photo, or `0`), so an Undo
    /// writes it back as it was (audit 2026-11-21-3, A3-2). Read and written with the rating only.
    public var ratingText: String?
    public var keywords: [String]?
    public var taken: TakenDate?
    public var latitude: Double?
    public var longitude: Double?

    public init(fields: Set<MetadataField> = [], rating: Int? = nil, keywords: [String]? = nil, taken: TakenDate? = nil,
                latitude: Double? = nil, longitude: Double? = nil)
    {
        self.fields = fields
        self.rating = rating
        self.keywords = keywords
        self.taken = taken
        self.latitude = latitude
        self.longitude = longitude
    }

    /// No value in any field: what a `.xmp` held for these fields before it was made.
    public var isBlank: Bool {
        rating == nil && ratingText == nil && keywords == nil && taken == nil && latitude == nil && longitude == nil
    }

    /// The same values, keeping only `wanted` fields.
    public func only(_ wanted: Set<MetadataField>) -> MetadataValues {
        var out = MetadataValues(fields: fields.intersection(wanted))
        if out.fields.contains(.rating) {
            out.rating = rating
            out.ratingText = ratingText
        }
        if out.fields.contains(.keywords) { out.keywords = keywords }
        if out.fields.contains(.taken) { out.taken = taken }
        if out.fields.contains(.location) {
            out.latitude = latitude
            out.longitude = longitude
        }
        return out
    }

    /// `other`'s fields over these.
    public func merging(_ other: MetadataValues) -> MetadataValues {
        var out = self
        out.fields.formUnion(other.fields)
        if other.fields.contains(.rating) {
            out.rating = other.rating
            out.ratingText = other.ratingText
        }
        if other.fields.contains(.keywords) { out.keywords = other.keywords }
        if other.fields.contains(.taken) { out.taken = other.taken }
        if other.fields.contains(.location) {
            out.latitude = other.latitude
            out.longitude = other.longitude
        }
        return out
    }

    /// Whether these values hold for every field of `wanted`, as the file would read back (R-4502).
    public func agrees(with wanted: MetadataValues) -> Bool {
        for field in wanted.fields {
            switch field {
            case .rating: if (rating ?? 0) != (wanted.rating ?? 0) { return false }
            case .keywords: if (keywords ?? []) != (wanted.keywords ?? []) { return false }
            case .taken:
                let a = taken ?? TakenDate(), b = wanted.taken ?? TakenDate()
                if a.original != b.original || a.digitized != b.digitized
                    || MetadataEdit.offset(a.originalOffset) != MetadataEdit.offset(b.originalOffset)
                    || a.digitized != nil && MetadataEdit.offset(a.digitizedOffset) != MetadataEdit.offset(b.digitizedOffset)
                {
                    return false
                }
            case .location:
                switch (latitude, longitude, wanted.latitude, wanted.longitude) {
                case (nil, nil, nil, nil): break
                case let (lat?, lon?, wlat?, wlon?):
                    // Degrees with minutes to 1/10,000: about 0.2 m.
                    if abs(lat - wlat) > 0.00001 || abs(lon - wlon) > 0.00001 { return false }
                default: return false
                }
            }
        }
        return true
    }
}

/// What the person asks for (R-4501), applied to each file's current values.
public enum MetadataEdit: Sendable, Hashable {
    /// Nil or 0: no rating.
    case rating(Int?)
    case keywords(add: [String], remove: [String])
    /// The camera's clock was this many seconds off: every recorded date moves, offsets stay.
    case shiftDate(seconds: Int)
    /// The clock times were right but the zone was not: offsets become this one (`+09:00`), times stay.
    case timeZone(String)
    case location(latitude: Double, longitude: Double)
    case removeLocation

    public var field: MetadataField {
        switch self {
        case .rating: .rating
        case .keywords: .keywords
        case .shiftDate, .timeZone: .taken
        case .location, .removeLocation: .location
        }
    }

    /// The new values for a file whose values are `current`, or nil when this edit changes nothing there (no date to
    /// shift, the same rating). Only this edit's field is set in the result.
    public func apply(to current: MetadataValues) -> MetadataValues? {
        var out = MetadataValues(fields: [field])
        switch self {
        case let .rating(stars):
            let value = stars.flatMap { $0 > 0 ? min($0, 5) : nil }
            guard value != current.rating else { return nil }
            out.rating = value
        case let .keywords(add, remove):
            var list = current.keywords ?? []
            let removing = Set(remove.map { $0.lowercased() })
            list.removeAll { removing.contains($0.lowercased()) }
            for word in add {
                guard let word = word.trimmedNonEmpty, !list.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame })
                else { continue }
                list.append(word)
            }
            guard list != (current.keywords ?? []) else { return nil }
            out.keywords = list.isEmpty ? nil : list
        case let .shiftDate(seconds):
            guard seconds != 0, let taken = current.taken, !taken.isEmpty else { return nil }
            // Each date that can be read moves; one left blank by the camera ("0000:00:00 …") stays as it is.
            var shifted = taken
            shifted.original = taken.original.map { Self.shift($0, by: seconds) ?? $0 }
            shifted.digitized = taken.digitized.map { Self.shift($0, by: seconds) ?? $0 }
            guard shifted != taken else { return nil }
            out.taken = shifted
        case let .timeZone(zone):
            guard let zone = Self.offset(zone), let taken = current.taken, !taken.isEmpty else { return nil }
            var zoned = taken
            if taken.original != nil { zoned.originalOffset = zone }
            if taken.digitized != nil { zoned.digitizedOffset = zone }
            guard zoned != taken else { return nil }
            out.taken = zoned
        case let .location(lat, lon):
            guard (-90 ... 90).contains(lat), (-180 ... 180).contains(lon) else { return nil }
            if let clat = current.latitude, let clon = current.longitude, abs(clat - lat) < 0.00001, abs(clon - lon) < 0.00001 {
                return nil
            }
            out.latitude = lat
            out.longitude = lon
        case .removeLocation:
            guard current.latitude != nil || current.longitude != nil else { return nil }
        }
        return out
    }

    // MARK: Dates

    /// EXIF clock text read and written as a floating time: no zone is applied, so shifting never crosses a daylight
    /// saving change.
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    public static func shift(_ text: String, by seconds: Int) -> String? {
        guard let date = clock.date(from: text.trimmingCharacters(in: .whitespaces)) else { return nil }
        return clock.string(from: date.addingTimeInterval(TimeInterval(seconds)))
    }

    /// The moment a clock text and offset name (the Mac's own zone when there is no offset).
    public static func moment(_ text: String, offset: String?) -> Date? {
        guard let floating = clock.date(from: text.trimmingCharacters(in: .whitespaces)) else { return nil }
        let seconds = offset.flatMap(offsetSeconds) ?? TimeZone.current.secondsFromGMT(for: floating)
        return floating.addingTimeInterval(TimeInterval(-seconds))
    }

    /// `+08:00`, `+0800`, `+08` and `Z` as `+08:00`; anything else is nil.
    public static func offset(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text == "Z" { return "+00:00" }
        guard let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let rest = text.dropFirst()
        let digits = rest.filter(\.isNumber)
        guard digits.count == rest.count(where: { $0 != ":" }) else { return nil }
        let hours: Substring, minutes: Substring
        switch digits.count {
        case 2: (hours, minutes) = (digits.prefix(2), "00")
        case 4: (hours, minutes) = (digits.prefix(2), digits.suffix(2))
        default: return nil
        }
        guard let h = Int(hours), let m = Int(minutes), h <= 14, m < 60 else { return nil }
        return "\(sign)\(hours):\(minutes)"
    }

    public static func offsetSeconds(_ text: String) -> Int? {
        guard let normal = offset(text) else { return nil }
        let sign = normal.hasPrefix("-") ? -1 : 1
        let parts = normal.dropFirst().split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return sign * (parts[0] * 3600 + parts[1] * 60)
    }

    /// `+09:00` for 32,400 seconds.
    public static func offsetText(seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let total = abs(seconds) / 60
        return String(format: "%@%02d:%02d", sign, total / 60, total % 60)
    }
}

/// How XMP writes dates and GPS positions (XMP specification part 2: Date, GPSCoordinate), for `.xmp` files beside RAW
/// and other files that are not written in place (R-4502).
public enum XMPText {
    /// `2021:05:06 07:08:09` with `+09:00` as `2021-05-06T07:08:09+09:00`.
    public static func date(exif text: String, offset: String?) -> String? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard parts.count == 2 else { return nil }
        let day = parts[0].split(separator: ":"), time = parts[1]
        guard day.count == 3, day.allSatisfy({ Int($0) != nil }), time.split(separator: ":").count == 3 else { return nil }
        return "\(day[0])-\(day[1])-\(day[2])T\(time)\(MetadataEdit.offset(offset) ?? "")"
    }

    /// An XMP date (`2019-07-01T10:11:12.50+02:00`, `2019-07-01T10:11Z`, `2019-07-01`, or the EXIF form some writers use)
    /// as EXIF text and its offset.
    public static func exif(fromDate text: String) -> (text: String, offset: String?)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 19, trimmed.dropFirst(4).first == ":" {
            return (String(trimmed.prefix(19)), MetadataEdit.offset(String(trimmed.dropFirst(19))))
        }
        let halves = trimmed.split(separator: "T", maxSplits: 1)
        let day = halves.first.map { $0.split(separator: "-") } ?? []
        guard day.count == 3, day[0].count == 4, day.allSatisfy({ Int($0) != nil }) else { return nil }
        var clock = "00:00:00", offset: String?
        if halves.count == 2 {
            var rest = Substring(halves[1])
            if let zone = rest.firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
                offset = MetadataEdit.offset(String(rest[zone...]))
                rest = rest[..<zone]
            }
            var fields = rest.split(separator: ":").map(String.init)
            guard (2 ... 3).contains(fields.count) else { return nil }
            if fields.count == 2 { fields.append("00") }
            fields[2] = String(fields[2].prefix { $0 != "." })
            guard fields.allSatisfy({ $0.count == 2 && Int($0) != nil }) else { return nil }
            clock = fields.joined(separator: ":")
        }
        return ("\(day[0]):\(day[1]):\(day[2]) \(clock)", offset)
    }

    /// 35.5 as a latitude: `35,30.000000N`.
    public static func coordinate(_ value: Double, latitude: Bool) -> String {
        let reference = latitude ? (value < 0 ? "S" : "N") : (value < 0 ? "W" : "E")
        let degrees = abs(value)
        let whole = Int(degrees.rounded(.down))
        return String(format: "%d,%.6f%@", whole, (degrees - Double(whole)) * 60, reference)
    }

    /// `52,22.5N`, `52,22,30N` or a plain signed number, as signed degrees.
    public static func degrees(_ text: String) -> Double? {
        var body = text.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        var sign = 1.0
        if let last = body.last, "NSEW".contains(last.uppercased()) {
            if "SW".contains(last.uppercased()) { sign = -1 }
            body.removeLast()
        } else {
            return Double(body)
        }
        let parts = body.split(separator: ",").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        let values = parts.compactMap(\.self)
        var total = values[0]
        if values.count > 1 { total += values[1] / 60 }
        if values.count > 2 { total += values[2] / 3600 }
        return sign * total
    }
}
