import Foundation

/// A file's edits in Edit/Frame (section 46, D-127): the original is never changed; this recipe is applied when shown and
/// when exported. Every field has a neutral default, and older or partial recipes read over a blank one (`LenientJSON`).
public struct EditRecipe: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var source: EditSource
    public var modified: Date
    public var geometry = EditGeometry()
    public var adjust = Adjustments()
    public var look: Look?
    public var frame: Frame?
    public var layers: [Layer] = []
    public var timeline: EditTimeline?
    /// Audio tags and artwork to change (R-4610).
    public var tags: AudioTagEdit?
    public var export = ExportSettings()

    public init(id: UUID = UUID(), source: EditSource, modified: Date = Date()) {
        self.id = id
        self.source = source
        self.modified = modified
    }

    /// Whether anything is edited (a blank recipe is not kept).
    public var isEdited: Bool {
        geometry != EditGeometry() || adjust != Adjustments() || look != nil || frame != nil || !layers.isEmpty
            || (timeline.map { $0 != EditTimeline() } ?? false) || (tags.map { $0 != AudioTagEdit() } ?? false)
    }

    /// Reads a stored recipe; a missing field, at any depth, falls back to its neutral value, so a recipe written before a
    /// field was added still reads whole.
    public static func decode(_ data: Data) -> EditRecipe? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let source = object["source"] as? [String: Any], let path = source["path"] as? String,
              let kindText = source["kind"] as? String, let kind = MediaKind(rawValue: kindText)
        else { return nil }
        let blank = EditRecipe(id: (object["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(),
                               source: EditSource(path: path, kind: kind))
        guard let filled = try? JSONSerialization.data(withJSONObject: Self.filled(object)) else { return nil }
        return LenientJSON.decode(EditRecipe.self, from: filled, over: blank)
    }

    /// The stored object with each nested part laid over its own neutral value (the blank recipe has none of them).
    static func filled(_ object: [String: Any]) -> [String: Any] {
        func json(_ value: some Encodable) -> [String: Any] {
            (try? JSONEncoder().encode(value)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        }
        func over(_ saved: Any?, _ base: [String: Any], without: [String] = []) -> Any? {
            guard let saved = saved as? [String: Any] else { return saved }
            var base = base
            // An enum's own case comes from what was saved (both would make two cases); kept from the base otherwise.
            for key in without where saved[key] != nil {
                base[key] = nil
            }
            return LenientJSON.overlay(saved, on: base)
        }
        var out = object
        out["frame"] = over(object["frame"], json(Frame()), without: ["background"])
        out["look"] = over(object["look"], json(Look(name: .mono)), without: ["name"])
        out["timeline"] = over(object["timeline"], json(EditTimeline()))
        out["tags"] = over(object["tags"], json(AudioTagEdit()))
        if let layers = object["layers"] as? [[String: Any]] {
            out["layers"] = layers.map { saved -> [String: Any] in
                var layer = (over(saved, json(Layer(kind: .shape(LayerShape()))), without: ["kind"]) as? [String: Any]) ?? saved
                if var kind = saved["kind"] as? [String: Any] {
                    if let text = (kind["text"] as? [String: Any])?["_0"] {
                        kind["text"] = ["_0": over(text, json(TextStyle(text: "")))]
                    } else if let shape = (kind["shape"] as? [String: Any])?["_0"] {
                        kind["shape"] = ["_0": over(shape, json(LayerShape()))]
                    }
                    layer["kind"] = kind
                }
                return layer
            }
        }
        return out
    }
}

/// The file a recipe belongs to: where it was, a reference that follows it through renames and moves on its disk, and
/// the file's creation date when the recipe was made, so another file later given the same name does not take its edits
/// (a metadata edit keeps the creation date, D-125; a different file has its own).
public struct EditSource: Codable, Sendable, Hashable {
    public var path: String
    public var reference: String?
    public var created: Date?
    public var kind: MediaKind

    public init(path: String, reference: String? = nil, created: Date? = nil, kind: MediaKind) {
        self.path = path
        self.reference = reference
        self.created = created
        self.kind = kind
    }
}

// MARK: Geometry (R-4604)

public struct EditGeometry: Codable, Sendable, Hashable {
    /// The part kept, in units of the turned and straightened picture (origin top left); nil keeps all of it.
    public var crop: UnitRect?
    /// The crop's shape, kept so a change of size keeps it.
    public var aspect: EditAspect = .free
    /// Degrees, −45 to 45; the picture is cropped to the largest rectangle that fits inside the turned one.
    public var straighten: Double = 0
    /// Quarter turns clockwise, 0 to 3.
    public var quarterTurns = 0
    public var flipped = false

    public init() {}

    /// Width over height of the picture once turned (before cropping), for a source of `size`.
    public func turnedSize(_ size: CGSize) -> CGSize {
        quarterTurns % 2 == 0 ? size : CGSize(width: size.height, height: size.width)
    }

    /// The largest rectangle with the turned picture's proportions that fits inside it once rotated by `degrees`, as a
    /// scale of the picture (1 when not straightened).
    public static func straightenScale(width: Double, height: Double, degrees: Double) -> Double {
        let angle = abs(degrees) * .pi / 180
        guard angle > 0, width > 0, height > 0 else { return 1 }
        let (sin, cos) = (Foundation.sin(angle), Foundation.cos(angle))
        // The rotated picture's bounding box must contain the original-proportioned rectangle scaled by s.
        let scaleW = width / (width * cos + height * sin)
        let scaleH = height / (width * sin + height * cos)
        return min(scaleW, scaleH)
    }
}

/// A rectangle in units of a picture (0 to 1), origin top left.
public struct UnitRect: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let whole = UnitRect(x: 0, y: 0, width: 1, height: 1)

    /// Kept inside the picture and at least 1 % of it.
    public var clamped: UnitRect {
        let w = min(max(width, 0.01), 1), h = min(max(height, 0.01), 1)
        return UnitRect(x: min(max(x, 0), 1 - w), y: min(max(y, 0), 1 - h), width: w, height: h)
    }

    /// The largest centred rectangle of `ratio` (width over height, in pixels) inside a picture of `size`.
    public static func centred(ratio: Double, in size: CGSize) -> UnitRect {
        guard ratio > 0, size.width > 0, size.height > 0 else { return .whole }
        let pictureRatio = size.width / size.height
        if ratio > pictureRatio {
            let h = pictureRatio / ratio
            return UnitRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
        }
        let w = ratio / pictureRatio
        return UnitRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
    }
}

