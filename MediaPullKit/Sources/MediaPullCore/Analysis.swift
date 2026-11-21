import Foundation

// MARK: What analysis records about a file (SPEC section 36)

public enum Orientation: String, Codable, Sendable, CaseIterable {
    case landscape, portrait, square

    public var label: String {
        switch self {
        case .landscape: "Landscape"
        case .portrait: "Portrait"
        case .square: "Square"
        }
    }
}

/// Facts read from the file itself, without models.
public struct MediaFacts: Codable, Sendable, Hashable {
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var format: MediaFormat?
    public var isAnimated = false
    public var duration: Double?
    public var cameraMake: String?
    public var cameraModel: String?
    public var captureDate: Date?
    public var latitude: Double?
    public var longitude: Double?
    public var screenCaptureMarker = false
    public var hasCameraEXIF = false
    /// Audio files' tags and stream (R-4205).
    public var audio: AudioTags?
    /// A Live Photo's content identifier, shared by its still and its clip (R-4206).
    public var contentIdentifier: String?

    public init() {}

    public var orientation: Orientation? {
        guard let w = pixelWidth, let h = pixelHeight, w > 0, h > 0 else { return nil }
        let ratio = Double(w) / Double(h)
        return ratio > 1.05 ? .landscape : ratio < 0.95 ? .portrait : .square
    }

    /// Width over height.
    public var aspectRatio: Double? {
        guard let w = pixelWidth, let h = pixelHeight, w > 0, h > 0 else { return nil }
        return Double(w) / Double(h)
    }

    public var pixelCount: Int {
        (pixelWidth ?? 0) * (pixelHeight ?? 0)
    }

    public var camera: String? {
        guard let model = cameraModel?.trimmingCharacters(in: .whitespaces), !model.isEmpty else { return cameraMake }
        guard let make = cameraMake?.trimmingCharacters(in: .whitespaces), !make.isEmpty,
              !model.lowercased().hasPrefix(make.lowercased().split(separator: " ").first.map(String.init) ?? make.lowercased())
        else { return model }
        return "\(make) \(model)"
    }

    public var kind: MediaKind? {
        isAnimated && format?.kind == .image ? .animatedImage : format?.kind
    }
}

public struct ContentLabel: Codable, Sendable, Hashable {
    public var identifier: String
    public var confidence: Float

    public init(identifier: String, confidence: Float) {
        self.identifier = identifier
        self.confidence = confidence
    }

    /// "teddy_bear" → "teddy bear".
    public var displayName: String {
        identifier.replacingOccurrences(of: "_", with: " ")
    }
}

/// A face found in a picture. The box is normalized with the origin at the top left.
public struct FaceBox: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var quality: Float?
    /// Width of the face in pixels of the original image.
    public var pixelSize: Double
    public var yaw: Double?

    public init(x: Double, y: Double, width: Double, height: Double, quality: Float?, pixelSize: Double, yaw: Double?) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.quality = quality
        self.pixelSize = pixelSize
        self.yaw = yaw
    }

    public var area: Double {
        width * height
    }

    /// A stable key for a face within one file, used to tie corrections to it (R-3904).
    public var key: String {
        String(format: "%.2f,%.2f,%.2f", x + width / 2, y + height / 2, width)
    }
}

public struct PlaceName: Codable, Sendable, Hashable {
    public var city: String
    public var region: String?
    public var country: String

    public init(city: String, region: String?, country: String) {
        self.city = city
        self.region = region
        self.country = country
    }

    public var display: String {
        [city, region, country].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ")
    }
}

/// The parts of a metadata file that sorting and search use.
public struct SourceInfo: Codable, Sendable, Hashable {
    public var category: String?
    public var subcategory: String?
    public var username: String?
    public var postID: String?
    public var date: Date?
    public var description: String?
    /// The file's place in its post and the post's size, when the post has several files (Appendix C.4, R-4208).
    public var num: Int?
    public var count: Int?

    public init(category: String? = nil, subcategory: String? = nil, username: String? = nil, postID: String? = nil, date: Date? = nil,
                description: String? = nil, num: Int? = nil, count: Int? = nil)
    {
        self.category = category
        self.subcategory = subcategory
        self.username = username
        self.postID = postID
        self.date = date
        self.description = description
        self.num = num
        self.count = count
    }

