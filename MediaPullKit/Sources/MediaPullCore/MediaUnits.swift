import Foundation

/// What kind of shot a unit is (R-4206).
public enum UnitKind: String, Codable, Sendable, Hashable {
    /// A RAW file with the JPEG, HEIC or HEIF of the same shot.
    case rawPair
    /// A photo with its clip (a Live Photo; a ProRAW Live Photo also has its RAW).
    case live

    public var badge: String {
        switch self {
        case .rawPair: "RAW+JPEG"
        case .live: "LIVE"
        }
    }
}

/// The files of one shot, found by name in one folder and never by reading files (D-120): a RAW leads its JPEG, HEIC or
/// HEIF; a photo leads its MOV; `<name>.xmp`, `<name>.aae` and every member's metadata file come along. Pure, so it is
/// tested without a disk.
public enum MediaUnits {
    static let photoExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "hif"]
    static let clipExtensions: Set<String> = ["mov"]

    /// Whether a file of this name is one shot with others of its name in a folder, or shares their `.xmp`: a photo of
    /// any format (a PNG reads the `.xmp` of its name too), a RAW, a clip, or an edit file (D-120). Audio and other videos
    /// never are, so their names never clash as shots (an MP3 and a FLAC of one song stay as they are).
    public static func takesPartInUnits(_ name: String) -> Bool {
        let e = ext(name)
        return MediaFormat.fromExtension(e)?.kind == .image || MediaFormat.rawExtensions.contains(e) || clipExtensions.contains(e)
            || ["xmp", "aae"].contains(e)
    }
    public static let sideExtensions: Set<String> = ["xmp", "aae"]

    static func stem(_ name: String) -> String { (name as NSString).deletingPathExtension.lowercased() }
    static func ext(_ name: String) -> String { (name as NSString).pathExtension.lowercased() }

    /// A unit found among names: its lead, its members (media only) and its kind.
    public struct Unit: Sendable, Equatable {
        public var lead: String
        public var members: [String]
        public var kind: UnitKind
    }

    /// Every unit among the names of one folder.
    public static func units(in names: [String]) -> [Unit] {
        var byStem: [String: [String]] = [:]
        // Hidden names are not shots, except a unit's files under the temporary names of a rename that swaps names, which
        // must stay one unit through it (audit 2026-11-21-9, A9-1).
        for name in names where !name.hasPrefix(".") || name.hasPrefix(".mediapull-rename-") {
            let e = ext(name)
            guard MediaFormat.rawExtensions.contains(e) || photoExtensions.contains(e) || clipExtensions.contains(e) else { continue }
            byStem[stem(name), default: []].append(name)
        }
        var out: [Unit] = []
        for group in byStem.values where group.count > 1 {
            let sorted = group.sorted()
            let raws = sorted.filter { MediaFormat.rawExtensions.contains(ext($0)) }
            let photos = sorted.filter { photoExtensions.contains(ext($0)) }
            let clips = sorted.filter { clipExtensions.contains(ext($0)) }
            if let lead = raws.first {
                let members = Array(raws.dropFirst()) + photos + clips
                guard !members.isEmpty else { continue }
                out.append(Unit(lead: lead, members: members, kind: clips.isEmpty ? .rawPair : .live))
            } else if let lead = photos.first, !clips.isEmpty {
                out.append(Unit(lead: lead, members: Array(photos.dropFirst()) + clips, kind: .live))
            }
        }
        return out.sorted { $0.lead < $1.lead }
    }

    /// Names that belong to a unit without leading it: hidden from listings, moved with their lead.
    public static func memberNames(in names: [String]) -> Set<String> {
        Set(units(in: names).flatMap(\.members))
    }

    /// Everything that travels with `lead` (its members, its `.xmp` and `.aae`, and the metadata file of each), as names in
    /// the same folder. A file that leads nothing still takes its metadata file and its `.xmp`.
    public static func companions(ofLead lead: String, in names: [String]) -> [String] {
        let present = Set(names)
        let all = units(in: names)
        // A member handled on its own takes only its metadata file: the shot's edit files stay with its lead.
        if all.contains(where: { $0.members.contains(lead) }) { return present.contains(lead + ".json") ? [lead + ".json"] : [] }
        let unit = all.first { $0.lead == lead }
        let members = unit?.members ?? []
        let leadStem = stem(lead)
        var out: [String] = []
        for name in [lead] + members {
            if name != lead { out.append(name) }
            if present.contains(name + ".json") { out.append(name + ".json") }
        }
        // Edit files of the same shot, whatever the case of their names, only while no other shot of the stem stays: an
        // edit file two shots could own stays where it is (R-4502, audit 2026-11-21-14, A14-2).
        let own = Set([lead] + members)
        let otherShot = names.contains { name in
            !own.contains(name) && stem(name) == leadStem && takesPartInUnits(name) && !sideExtensions.contains(ext(name))
        }
        if !otherShot {
            for name in names.sorted() where sideExtensions.contains(ext(name)) && stem(name) == leadStem && name != lead {
                out.append(name)
            }
        }
        return out
    }

    /// The names among `names` that travel with another of them (members, edit files, metadata files of media): what a
    /// plan or a drop leaves out because its lead carries it. Every file that is not an edit file leads its own (A13-2,
    /// round 14, A14-4).
    public static func carried(in names: [String]) -> Set<String> {
        let leads = names.filter { !sideExtensions.contains(ext($0)) && !$0.lowercased().hasSuffix(".json") }
        return Set(leads.flatMap { companions(ofLead: $0, in: names) })
    }

    /// Whether `name` is a companion of `lead` by its name alone (Undo, where the folder may have changed since).
    public static func isCompanionName(_ name: String, ofLead lead: String) -> Bool {
        let leadStem = (lead as NSString).deletingPathExtension
        guard name.count > leadStem.count, name.lowercased().hasPrefix(leadStem.lowercased() + ".") else { return false }
        let suffix = String(name.dropFirst(leadStem.count + 1)).lowercased()
        let leadExt = ext(lead)
        if suffix == "\(leadExt).json" || sideExtensions.contains(suffix) { return true }
        let parts = suffix.split(separator: ".").map(String.init)
        guard let memberExt = parts.first, parts.count <= 2, parts.count == 1 || parts[1] == "json" else { return false }
        let leadsMembers = MediaFormat.rawExtensions.contains(leadExt)
            ? photoExtensions.union(clipExtensions).union(MediaFormat.rawExtensions)
            : photoExtensions.contains(leadExt) ? clipExtensions.union(photoExtensions) : []
        return leadsMembers.contains(memberExt) && memberExt != leadExt
    }

    /// A companion's name once its lead is called `newLead`: the lead's stem is swapped, the rest kept
    /// (`IMG_1.JPG` → `IMG_1 2.JPG` when `IMG_1.CR3` became `IMG_1 2.CR3`).
    public static func renamed(_ companion: String, lead: String, newLead: String) -> String {
        let oldStem = (lead as NSString).deletingPathExtension, newStem = (newLead as NSString).deletingPathExtension
        guard companion.lowercased().hasPrefix(oldStem.lowercased()) else { return companion }
        return newStem + companion.dropFirst(oldStem.count)
    }

    /// The parts after the stem of each companion (`.JPG`, `.CR3.json`, `.xmp`), so a destination is free for all of them.
    public static func suffixes(ofLead lead: String, in names: [String]) -> [String] {
        let leadStem = (lead as NSString).deletingPathExtension
        return companions(ofLead: lead, in: names).map { String($0.dropFirst(leadStem.count)) }
    }
}