public enum EditAspect: String, Codable, Sendable, CaseIterable {
    case free, original, square, portrait45, portrait34, portrait23, landscape32, landscape169, portrait916

    public var label: String {
        switch self {
        case .free: "Free"
        case .original: "Original"
        case .square: "Square"
        case .portrait45: "4:5"
        case .portrait34: "3:4"
        case .portrait23: "2:3"
        case .landscape32: "3:2"
        case .landscape169: "16:9"
        case .portrait916: "9:16"
        }
    }

    /// Width over height, or nil for free; `original` is the picture's own.
    public func ratio(original: Double) -> Double? {
        switch self {
        case .free: nil
        case .original: original
        case .square: 1
        case .portrait45: 4.0 / 5
        case .portrait34: 3.0 / 4
        case .portrait23: 2.0 / 3
        case .landscape32: 3.0 / 2
        case .landscape169: 16.0 / 9
        case .portrait916: 9.0 / 16
        }
    }
}

// MARK: Adjustments and looks (R-4603)

/// Each value is neutral at 0; Exposure is in stops (−5 to 5), the rest run from −100 to 100 (Clarity, Sharpen,
/// Vignette and Grain from 0 to 100).
public struct Adjustments: Codable, Sendable, Hashable {
    public var exposure: Double = 0
    public var contrast: Double = 0
    public var highlights: Double = 0
    public var shadows: Double = 0
    public var whites: Double = 0
    public var blacks: Double = 0
    public var temperature: Double = 0
    public var tint: Double = 0
    public var vibrance: Double = 0
    public var saturation: Double = 0
    public var clarity: Double = 0
    public var sharpen: Double = 0
    public var vignette: Double = 0
    public var grain: Double = 0

    public init() {}

    public enum Key: String, CaseIterable, Sendable {
        case exposure, contrast, highlights, shadows, whites, blacks, temperature, tint, vibrance, saturation
        case clarity, sharpen, vignette, grain