    /// The post this file belongs to, when it is one of several (R-4208): its account or site and its id.
    public var postKey: String? {
        guard let postID, (count ?? 1) > 1 else { return nil }
        return "\(sourceName ?? "")\u{0}\(postID)"
    }

    /// "2 of 5" for a file of a post with several files (R-4209).
    public var postPlace: String? {
        guard postKey != nil, let num, let count else { return nil }
        return "\(num) of \(count)"
    }

    /// Reads `<file>.json` next to a media file, if there is one.
    public static func read(sidecarOf file: URL) -> SourceInfo? {
        guard let data = try? Data(contentsOf: Sidecar.sidecarURL(for: file)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func string(_ key: String) -> String? {
            if let s = json[key] as? String, !s.isEmpty {
                return s
            }
            if let n = json[key] as? NSNumber {
                return n.stringValue
            }
            return nil
        }
        return SourceInfo(category: string("category"), subcategory: string("subcategory"), username: string("username"),
                          postID: string("post_shortcode") ?? string("post_id"),
                          date: string("date").flatMap { DateFormats.parseEngineDate($0) },
                          description: string("description") ?? string("content"),
                          num: string("num").flatMap(Int.init), count: string("count").flatMap(Int.init))
    }

    /// "Account" for engine sources, the site for web pages.
    public var sourceName: String? {
        username ?? category
    }
}

public enum ColourName: String, Codable, Sendable, CaseIterable {
    case red, orange, yellow, green, teal, blue, purple, pink, brown, black, grey, white

    public var label: String {
        rawValue.capitalized
    }

    /// The dominant colour of an 8×8 RGB grid (192 values, 0...255), weighted towards colourful cells (R-3606).
    public static func dominant(grid: [UInt8]) -> ColourName? {
        guard grid.count >= 192 else { return nil }
        var weights: [ColourName: Double] = [:]
        for cell in 0 ..< 64 {
            let r = Double(grid[cell * 3]) / 255, g = Double(grid[cell * 3 + 1]) / 255, b = Double(grid[cell * 3 + 2]) / 255
            let maxV = max(r, g, b), minV = min(r, g, b)
            let value = maxV, saturation = maxV == 0 ? 0 : (maxV - minV) / maxV
            if saturation < 0.18 || value < 0.12 {
                let name: ColourName = value < 0.22 ? .black : value > 0.82 ? .white : .grey
                weights[name, default: 0] += 0.45
                continue
            }
            var hue: Double
            let delta = maxV - minV
            if maxV == r {
                hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxV == g {
                hue = 60 * ((b - r) / delta + 2)
            } else {
                hue = 60 * ((r - g) / delta + 4)
            }
            if hue < 0 {
                hue += 360
            }
            let name: ColourName = switch hue {
            case 15 ..< 45 where value < 0.62: .brown
            case 15 ..< 42: .orange
            case 42 ..< 68: .yellow
            case 68 ..< 165: .green
            case 165 ..< 195: .teal
            case 195 ..< 258: .blue
            case 258 ..< 290: .purple
            case 290 ..< 345: .pink
            default: .red
            }
            weights[name, default: 0] += 0.4 + saturation * value * 1.6
        }
        return weights.max { $0.value < $1.value }?.key
    }
}

/// Everything analysis knows about one file, keyed by its content checksum (D-60).
public struct AnalysisRecord: Codable, Sendable, Hashable {
    /// Bump when a model or rule changes, so files are analysed again in the background (R-3603).
    public static let currentVersion = 1
    /// Bump when reading facts from files changes: facts are read again, no model runs again (R-4210).
    public static let currentFactsVersion = 2

    public var sha256: String
    public var version: Int
    /// Nil for records made before facts had a version of their own.
    public var factsVersion: Int?
    public var facts: MediaFacts
    public var labels: [ContentLabel]
    public var text: String?
    public var place: PlaceName?
    public var isScreenshot: Bool
    public var colour: ColourName?
    public var faces: [FaceBox]
    public var hasEmbedding: Bool
    /// Whether faces were turned into embeddings to recognise people (only after the opt-in, D-61).
    public var peopleChecked = false
    public var analysedAt: Date

