import Foundation

/// How a pane shows its media, as in the Finder (SPEC R-1708, D-76).
public enum PaneViewMode: String, Codable, Sendable, CaseIterable, Hashable {
    case icon, list, column

    public var label: String {
        switch self {
        case .icon: "as Icons"
        case .list: "as List"
        case .column: "as Columns"
        }
    }

    public var symbol: String {
        switch self {
        case .icon: "square.grid.2x2"
        case .list: "list.bullet"
        case .column: "rectangle.split.3x1"
        }
    }

    /// Extracted Media is not a folder, so it has no column view.
    public static func allowed(for pane: PaneID) -> [PaneViewMode] {
        switch pane {
        case .library, .organiseSource, .organiseTarget: [.icon, .list, .column]
        case .extracted: [.icon, .list]
        default: [.icon]
        }
    }
}

/// Each pane's view, kept between launches. Unknown panes and views not allowed for a pane read as icons.
public struct PaneViewModes: Codable, Sendable, Equatable {
    public var modes: [String: PaneViewMode]

    public init(modes: [String: PaneViewMode] = [:]) {
        self.modes = modes
    }

    public init(from decoder: Decoder) throws {
        // A stored view this version does not know (written by a later one) is dropped rather than failing the whole set.
        let raw = try decoder.singleValueContainer().decode([String: String].self)
        modes = raw.compactMapValues(PaneViewMode.init(rawValue:))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(modes.mapValues(\.rawValue))
    }

    public func mode(for pane: PaneID) -> PaneViewMode {
        let mode = modes[pane.rawValue] ?? .icon
        return PaneViewMode.allowed(for: pane).contains(mode) ? mode : .icon
    }

    public mutating func set(_ mode: PaneViewMode, for pane: PaneID) {
        guard PaneViewMode.allowed(for: pane).contains(mode) else { return }
        modes[pane.rawValue] = mode
    }
}

/// A column of the list view. Clicking its header sorts by the matching Library or Extracted Media sort, when it has one.
public enum ListColumn: String, Codable, Sendable, CaseIterable, Hashable {
    case name, date, size, dimensions, kind, duration, source, found, tags

    public var title: String {
        switch self {
        case .name: "Name"
        case .date: "Date"
        case .size: "Size"
        case .dimensions: "Dimensions"
        case .kind: "Kind"
        case .duration: "Duration"
        case .source: "Source"
        case .found: "Found"
        case .tags: "Tags"
        }
    }

    /// The Library and Organise columns, and Extracted Media's.
    public static let fileColumns: [ListColumn] = [.name, .date, .size, .dimensions, .kind, .duration, .tags]
    public static let extractedColumns: [ListColumn] = [.name, .dimensions, .size, .kind, .duration, .source, .found]

    public var librarySort: LibrarySort? {
        switch self {
        case .name: .name
        case .date: .date
        case .size: .fileSize
        case .dimensions: .pixelSize
        case .duration: .videoLength
        case .source: .source
        case .kind, .found, .tags: nil
        }
    }

    public var extractedSort: SortOrder? {
        switch self {
        case .dimensions: .resolution
        case .size: .fileSize
        case .kind: .type
        case .duration: .duration
        case .source: .domain
        case .found: .discovery
        case .date: .date
        case .name, .tags: nil
        }
    }

    public init?(librarySort: LibrarySort) {
        guard let column = Self.fileColumns.first(where: { $0.librarySort == librarySort }) else { return nil }
        self = column
    }

    public init?(extractedSort: SortOrder) {
        guard let column = Self.extractedColumns.first(where: { $0.extractedSort == extractedSort }) else { return nil }
        self = column
    }

    /// As in the Finder: names A to Z, the newest, largest and longest first.
    public var defaultAscending: Bool {
        switch self {
        case .name, .kind, .source, .found, .tags: true
        case .date, .size, .dimensions, .duration: false
        }
    }
}

/// The sort after a column header is clicked: the same column flips direction, another starts in its own default.
public enum ListSortState {
    public static func next(clicked: ListColumn, current: (column: ListColumn, ascending: Bool)?) -> (column: ListColumn, ascending: Bool) {
        if let current, current.column == clicked { return (clicked, !current.ascending) }
        return (clicked, clicked.defaultAscending)
    }
}