        public var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

        public var range: ClosedRange<Double> {
            switch self {
            case .exposure: -5 ... 5
            case .clarity, .sharpen, .vignette, .grain: 0 ... 100
            default: -100 ... 100
            }
        }

        public var group: String {
            switch self {
            case .exposure, .contrast, .highlights, .shadows, .whites, .blacks: "Light"
            case .temperature, .tint, .vibrance, .saturation: "Colour"
            case .clarity, .sharpen, .vignette, .grain: "Effects"
            }
        }

        var path: WritableKeyPath<Adjustments, Double> {
            switch self {
            case .exposure: \.exposure
            case .contrast: \.contrast
            case .highlights: \.highlights
            case .shadows: \.shadows
            case .whites: \.whites
            case .blacks: \.blacks
            case .temperature: \.temperature
            case .tint: \.tint
            case .vibrance: \.vibrance
            case .saturation: \.saturation
            case .clarity: \.clarity
            case .sharpen: \.sharpen
            case .vignette: \.vignette
            case .grain: \.grain
            }
        }
    }

    public subscript(key: Key) -> Double {
        get { self[keyPath: key.path] }
        set { self[keyPath: key.path] = min(max(newValue, key.range.lowerBound), key.range.upperBound) }
    }
}

public struct Look: Codable, Sendable, Hashable {
    public var name: LookName
    /// 0 to 1.
    public var amount: Double = 1

    public init(name: LookName, amount: Double = 1) {
        self.name = name
        self.amount = amount
    }
}

public enum LookName: String, Codable, Sendable, CaseIterable {
    case mono, noir, silvertone, film, fade, warm, cool, vivid, chrome, instant

    public var label: String {
        switch self {
        case .mono: "Mono"
        case .noir: "Noir"
        case .silvertone: "Silvertone"
        case .film: "Film"
        case .fade: "Fade"
        case .warm: "Warm"
        case .cool: "Cool"
        case .vivid: "Vivid"
        case .chrome: "Chrome"
        case .instant: "Instant"
        }
    }
}

// MARK: Frame and layers (R-4605, R-4606)

/// An sRGB colour with alpha, each 0 to 1.
public struct EditColor: Codable, Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double = 1

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let white = EditColor(red: 1, green: 1, blue: 1)
    public static let black = EditColor(red: 0, green: 0, blue: 0)
}

public struct Frame: Codable, Sendable, Hashable {
    public enum Shape: String, Codable, Sendable, CaseIterable {
        /// The photo's own shape, grown by the insets.
        case photo
        /// The canvas keeps the photo's proportions, with the photo inset inside it.
        case photoShape
        case square, portrait45, story916, landscape32, portrait23

        public var label: String {
            switch self {
            case .photo: "Photo with Border"
            case .photoShape: "Photo's Own Shape"
            case .square: "1:1"
            case .portrait45: "4:5"
            case .story916: "9:16"
            case .landscape32: "3:2"
            case .portrait23: "2:3"
            }
        }

        /// Width over height, nil for the photo's own shape plus its border.
        public var ratio: Double? {
            switch self {
            case .photo, .photoShape: nil
            case .square: 1
            case .portrait45: 4.0 / 5
            case .story916: 9.0 / 16
            case .landscape32: 3.0 / 2
            case .portrait23: 2.0 / 3
            }
        }
    }

    public enum Background: Codable, Sendable, Hashable {
        case color(EditColor)
        case blurredPhoto
        case gradient(EditColor, EditColor)
    }

    public var shape: Shape = .photo
    public var background: Background = .color(.white)
    /// The photo's inset from each edge, as a share of the canvas's shorter side (0 to 0.4).
    public var top: Double = 0.05
    public var left: Double = 0.05
    public var right: Double = 0.05
    public var bottom: Double = 0.05
    /// As a share of the photo's shorter side (0 to 0.5).
    public var cornerRadius: Double = 0
    public var shadow = false
    /// For a fixed shape: the photo fills the space inside the insets, its centre kept (a poster), instead of fitting in it.
    public var fill = false

    public init() {}
}