/// Instagram posts with several pictures (R-4208): files whose metadata files share an account and post id with a
/// count above 1.
public enum PostGroups {
    /// Each file's folder chosen so a whole post lands in one place: the first picture's for most sorts, or, with
    /// `byMajority`, the folder most of its pictures go to (ties go to the first picture). Files without a post keep
    /// their own. Returns the new assignment and how many posts were kept whole.
    public static func keepTogether(_ entries: [MediaEntry], assignment: [String: [[String]]], byMajority: Bool)
        -> (assignment: [String: [[String]]], posts: Int)
    {
        var out = assignment
        var posts = 0
        let grouped = Dictionary(grouping: entries.filter { $0.source?.postKey != nil }) { $0.source!.postKey! }
        for members in grouped.values where members.count > 1 {
            let ordered = members.sorted { ($0.source?.num ?? .max, $0.name) < ($1.source?.num ?? .max, $1.name) }
            let first = assignment[ordered[0].path] ?? []
            var chosen = first
            if byMajority {
                var counts: [[[String]]: Int] = [:]
                for member in ordered {
                    counts[assignment[member.path] ?? [], default: 0] += 1
                }
                let best = counts.values.max() ?? 0
                // The first picture's folder wins a tie; otherwise the first folder (in post order) with the most pictures.
                if counts[first] != best {
                    chosen = ordered.map { assignment[$0.path] ?? [] }.first { counts[$0] == best } ?? first
                }
            }
            for member in ordered {
                out[member.path] = chosen
            }
            posts += 1
        }
        return (out, posts)
    }
}
