import Foundation

/// One file in a Library or Organise folder, with what analysis knows about it.
public struct MediaEntry: Sendable, Hashable {
    public var url: URL
    public var size: Int64
    public var created: Date?
    public var modified: Date
    public var format: MediaFormat?
    public var source: SourceInfo?
    public var record: AnalysisRecord?

    public init(url: URL, size: Int64, created: Date?, modified: Date, format: MediaFormat?, source: SourceInfo? = nil,
                record: AnalysisRecord? = nil)
    {
        self.url = url
        self.size = size
        self.created = created
        self.modified = modified
        self.format = format
        self.source = source
        self.record = record
    }

    public var path: String {
        url.path
    }

    public var name: String {
        url.lastPathComponent
    }

    public var date: Date {
        MediaDates.effective(facts: record?.facts, source: source, created: created, modified: modified)
    }

    public var facts: MediaFacts? {
        record?.facts
    }

    public var kind: MediaKind? {
        record?.facts.kind ?? format?.kind
    }
}

public enum LibrarySort: String, Codable, Sendable, CaseIterable {
    case date, name, fileSize, pixelSize, videoLength, source, camera, events, similar

    public var label: String {
        switch self {
        case .date: "Date"
        case .name: "Name"
        case .fileSize: "File Size"
        case .pixelSize: "Pixel Size"
        case .videoLength: "Video Length"
        case .source: "Source"
        case .camera: "Camera"
        case .events: "Events"
        case .similar: "Group Similar"
        }
    }

    public var needsAnalysis: Bool {
        [.pixelSize, .videoLength, .camera, .similar].contains(self)
    }
}

public enum FaceFilter: String, Codable, Sendable, CaseIterable {
    case withFaces, withoutFaces, portraits, groups

    public var label: String {
        switch self {
        case .withFaces: "With Faces"
        case .withoutFaces: "Without Faces"
        case .portraits: "Portraits"
        case .groups: "Group Photos"
        }
    }
}

public enum ScreenshotFilter: String, Codable, Sendable, CaseIterable {
    case screenshots, photos

    public var label: String {
        self == .screenshots ? "Screenshots" : "Photos"
    }
}

/// Filters combine with AND; values chosen within one filter combine with OR (R-3703).
public struct LibraryFilter: Codable, Sendable, Hashable {
    public var kinds: Set<MediaKind> = []
    public var formats: Set<MediaFormat> = []
    public var orientations: Set<Orientation> = []
    public var minPixels: Int?
    public var minDuration: Double?
    public var maxDuration: Double?
    public var cameras: Set<String> = []
    public var sources: Set<String> = []
    public var screenshots: ScreenshotFilter?
    public var colours: Set<ColourName> = []
    public var places: Set<String> = []
    public var tags: Set<String> = []
    public var faces: FaceFilter?
    public var people: Set<UUID> = []
    public var similarOnly = false

    public init() {}

    public var isEmpty: Bool {
        self == LibraryFilter()
    }

    /// How many filters are set, for the filter button's badge.
    public var count: Int {
        [!kinds.isEmpty, !formats.isEmpty, !orientations.isEmpty, minPixels != nil, minDuration != nil || maxDuration != nil,
         !cameras.isEmpty, !sources.isEmpty, screenshots != nil, !colours.isEmpty, !places.isEmpty, !tags.isEmpty, faces != nil,
         !people.isEmpty, similarOnly].filter(\.self).count
    }

    /// Filters that only work once a file has been analysed.
    public var needsAnalysis: Bool {
        !orientations.isEmpty || minPixels != nil || minDuration != nil || maxDuration != nil || !cameras.isEmpty || screenshots != nil
            || !colours.isEmpty || !places.isEmpty || !tags.isEmpty || faces != nil || !people.isEmpty || similarOnly
    }
}

public struct LibrarySection: Sendable, Hashable {
    public var title: String?
    public var items: [MediaEntry]

    public init(title: String?, items: [MediaEntry]) {
        self.title = title
        self.items = items
    }
}

/// What the Library shows: sort, filters and search (section 37). Pure, so it is table-tested and runs off the main actor.
public struct LibraryQuery: Codable, Sendable, Hashable {
    public var sort: LibrarySort = .date
    public var ascending = false
    public var filter = LibraryFilter()
    public var search = ""
    public var eventGap: TimeInterval = 3 * 3600
    public var tagConfidence: Float = 0.3

    public init() {}

