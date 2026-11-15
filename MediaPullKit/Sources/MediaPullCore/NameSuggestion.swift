import Foundation

/// Suggests a name for an unnamed person from the folder their photos sit in (R-3905, D-66). Never applied without a click.
public enum NameSuggestion {
    public static let minimumPhotos = 5
    public static let minimumShare = 0.6
    /// The person must make up most of the photos with people in that folder.
    public static let minimumFolderShare = 0.5

    static let generic: Set<String> = [
        "unsorted", "posts", "reels", "stories", "highlights", "profile pictures", "tagged", "reposts", "saved posts", "hashtags",
        "account details", "group photos", "screenshots", "photos", "pictures", "images", "videos", "camera roll", "downloads",
        "desktop", "documents", "media", "new folder", "untitled folder", "misc", "other", "old", "new", "family", "friends", "people",
        "selfies", "portraits", "wallpapers", "memes", "edited", "export", "exports", "originals", "backup", "pdf", "web",
    ]

    /// Whether a folder name could be a person's name: one to four words of letters, no digits or underscores,
    /// not a known folder type, a date or a site.
    public static func looksLikeName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard (2 ... 40).contains(trimmed.count), !generic.contains(trimmed.lowercased()),
              !FileNaming.reservedFolders.contains(trimmed.lowercased()) else { return false }
        if trimmed.contains(where: { $0.isNumber || $0 == "_" || $0 == "." || $0 == "@" || $0 == "#" || $0 == "/" }) {
            return false
        }
        let words = trimmed.split(separator: " ")
        guard (1 ... 4).contains(words.count) else { return false }
        return words.allSatisfy { word in
            word.first?.isLetter == true && word.allSatisfy { $0.isLetter || $0 == "-" || $0 == "'" || $0 == "’" }
        }
    }

    /// For one person: the paths of their photos, and for each folder how many photos with any recognised person it holds.
    /// Folders missing from `peoplePhotosByFolder` are not considered. `accountFolders` are folders named after an account in their
    /// metadata files, which are never suggested.
    public static func suggest(personPhotos: [String], peoplePhotosByFolder: [String: Int], accountFolders: Set<String>,
                               root: String? = nil) -> String?
    {
        guard personPhotos.count >= minimumPhotos else { return nil }
        var byFolder: [String: Int] = [:]
        for path in personPhotos {
            var folder = (path as NSString).deletingLastPathComponent
            var depth = 0
            while depth < 3, folder.count > 1, folder != root {
                byFolder[folder, default: 0] += 1
                folder = (folder as NSString).deletingLastPathComponent
                depth += 1
            }
        }
        // The deepest folder that qualifies is the most specific name.
        let candidates = byFolder.filter { folder, count in
            let name = (folder as NSString).lastPathComponent
            guard let withPeople = peoplePhotosByFolder[folder] else { return false }
            return Double(count) / Double(personPhotos.count) >= minimumShare && looksLikeName(name)
                && !accountFolders.contains(folder) && Double(count) / Double(max(withPeople, count)) >= minimumFolderShare
        }
        guard let best = candidates.max(by: { a, b in
            a.key.split(separator: "/").count == b.key.split(separator: "/").count ? a.value < b.value
                : a.key.split(separator: "/").count < b.key.split(separator: "/").count
        }) else { return nil }
        return (best.key as NSString).lastPathComponent.trimmingCharacters(in: .whitespaces)
    }
}
