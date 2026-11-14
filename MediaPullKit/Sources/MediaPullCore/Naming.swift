import Foundation

/// Values a name template can use.
public struct NameContext: Sendable {
    public var date: Date
    public var code: String?
    public var postID: String?
    public var mediaID: String?
    public var num: Int?
    public var count: Int?
    public var username: String?
    public var host: String?
    public var title: String?
    public var originalName: String?
    public var index: Int
    public var hash: String?
    public var width: Int?
    public var height: Int?

    public init(date: Date, index: Int) {
        self.date = date
        self.index = index
    }
}

public struct NameTemplate: Codable, Hashable, Sendable {
    public var pattern: String

    public init(_ pattern: String) {
        self.pattern = pattern
    }

    public static let archiveEngine = NameTemplate("{yyyy}-{MM}-{dd}_{HH}{mm}{ss}_{code}_{num:02}")
    public static let archiveAvatar = NameTemplate("{yyyy}-{MM}-{dd}_{HH}{mm}{ss}_avatar")
    public static let archiveWeb = NameTemplate("{yyyy}-{MM}-{dd}_{HH}{mm}{ss}_{index:04}_{orig_name}")
    public static let plain = NameTemplate("{orig_name}")

    public static let tokens = [
        "yyyy", "MM", "dd", "HH", "mm", "ss", "date:<format>", "code", "shortcode", "post_id", "media_id", "num", "num:02",
        "count", "username", "host", "title", "orig_name", "index:04", "hash8", "w", "h",
    ]

    /// The file name stem (no extension) for `context`.
    public func render(_ context: NameContext) -> String {
        var output = ""
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "{", let close = pattern[index...].firstIndex(of: "}") {
                let token = String(pattern[pattern.index(after: index) ..< close])
                output += value(for: token, context)
                index = pattern.index(after: close)
            } else {
                output.append(character)
                index = pattern.index(after: index)
            }
        }
        return output
    }

    private func value(for token: String, _ context: NameContext) -> String {
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts.first ?? ""
        let format = parts.count > 1 ? parts[1] : nil
        func padded(_ number: Int?) -> String {
            guard let number else { return "" }
            if let format, let width = Int(format) { return String(format: "%0\(width)d", number) }
            return String(number)
        }
        switch name {
        case "yyyy", "MM", "dd", "HH", "mm", "ss": return DateFormats.utc(name).string(from: context.date)
        case "date": return DateFormats.utc(format ?? "yyyy-MM-dd").string(from: context.date)
        case "code": return context.code ?? context.mediaID ?? context.postID ?? context.hash ?? "item"
        case "shortcode": return context.code ?? ""
        case "post_id": return context.postID ?? ""
        case "media_id": return context.mediaID ?? ""
        case "num": return padded(context.num ?? 1)
        case "count": return padded(context.count ?? 1)
        case "username": return context.username ?? ""
        case "host": return context.host ?? ""
        case "title": return context.title ?? ""
        case "orig_name": return context.originalName ?? context.hash ?? "media"
        case "index": return padded(context.index)
        case "hash8": return String((context.hash ?? "").prefix(8))
        case "w": return context.width.map(String.init) ?? ""
        case "h": return context.height.map(String.init) ?? ""
        default: return ""
        }
    }

    /// Problems with this template for the Archive layout (SPEC R-1503, R-1504), empty when valid.
    public func archiveProblems() -> [String] {
        var problems: [String] = []
        var context = NameContext(date: Date(timeIntervalSince1970: 1_700_000_000), index: 7)
        context.code = "Cabc123"
        context.num = 1
        context.originalName = "photo"
        let sample = render(context)
        if sample.range(of: #"^\d{4}-\d{2}-\d{2}_"#, options: .regularExpression) == nil {
            problems.append("Archive names must start with the date, as yyyy-MM-dd_.")
        }
        if FileNaming.isForbiddenArchiveName(sample) {
            problems.append("This pattern produces names that other tools mistake for a different downloader's layout.")
        }
        return problems
    }
}

public enum DateFormats {
    /// UTC, POSIX locale, Gregorian calendar: independent of the user's settings (SPEC R-1508).
    public static func utc(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    public static func sidecarString(_ date: Date) -> String {
        utc("yyyy-MM-dd HH:mm:ss").string(from: date)
    }

    public static func parseEngineDate(_ text: String) -> Date? {
        if let date = utc("yyyy-MM-dd HH:mm:ss").date(from: text) { return date }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        return utc("yyyy-MM-dd'T'HH:mm:ss").date(from: text)
    }
}

public enum FileNaming {
    static let forbidden = try? NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_UTC"#)
    public static let reservedFolders: Set<String> = ["media", "your_instagram_activity"]

    public static func isForbiddenArchiveName(_ name: String) -> Bool {
        guard let forbidden else { return false }
        return forbidden.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    /// A safe file or folder name: NFC, no separators or control characters, no leading dot,
    /// and at most `maxBytes` bytes of UTF-8.
    public static func sanitize(_ name: String, maxBytes: Int = 200) -> String {
        var result = name.precomposedStringWithCanonicalMapping
        let banned = CharacterSet(charactersIn: "/:\\\0").union(.controlCharacters).union(.newlines)
        result = String(result.unicodeScalars.map { banned.contains($0) ? "_" : Character($0) })
        result = result.replacingOccurrences(of: "\u{200B}", with: "")
        result = result.trimmingCharacters(in: .whitespaces)
        while result.hasPrefix(".") { result.removeFirst() }
        while result.utf8.count > maxBytes { result.removeLast() }
        result = result.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "untitled" : result
    }

    /// A first-level folder name that never collides with a reserved name (SPEC R-1505).
    public static func safeTopFolder(_ name: String) -> String {
        let clean = sanitize(name, maxBytes: 120)
        return reservedFolders.contains(clean.lowercased()) ? "_" + clean : clean
    }

    /// The full file name for `stem` and `ext`, short enough that adding ".json" fits in 255 bytes.
    public static func fileName(stem: String, ext: String) -> String {
        let budget = 255 - ".json".utf8.count - ext.utf8.count - 1
        var clean = sanitize(stem, maxBytes: budget)
        if clean.isEmpty { clean = "media" }
        return ext.isEmpty ? clean : "\(clean).\(ext)"
    }
}

public enum SaveLayout: String, Codable, Sendable, CaseIterable {
    case archive
    case plain

    public var label: String {
        switch self {
        case .archive: "Archive (with metadata)"
        case .plain: "Plain files"
        }
    }

    public var shortLabel: String {
        switch self {
        case .archive: "Archive"
        case .plain: "Plain"
        }
    }

    /// Output types allowed in this layout (SPEC R-1502).
    public func allows(_ format: MediaFormat) -> Bool {
        switch self {
        case .archive: [.jpeg, .png, .gif, .mp4, .mov].contains(format)
        case .plain: true
        }
    }
}

public enum ConflictPolicy: String, Codable, Sendable, CaseIterable {
    case number, skip

    public var label: String {
        switch self {
        case .number: "Add a number"
        case .skip: "Skip"
        }
    }
}
