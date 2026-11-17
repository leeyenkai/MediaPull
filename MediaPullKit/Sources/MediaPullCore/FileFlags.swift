import Foundation

public enum FileFlags {
    /// Whether the file's contents are not on this Mac (an iCloud file kept only in the cloud). Reading it would download
    /// it, so checks that only need to know what is here leave it alone. Since macOS 14 such files keep their own names and
    /// carry the dataless flag; older systems left `.name.icloud` placeholders instead.
    public static func isDataless(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & 0x4000_0000 != 0 // SF_DATALESS
    }

    /// Whether a path is in a Trash: `~/.Trash` on the start-up disk, `.Trashes/<user>` on any other (audit 3, B3-M3).
    public static func isInTrash(_ url: URL) -> Bool {
        url.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }
}