    public init(sha256: String, version: Int = AnalysisRecord.currentVersion, facts: MediaFacts, labels: [ContentLabel] = [],
                text: String? = nil, place: PlaceName? = nil, isScreenshot: Bool = false, colour: ColourName? = nil,
                faces: [FaceBox] = [], hasEmbedding: Bool = false, analysedAt: Date = Date())
    {
        self.sha256 = sha256
        self.version = version
        factsVersion = AnalysisRecord.currentFactsVersion
        self.facts = facts
        self.labels = labels
        self.text = text
        self.place = place
        self.isScreenshot = isScreenshot
        self.colour = colour
        self.faces = faces
        self.hasEmbedding = hasEmbedding
        self.analysedAt = analysedAt
    }

    /// Faces large and clear enough to tell people apart (R-3902).
    public var recognisableFaces: [FaceBox] {
        faces.filter { $0.pixelSize >= FaceRules.minimumPixels }
    }
}

public extension String {
    /// The text without surrounding spaces, or nil when nothing is left.
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// What an audio file says about itself (R-4205).
public struct AudioTags: Codable, Sendable, Hashable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var year: Int?
    public var genre: String?
    public var track: Int?
    public var codec: String?
    /// Bits per second.
    public var bitrate: Int?
    /// A hash of the audio stream alone, so the same sound with other tags is found (R-4205); nil until computed.
    public var streamHash: String?

    public init() {}

    public var isEmpty: Bool { [title, artist, album, albumArtist, genre].allSatisfy { $0 == nil } && year == nil && track == nil }
}

public enum FaceRules {
    /// Smaller faces still count for the face filters but are not used to recognise people (benchmark: no loss down to about 28 px).
    public static let minimumPixels: Double = 32
    /// A portrait has one face covering at least this share of the picture (R-3703).
    public static let portraitArea = 0.10
    public static let groupCount = 3
}

// MARK: Screenshots (R-3604)

public enum ScreenshotRule {
    /// Common screen sizes in pixels (shorter side, longer side), at the scales screens actually use.
    static let screens: Set<[Int]> = {
        let base: [[Int]] = [
            [800, 1280], [900, 1440], [982, 1512], [1117, 1728], [1050, 1680], [1080, 1920], [1200, 1920], [1440, 2560], [1600, 2560],
            [1800, 2880], [1964, 3024], [2234, 3456], [2160, 3840], [2880, 5120], [3384, 6016], [768, 1366], [864, 1536], [1024, 1280],
            [640, 1136], [750, 1334], [828, 1792], [1125, 2436], [1170, 2532], [1179, 2556], [1206, 2622], [1242, 2688], [1284, 2778],
            [1290, 2796], [1320, 2868], [1242, 2208], [1080, 2340], [1080, 2400], [1440, 3200], [1440, 3120], [1080, 2280],
            [1536, 2048], [1620, 2160], [1640, 2360], [1668, 2388], [1668, 2224], [2048, 2732], [1488, 2266], [2064, 2752],
        ]
        var all = Set(base)
        for size in base {
            all.insert(size.map { $0 / 2 })
        }
        return all
    }()

    public static func isScreenshot(facts: MediaFacts, fileName: String) -> Bool {
        if facts.screenCaptureMarker {
            return true
        }
        let name = fileName.lowercased()
        if name.hasPrefix("screenshot") || name.hasPrefix("screen shot") || name.contains(" screenshot ") {
            return true
        }
        guard !facts.hasCameraEXIF, let format = facts.format, [.png, .heic].contains(format),
              let w = facts.pixelWidth, let h = facts.pixelHeight else { return false }
        return screens.contains([min(w, h), max(w, h)])
    }
}

// MARK: Dates

public enum MediaDates {
    /// The date used for sorting: the capture date, then the metadata file's date, then the file's creation date (R-3702).
    public static func effective(facts: MediaFacts?, source: SourceInfo?, created: Date?, modified: Date) -> Date {
        facts?.captureDate ?? source?.date ?? created ?? modified
    }
}