    /// Context computed elsewhere: free-text similarity per path, similar sets, and the people in each file.
    public struct Context: Sendable {
        public var similarity: [String: Float]
        public var similarityFloor: Float
        public var similarGroups: [String: Int]
        public var people: [String: Set<UUID>]

        public init(similarity: [String: Float] = [:], similarityFloor: Float = 0.2, similarGroups: [String: Int] = [:],
                    people: [String: Set<UUID>] = [:])
        {
            self.similarity = similarity
            self.similarityFloor = similarityFloor
            self.similarGroups = similarGroups
            self.people = people
        }
    }

    public func apply(_ items: [MediaEntry], context: Context = Context()) -> [LibrarySection] {
        var shown = items.filter { matches($0, context: context) }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let ranked = shown.compactMap { item -> (MediaEntry, Double)? in
                let text = textScore(item, query: query)
                let semantic = context.similarity[item.path].map(Double.init) ?? -1
                if text > 0 {
                    return (item, 10 + text + max(semantic, 0))
                }
                if semantic >= Double(context.similarityFloor) {
                    return (item, semantic)
                }
                return nil
            }
            return [LibrarySection(title: nil, items: ranked.sorted { $0.1 > $1.1 }.map(\.0))]
        }
        shown = sorted(shown, context: context)
        switch sort {
        case .events: return events(shown)
        case .similar: return similarSections(shown, context: context)
        default: return [LibrarySection(title: nil, items: shown)]
        }
    }

    // MARK: Filters

    public func matches(_ item: MediaEntry, context: Context = Context()) -> Bool {
        let f = filter
        let facts = item.facts
        if !f.kinds.isEmpty, !(item.kind.map(f.kinds.contains) ?? false) {
            return false
        }
        if !f.formats.isEmpty, !(item.format.map(f.formats.contains) ?? false) {
            return false
        }
        if !f.orientations.isEmpty, !(facts?.orientation.map(f.orientations.contains) ?? false) {
            return false
        }
        if let minPixels = f.minPixels, (facts?.pixelCount ?? 0) < minPixels {
            return false
        }
        if let minDuration = f.minDuration, (facts?.duration ?? -1) < minDuration {
            return false
        }
        if let maxDuration = f.maxDuration, (facts?.duration ?? .infinity) > maxDuration {
            return false
        }
        if !f.cameras.isEmpty, !(facts?.camera.map(f.cameras.contains) ?? false) {
            return false
        }
        if !f.sources.isEmpty, !(item.source?.sourceName.map(f.sources.contains) ?? false) {
            return false
        }
        if let screenshots = f.screenshots {
            guard let record = item.record else { return false }
            if record.isScreenshot != (screenshots == .screenshots) {
                return false
            }
        }
        if !f.colours.isEmpty, !(item.record?.colour.map(f.colours.contains) ?? false) {
            return false
        }
        if !f.places.isEmpty, !(item.record?.place.map { f.places.contains($0.display) || f.places.contains($0.country) } ?? false) {
            return false
        }
        if !f.tags.isEmpty {
            let labels = Set((item.record?.labels ?? []).filter { $0.confidence >= tagConfidence }.map(\.identifier))
            if labels.isDisjoint(with: f.tags) {
                return false
            }
        }
        if let faces = f.faces {
            guard let record = item.record else { return false }
            let count = record.faces.count
            switch faces {
            case .withFaces: if count == 0 {
                    return false
                }
            case .withoutFaces: if count > 0 {
                    return false
                }
            case .portraits: if count != 1 || record.faces[0].area < FaceRules.portraitArea {
                    return false
                }
            case .groups: if count < FaceRules.groupCount {
                    return false
                }
            }
        }
        if !f.people.isEmpty, (context.people[item.path] ?? []).isDisjoint(with: f.people) {
            return false
        }
        if f.similarOnly, context.similarGroups[item.path] == nil {
            return false
        }
        return true
    }

    // MARK: Search

    /// Case- and accent-insensitive text match over the name, metadata, recognised text, tags and place (R-3704).
    public func textScore(_ item: MediaEntry, query: String) -> Double {
        let words = Self.fold(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return 0 }
        let tags = (item.record?.labels ?? []).filter { $0.confidence >= tagConfidence }.map { Self.fold($0.displayName) }
        let fields: [(String, Double)] = [
            (Self.fold((item.name as NSString).deletingPathExtension), 3),
            (Self.fold(item.source?.description ?? ""), 2),
            (Self.fold([item.source?.username, item.source?.category].compactMap(\.self).joined(separator: " ")), 2),
            (Self.fold(item.record?.text ?? ""), 2),
            (Self.fold(item.record?.place?.display ?? ""), 1),
        ]
        var score = 0.0
        for word in words {
            var best = 0.0
            if tags.contains(word) {
                best = 3
            } else if tags.contains(where: { $0.hasPrefix(word) }) {
                best = 2
            }
            for (field, weight) in fields where field.contains(word) {
                best = max(best, weight)
            }
            guard best > 0 else { return 0 }
            score += best
        }
        return score
    }

    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "_", with: " ")
    }

    // MARK: Sorting and sections

    func sorted(_ items: [MediaEntry], context _: Context) -> [MediaEntry] {
        func ordered<T: Comparable>(_ a: T, _ b: T) -> Bool {
            ascending ? a < b : a > b
        }
        switch sort {
        case .date, .similar: return items.sorted { $0.date == $1.date ? $0.name < $1.name : ordered($0.date, $1.date) }
        case .events: return items.sorted { $0.date == $1.date ? $0.name < $1.name : $0.date < $1.date }
        case .name: return items.sorted { ascending ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.name.localizedStandardCompare($1.name) == .orderedDescending
            }
        case .fileSize: return items.sorted { $0.size == $1.size ? $0.name < $1.name : ordered($0.size, $1.size) }
        case .pixelSize:
            return items.sorted { ($0.facts?.pixelCount ?? 0) == ($1.facts?.pixelCount ?? 0) ? $0.name < $1.name
                : ordered($0.facts?.pixelCount ?? 0, $1.facts?.pixelCount ?? 0)
            }
        case .videoLength:
            return items.sorted { ($0.facts?.duration ?? 0) == ($1.facts?.duration ?? 0) ? $0.name < $1.name
                : ordered($0.facts?.duration ?? 0, $1.facts?.duration ?? 0)
            }
        case .source:
            func key(_ i: MediaEntry) -> String {
                "\(i.source?.sourceName?.lowercased() ?? "\u{FFFF}")\u{0}\(i.source?.postID ?? "")"
            }
            return items.sorted { key($0) == key($1) ? $0.date > $1.date : (ascending ? key($0) < key($1) : key($0) > key($1)) }
        case .camera:
            func key(_ i: MediaEntry) -> String {
                i.facts?.camera?.lowercased() ?? "\u{FFFF}"
            }
            return items.sorted { key($0) == key($1) ? $0.date > $1.date : (ascending ? key($0) < key($1) : key($0) > key($1)) }
        }
    }

    /// Sections that start wherever the gap between neighbouring dates is longer than the event gap.
    public func events(_ items: [MediaEntry]) -> [LibrarySection] {
        let chronological = items.sorted { $0.date < $1.date }
        var sections: [[MediaEntry]] = []
        for item in chronological {
            if let last = sections.last?.last, item.date.timeIntervalSince(last.date) <= eventGap {
                sections[sections.count - 1].append(item)
            } else {
                sections.append([item])
            }
        }
        let built = sections.map { LibrarySection(title: Self.eventTitle($0), items: $0) }
        return ascending ? built : built.reversed()
    }

    public static func eventTitle(_ items: [MediaEntry]) -> String {
        guard let first = items.first?.date, let last = items.last?.date else { return "" }
        let day = first.formatted(date: .abbreviated, time: .omitted)
        let lastDay = last.formatted(date: .abbreviated, time: .omitted)
        let place = items.compactMap { $0.record?.place?.city }.first
        let span = day == lastDay ? day : "\(day) – \(lastDay)"
        return [span, place].compactMap(\.self).joined(separator: " · ") + " (\(items.count))"
    }

    func similarSections(_ items: [MediaEntry], context: Context) -> [LibrarySection] {
        var groups: [Int: [MediaEntry]] = [:]
        var rest: [MediaEntry] = []
        for item in items {
            if let group = context.similarGroups[item.path] {
                groups[group, default: []].append(item)
            } else {
                rest.append(item)
            }
        }
        let ordered = groups.values.sorted { $0.count == $1.count ? $0[0].date > $1[0].date : $0.count > $1.count }
        var sections = ordered.enumerated().map { LibrarySection(
            title: "Similar set \($0.offset + 1) (\($0.element.count))",
            items: $0.element
        ) }
        if !rest.isEmpty {
            sections.append(LibrarySection(title: "Not in a set (\(rest.count))", items: rest))
        }
        return sections
    }
}
