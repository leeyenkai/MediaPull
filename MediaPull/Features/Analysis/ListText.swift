import Foundation
import MediaPullCore

/// The text of a list view cell for a folder pane's files and folders (R-1709).
enum ListText {
    /// As in the Finder, a folder shows its name and kind; its size and dates are left out ("--").
    static func folder(_ id: String, _ column: ListColumn) -> String {
        switch column {
        case .name: URL(fileURLWithPath: id).lastPathComponent
        case .kind: "Folder"
        default: "--"
        }
    }

    /// `measured` is a pixel size read for the grid when analysis has not given one yet.
    static func entry(_ entry: MediaEntry, _ column: ListColumn, measured: PixelSize? = nil) -> String {
        switch column {
        case .name: entry.name
        case .date: entry.date.formatted(date: .abbreviated, time: .shortened)
        case .size: Format.bytes(entry.size)
        case .dimensions:
            if let facts = entry.facts, let width = facts.pixelWidth, let height = facts.pixelHeight { "\(width) × \(height)" } else {
                measured.map { "\($0.width) × \($0.height)" } ?? ""
            }
        case .kind: entry.format?.label ?? entry.url.pathExtension.uppercased()
        case .duration: entry.facts?.duration.map(Format.duration) ?? ""
        case .source: entry.source?.sourceName ?? ""
        case .found: ""
        }
    }
}
