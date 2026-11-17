import Foundation

/// Which Instagram item a file in a folder is, in the forms the bridge knows (D-79): `ig:<media_id>` (the engine's own key)
/// and, for a post's file, `igp:<post_id>:<num>`. A file is recognised from its name when MediaPull named it, and from its
/// metadata file otherwise, so a folder MediaPull has no record of is still understood.
public enum InstagramIdentity {
    /// The identities of one file. `metadata` is its metadata file, when there is one and the name did not say enough.
    public static func identities(fileName: String, metadata: [String: Any]? = nil) -> Set<String> {
        var out = Set<String>()
        let stem = Self.stemWithoutNumbering((fileName as NSString).deletingPathExtension)
        if let code = archiveCode(stem) {
            out.formUnion(mediaIdentities(code: code))
        } else {
            for code in plainCodes(stem) {
                out.formUnion(mediaIdentities(code: code))
            }
        }
        if let metadata, (metadata["category"] as? String) == "instagram" {
            if let media = string(metadata["media_id"]) { out.insert("ig:\(media)") }
            let subcategory = metadata["subcategory"] as? String
            if ["posts", "reels"].contains(subcategory), let post = string(metadata["post_id"]), let num = metadata["num"] as? Int {
                out.insert("igp:\(post):\(num)")
            }
        }
        return out
    }

    /// Whether `identities(fileName:)` can tell this file without its metadata file.
    public static func nameSuffices(_ fileName: String) -> Bool {
        archiveCode(stemWithoutNumbering((fileName as NSString).deletingPathExtension)) != nil
    }

    /// "name 2" (a collision number) is the same item as "name".
    static func stemWithoutNumbering(_ stem: String) -> String {
        guard let range = stem.range(of: #" \d+$"#, options: .regularExpression) else { return stem }
        return String(stem[..<range.lowerBound])
    }

    /// `YYYY-MM-DD_HHMMSS_<code>_<NN>`, the archive name of an Instagram file (Naming.archiveEngine).
    static func archiveCode(_ stem: String) -> String? {
        guard let match = stem.range(of: #"^\d{4}-\d{2}-\d{2}_\d{6}_(.+)_\d{2,}$"#, options: .regularExpression) else { return nil }
        let body = stem[match]
        let afterDate = body.dropFirst(18)
        guard let last = afterDate.lastIndex(of: "_") else { return nil }
        let code = String(afterDate[..<last])
        return code.isEmpty || code == "avatar" ? nil : code
    }

    /// `<username>_<code>_<NN>`, the Plain name of an Instagram file; usernames and codes can both hold "_", so every
    /// split is tried and only codes that decode to a plausible media id are kept.
    static func plainCodes(_ stem: String) -> [String] {
        guard let last = stem.lastIndex(of: "_"), stem[stem.index(after: last)...].allSatisfy(\.isNumber),
              stem.distance(from: last, to: stem.endIndex) >= 3 else { return [] }
        let rest = stem[..<last]
        var codes: [String] = []
        var index = rest.startIndex
        while let underscore = rest[index...].firstIndex(of: "_") {
            let code = String(rest[rest.index(after: underscore)...])
            if let id = InstagramIDs.id(fromShortcode: code), let value = UInt64(id), value >= 100_000_000_000_000 {
                codes.append(code)
            }
            index = rest.index(after: underscore)
        }
        return codes
    }

    /// A media's code is its id in Instagram's base-64 alphabet; a numeric code is the id itself.
    static func mediaIdentities(code: String) -> Set<String> {
        var out = Set<String>()
        if code.allSatisfy(\.isNumber) { out.insert("ig:\(code)") }
        if let id = InstagramIDs.id(fromShortcode: code) { out.insert("ig:\(id)") }
        return out
    }

    static func string(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
