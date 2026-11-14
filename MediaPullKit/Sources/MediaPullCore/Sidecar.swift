import Foundation

/// The JSON sidecar written next to each file in the Archive layout: a gallery-dl-compatible
/// metadata record (SPEC section 15.3, Appendix C). It is a closed set of fields, so nothing an
/// engine or page reports can leak into it by accident.
public struct Sidecar: Encodable, Equatable, Sendable {
    public var category: String
    public var subcategory: String
    public var username: String
    public var author: String?
    public var postShortcode: String?
    public var postID: String
    public var num: Int?
    public var count: Int?
    public var date: Date?
    public var description: String?
    public var postURL: String?
    public var pageURL: String?
    public var sourceURL: String?
    public var width: Int?
    public var height: Int?
    public var originalWidth: Int?
    public var originalHeight: Int?
    public var duration: Double?
    public var ownerUsername: String?
    public var highlightTitle: String?
    public var productType: String?
    public var sha256: String?
    public var extractor: String?
    public var mediapullVersion: String?
    public var higherResolutionAvailable: String?

    public init(category: String, subcategory: String, username: String, postID: String) {
        self.category = category
        self.subcategory = subcategory
        self.username = username
        self.postID = postID
    }

    enum CodingKeys: String, CodingKey {
        case category, subcategory, username, author, num, count, date, description, width, height, duration, sha256, extractor
        case postShortcode = "post_shortcode"
        case postID = "post_id"
        case postURL = "post_url"
        case pageURL = "page_url"
        case sourceURL = "source_url"
        case originalWidth = "original_width"
        case originalHeight = "original_height"
        case ownerUsername = "owner_username"
        case highlightTitle = "highlight_title"
        case productType = "product_type"
        case mediapullVersion = "mediapull_version"
        case higherResolutionAvailable = "higher_res_available"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(category, forKey: .category)
        try container.encode(subcategory, forKey: .subcategory)
        try container.encode(username, forKey: .username)
        try container.encode(postID, forKey: .postID)
        try container.encodeIfPresent(author?.nonEmpty, forKey: .author)
        try container.encodeIfPresent(postShortcode?.nonEmpty, forKey: .postShortcode)
        if let num, let count {
            try container.encode(num, forKey: .num)
            try container.encode(count, forKey: .count)
        }
        try container.encodeIfPresent(date.map(DateFormats.sidecarString), forKey: .date)
        try container.encodeIfPresent(description?.nonEmpty, forKey: .description)
        try container.encodeIfPresent(postURL, forKey: .postURL)
        try container.encodeIfPresent(pageURL, forKey: .pageURL)
        try container.encodeIfPresent(sourceURL, forKey: .sourceURL)
        try container.encodeIfPresent(width, forKey: .width)
        try container.encodeIfPresent(height, forKey: .height)
        try container.encodeIfPresent(originalWidth, forKey: .originalWidth)
        try container.encodeIfPresent(originalHeight, forKey: .originalHeight)
        try container.encodeIfPresent(duration.map { ($0 * 1000).rounded() / 1000 }, forKey: .duration)
        try container.encodeIfPresent(ownerUsername?.nonEmpty, forKey: .ownerUsername)
        try container.encodeIfPresent(highlightTitle?.nonEmpty, forKey: .highlightTitle)
        try container.encodeIfPresent(productType?.nonEmpty, forKey: .productType)
        try container.encodeIfPresent(sha256, forKey: .sha256)
        try container.encodeIfPresent(extractor, forKey: .extractor)
        try container.encodeIfPresent(mediapullVersion, forKey: .mediapullVersion)
        try container.encodeIfPresent(higherResolutionAvailable, forKey: .higherResolutionAvailable)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    public static func sidecarURL(for media: URL) -> URL {
        media.deletingLastPathComponent().appendingPathComponent(media.lastPathComponent + ".json")
    }
}

public extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : self
    }
}

public enum ShortHash {
    /// A stable, short identifier for a string (FNV-1a 64, hex), used for web page ids.
    public static func of(_ text: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016llx", hash).prefix(12).description
    }
}