public struct Layer: Codable, Sendable, Hashable, Identifiable {
    public var id = UUID()
    public var kind: Kind
    /// Centre, width and height in units of the canvas (0 to 1, origin top left); may reach past the photo onto the border.
    public var x: Double = 0.5
    public var y: Double = 0.5
    public var width: Double = 0.6
    public var height: Double = 0.15
    /// Degrees, clockwise.
    public var rotation: Double = 0
    public var opacity: Double = 1
    public var hidden = false

    public init(kind: Kind) {
        self.kind = kind
    }

    public enum Kind: Codable, Sendable, Hashable {
        case text(TextStyle)
        case shape(LayerShape)
        case image(path: String)
    }

    public var label: String {
        switch kind {
        case let .text(style): style.text.split(separator: "\n").first.map(String.init) ?? "Text"
        case let .shape(style): style.kind.label
        case let .image(path): (path as NSString).lastPathComponent
        }
    }
}

public struct TextStyle: Codable, Sendable, Hashable {
    public var text: String
    /// A family name; `face` picks a style in it ("Bold"), nil for its regular face.
    public var family: String = "Helvetica Neue"
    public var face: String?
    /// The size of a capital letter as a share of the canvas's height.
    public var size: Double = 0.06
    public var color: EditColor = .white
    public enum Alignment: String, Codable, Sendable, CaseIterable { case left, center, right }
    public var alignment: Alignment = .left
    /// Extra space between letters, as a share of the size.
    public var tracking: Double = 0
    /// Line height as a multiple of the size.
    public var lineHeight: Double = 1.1
    public var uppercase = false
    public var shadow = false
    public var outline: EditColor?

    public init(text: String) {
        self.text = text
    }
}

public struct LayerShape: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case rectangle, ellipse, line

        public var label: String { rawValue.capitalized }
    }

    public var kind: Kind = .rectangle
    public var color: EditColor = .white
    public var filled = true
    /// Outline or line width as a share of the canvas's shorter side.
    public var lineWidth: Double = 0.004

    public init(kind: Kind = .rectangle) {
        self.kind = kind
    }
}

// MARK: Time (video and audio, R-4609, R-4610)

public struct EditTimeline: Codable, Sendable, Hashable {
    /// The parts kept, in seconds of the original, in order; empty keeps all of it.
    public var kept: [TimeRange] = []
    /// 0.25 to 4.
    public var speed: Double = 1
    public var fadeIn: Double = 0
    public var fadeOut: Double = 0
    /// Linear gain, 0 to 4 (1 unchanged; 0 is mute).
    public var volume: Double = 1
    public var normalize = false

    public init() {}

    /// The kept parts inside `duration`, merged and ordered; the whole when none are set.
    public func keptRanges(duration: Double) -> [TimeRange] {
        guard duration > 0 else { return [] }
        let parts = kept.isEmpty ? [TimeRange(start: 0, end: duration)] : kept
        let clamped = parts.map { TimeRange(start: max(0, min($0.start, duration)), end: max(0, min($0.end, duration))) }
            .filter { $0.end - $0.start > 0.001 }
            .sorted { $0.start < $1.start }
        var merged: [TimeRange] = []
        for part in clamped {
            // Overlapping parts join; parts that only touch stay apart (Split Here makes them).
            if let last = merged.last, part.start < last.end {
                merged[merged.count - 1].end = max(last.end, part.end)
            } else {
                merged.append(part)
            }
        }
        return merged
    }

    /// How long the result is.
    public func resultDuration(of duration: Double) -> Double {
        keptRanges(duration: duration).reduce(0) { $0 + $1.end - $1.start } / min(max(speed, 0.25), 4)
    }

    /// Whether only cuts are asked for, which never needs re-encoding (D-130).
    public var cutsOnly: Bool {
        speed == 1 && fadeIn == 0 && fadeOut == 0 && (volume == 1 || volume == 0) && !normalize
    }
}

public struct TimeRange: Codable, Sendable, Hashable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

// MARK: Audio (R-4610)

/// Tag changes for an audio export: nil leaves a tag as it is, an empty text removes it.
public struct AudioTagEdit: Codable, Sendable, Hashable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var year: String?
    public var genre: String?
    public var track: String?
    /// A picture file to use as the artwork.
    public var artworkPath: String?
    public var removeArtwork = false

    public init() {}

    /// ffmpeg's metadata keys with their new values.
    public var metadata: [(key: String, value: String)] {
        [("title", title), ("artist", artist), ("album", album), ("album_artist", albumArtist), ("date", year), ("genre", genre),
         ("track", track)].compactMap { key, value in value.map { (key, $0.trimmingCharacters(in: .whitespacesAndNewlines)) } }
    }
}

