import Foundation
import MediaPullCore

/// Units on disk (R-4206): a folder's names are read once per change and kept here, so finding a file's companions does
/// not list its folder again for every file.
public final class UnitFiles {
    private var names: [String: [String]] = [:]

    public init() {}

    func names(in folder: URL) -> [String] {
        let key = folder.standardizedFileURL.path
        if let known = names[key] { return known }
        let listed = (try? FileManager.default.contentsOfDirectory(atPath: key)) ?? []
        names[key] = listed
        return listed
    }

    /// Forgets what a folder held, after a change put files into it or took them out.
    func forget(_ folder: URL) { names[folder.standardizedFileURL.path] = nil }

    /// The files that travel with `file` (its unit's members, edit files and metadata files); none for a folder.
    public func companions(of file: URL) -> [URL] {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder), !isFolder.boolValue else { return [] }
        let folder = file.deletingLastPathComponent()
        return MediaUnits.companions(ofLead: file.lastPathComponent, in: names(in: folder)).map { folder.appendingPathComponent($0) }
    }

    /// Where each companion goes when `file` goes to `destination`.
    public func companionMoves(of file: URL, to destination: URL) -> [(from: URL, to: URL)] {
        companions(of: file).map { companion in
            let name = MediaUnits.renamed(companion.lastPathComponent, lead: file.lastPathComponent, newLead: destination.lastPathComponent)
            return (companion, destination.deletingLastPathComponent().appendingPathComponent(name))
        }
    }

    /// Names a destination must leave free besides its own (`.JPG`, `.CR3.json`, `.xmp`).
    public func suffixes(of file: URL) -> [String] {
        let folder = file.deletingLastPathComponent()
        return MediaUnits.suffixes(ofLead: file.lastPathComponent, in: names(in: folder))
    }

    /// A one-off lookup, for callers outside a change.
    public static func companions(of file: URL) -> [URL] { UnitFiles().companions(of: file) }
}
