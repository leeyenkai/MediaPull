import Foundation

/// The sections of the window, each with its own panes (D-62, D-115).
public enum PaneGroup: String, Codable, Sendable, Hashable {
    case collect, organise, devices
}

/// The window's panes (SPEC sections 7 and 38).
public enum PaneID: String, Codable, CaseIterable, Sendable, Hashable {
    case source, extracted, preview, library, downloads
    case organiseSource, organiseWork, organiseTarget, organiseMap
    case devicesList, devicesMedia, devicesImport

    public var title: String {
        switch self {
        case .source: "Browser"
        case .extracted: "Extracted Media"
        case .preview: "Preview"
        case .library: "Library"
        case .downloads: "Downloads"
        case .organiseSource: "Source"
        case .organiseWork: "Organise"
        case .organiseTarget: "Target"
        case .organiseMap: "Map & Timeline"
        case .devicesList: "Devices"
        case .devicesMedia: "Media"
        case .devicesImport: "Import"
        }
    }

    public var group: PaneGroup {
        switch self {
        case .organiseSource, .organiseWork, .organiseTarget, .organiseMap: .organise
        case .devicesList, .devicesMedia, .devicesImport: .devices
        default: .collect
        }
    }

    public static func panes(in group: PaneGroup) -> [PaneID] { allCases.filter { $0.group == group } }
}

/// Where the panes sit: columns from left to right, each a stack of panes from top to bottom
/// (SPEC R-701a). Every pane appears exactly once.
public struct PaneArrangement: Codable, Equatable, Sendable, Hashable {
    public private(set) var columns: [[PaneID]]
    public let group: PaneGroup

    public init(columns: [[PaneID]], group: PaneGroup? = nil) {
        let resolved = group ?? columns.joined().first?.group ?? .collect
        self.group = resolved
        self.columns = columns.map { $0.filter { $0.group == resolved } }
        repair()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode([[String]].self)
        self.init(columns: raw.map { $0.compactMap(PaneID.init(rawValue:)) })
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(columns.map { $0.map(\.rawValue) })
    }

    public static let standard = PaneArrangement(columns: [[.source], [.extracted, .preview], [.library]])
    public static let previewColumn = PaneArrangement(columns: [[.source], [.extracted], [.preview], [.library]])
    public static let previewUnderBrowser = PaneArrangement(columns: [[.source, .preview], [.extracted], [.library]])
    public static let previewUnderLibrary = PaneArrangement(columns: [[.source], [.extracted], [.library, .preview]])
    public static let libraryFirst = PaneArrangement(columns: [[.library], [.extracted, .preview], [.source]])

    public static let presets: [(name: String, arrangement: PaneArrangement)] = [
        ("Standard", .standard),
        ("Preview in Its Own Column", .previewColumn),
        ("Preview Below Browser", .previewUnderBrowser),
        ("Preview Below Library", .previewUnderLibrary),
        ("Mirrored", .libraryFirst),
    ]

    // The Map & Timeline pane sits under the Organise pane; it is hidden until shown (R-4401).
    public static let organiseStandard = PaneArrangement(columns: [[.organiseSource], [.organiseWork, .organiseMap], [.organiseTarget]])
    public static let organiseWorkRight = PaneArrangement(columns: [[.organiseSource], [.organiseTarget], [.organiseWork, .organiseMap]])
    public static let organiseTargetBelow = PaneArrangement(columns: [[.organiseSource, .organiseTarget], [.organiseWork, .organiseMap]])

    public static let organisePresets: [(name: String, arrangement: PaneArrangement)] = [
        ("Standard", .organiseStandard),
        ("Organise on the Right", .organiseWorkRight),
        ("Target Below Source", .organiseTargetBelow),
    ]

    public static let devicesStandard = PaneArrangement(columns: [[.devicesList], [.devicesMedia], [.devicesImport]])
    public static let devicesImportBelow = PaneArrangement(columns: [[.devicesList, .devicesImport], [.devicesMedia]])

    public static let devicesPresets: [(name: String, arrangement: PaneArrangement)] = [
        ("Standard", .devicesStandard),
        ("Import Below Devices", .devicesImportBelow),
    ]

    public static func presets(for group: PaneGroup) -> [(name: String, arrangement: PaneArrangement)] {
        switch group {
        case .collect: presets
        case .organise: organisePresets
        case .devices: devicesPresets
        }
    }

    /// A stable name for this arrangement, used to keep divider positions per arrangement.
    public var key: String {
        columns.map { $0.map(\.rawValue).joined(separator: "+") }.joined(separator: "|")
    }

    public func column(of pane: PaneID) -> Int? {
        columns.firstIndex { $0.contains(pane) }
    }

    public func isStacked(_ pane: PaneID) -> Bool {
        column(of: pane).map { columns[$0].count > 1 } ?? false
    }

    public enum Side: Sendable { case left, right }

    /// A pane alone in its column swaps places with the neighbouring column; a stacked pane
    /// leaves its stack and becomes its own column on that side.
    public func canMove(_ pane: PaneID, _ side: Side) -> Bool {
        guard let index = column(of: pane) else { return false }
        if columns[index].count > 1 { return true }
        return side == .left ? index > 0 : index < columns.count - 1
    }

    public mutating func move(_ pane: PaneID, _ side: Side) {
        guard canMove(pane, side), let index = column(of: pane) else { return }
        if columns[index].count > 1 {
            columns[index].removeAll { $0 == pane }
            columns.insert([pane], at: side == .left ? index : index + 1)
        } else {
            columns.swapAt(index, side == .left ? index - 1 : index + 1)
        }
    }

    /// Puts the pane at the bottom of the neighbouring column.
    public func canStack(_ pane: PaneID, onto side: Side) -> Bool {
        guard let index = column(of: pane) else { return false }
        return side == .left ? index > 0 : index < columns.count - 1
    }

    public mutating func stack(_ pane: PaneID, onto side: Side) {
        guard canStack(pane, onto: side), let index = column(of: pane) else { return }
        let target = side == .left ? index - 1 : index + 1
        columns[target].append(pane)
        columns[index].removeAll { $0 == pane }
        repair()
    }

    public enum Direction: Sendable { case up, down }

    public func canMoveInStack(_ pane: PaneID, _ direction: Direction) -> Bool {
        guard let index = column(of: pane), let row = columns[index].firstIndex(of: pane) else { return false }
        return direction == .up ? row > 0 : row < columns[index].count - 1
    }

    public mutating func moveInStack(_ pane: PaneID, _ direction: Direction) {
        guard canMoveInStack(pane, direction), let index = column(of: pane), let row = columns[index].firstIndex(of: pane) else { return }
        columns[index].swapAt(row, direction == .up ? row - 1 : row + 1)
    }

    /// Drops duplicates and empty columns, and adds any missing pane as its own column.
    private mutating func repair() {
        var seen = Set<PaneID>()
        columns = columns.map { column in column.filter { seen.insert($0).inserted } }.filter { !$0.isEmpty }
        for pane in PaneID.panes(in: group) where !seen.contains(pane) {
            if pane == .preview, let index = column(of: .extracted) {
                columns[index].append(.preview)
            } else if pane == .downloads, let index = column(of: .source) {
                // Downloads sits below the browser it downloads from.
                columns[index].append(.downloads)
            } else {
                columns.append([pane])
            }
        }
    }
}