/// What an audio export is written as.
public enum AudioOutput: String, Codable, Sendable, CaseIterable {
    case mp3, aac, alac, flac, wav, aiff

    public var label: String {
        switch self {
        case .mp3: "MP3"
        case .aac: "M4A (AAC)"
        case .alac: "M4A (Apple Lossless)"
        case .flac: "FLAC"
        case .wav: "WAV"
        case .aiff: "AIFF"
        }
    }

    public var fileExtension: String {
        switch self {
        case .mp3: "mp3"
        case .aac, .alac: "m4a"
        case .flac: "flac"
        case .wav: "wav"
        case .aiff: "aiff"
        }
    }

    /// Whether a picture can be stored with it.
    public var holdsArtwork: Bool { [.mp3, .aac, .alac, .flac].contains(self) }

    /// The output like the original where MediaPull can write that format; Ogg and Opus become AAC. An M4A holding
    /// Apple Lossless (`codec` "alac") stays lossless.
    public static func like(_ fileExtension: String, codec: String? = nil) -> AudioOutput {
        if codec?.lowercased() == "alac" { return .alac }
        switch fileExtension.lowercased() {
        case "mp3": return .mp3
        case "flac": return .flac
        case "wav": return .wav
        case "aif", "aiff", "aifc": return .aiff
        default: return .aac
        }
    }
}

// MARK: Export (R-4608)

public struct ExportSettings: Codable, Sendable, Hashable {
    public enum PhotoFormat: String, Codable, Sendable, CaseIterable {
        case jpeg, heic, png

        public var label: String { rawValue.uppercased() }
        public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    }

    public enum Size: String, Codable, Sendable, CaseIterable {
        case original, long1080, long2048, long4096, post45, square, story

        public var label: String {
            switch self {
            case .original: "Original Size"
            case .long1080: "Long Edge 1080 px"
            case .long2048: "Long Edge 2048 px"
            case .long4096: "Long Edge 4096 px"
            case .post45: "Post (fits 1080 × 1350)"
            case .square: "Square Post (fits 1080 × 1080)"
            case .story: "Story (fits 1080 × 1920)"
            }
        }

        /// The pixel size of a result of `size`: fitted inside the social sizes (never padded), scaled to a long edge, or
        /// as it is. Never larger than the result itself.
        public func pixels(for size: CGSize) -> CGSize {
            func fit(_ box: CGSize) -> CGSize {
                let scale = min(1, min(box.width / size.width, box.height / size.height))
                return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
            }
            guard size.width > 0, size.height > 0 else { return size }
            switch self {
            case .original: return size
            case .long1080: return fit(CGSize(width: 1080, height: 1080))
            case .long2048: return fit(CGSize(width: 2048, height: 2048))
            case .long4096: return fit(CGSize(width: 4096, height: 4096))
            case .post45: return fit(CGSize(width: 1080, height: 1350))
            case .square: return fit(CGSize(width: 1080, height: 1080))
            case .story: return fit(CGSize(width: 1080, height: 1920))
            }
        }
    }

    public enum VideoCodec: String, Codable, Sendable, CaseIterable {
        case hevc, h264

        public var label: String { self == .hevc ? "HEVC" : "H.264" }
    }

    public enum VideoContainer: String, Codable, Sendable, CaseIterable {
        case mp4, mov

        public var label: String { rawValue.uppercased() }
    }

    public var format: PhotoFormat = .jpeg
    public var size: Size = .original
    public var videoCodec: VideoCodec = .hevc
    /// Nil: like the original (a MOV stays MOV, keeping its camera details and ProRes).
    public var videoContainer: VideoContainer?
    /// Nil: like the original (`AudioOutput.like`).
    public var audioFormat: AudioOutput?
    /// 0.5 to 1.
    public var quality: Double = 0.92
    public var displayP3 = false
    public var keepLocation = true
    public var keepCamera = true

    public init() {}
}
