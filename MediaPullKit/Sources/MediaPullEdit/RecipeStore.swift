import Foundation
import MediaPullCore

/// Edit/Frame recipes (R-4602, D-127), one file each in Application Support, never in a library folder. Found by the
/// file's path, or by a reference that follows it through renames and moves on its disk; kept current as MediaPull
/// moves files.
public actor RecipeStore {
    public nonisolated let folder: URL
    private var byPath: [String: EditRecipe] = [:]
    private var loaded = false

    public init(folder: URL) {
        self.folder = folder
    }

    public static var defaultFolder: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("MediaPull/Edits", isDirectory: true)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let recipe = EditRecipe.decode(data) else { continue }
            let path = Self.key(recipe.source.path)
            // Two recipes for one path (a crash between writes): the newer one is kept.
            if let other = byPath[path], other.modified > recipe.modified { continue }
            byPath[path] = recipe
        }
    }

    static func key(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// The recipe for the file at `url`: by its path, else by a reference that now leads to it (it was moved or renamed
    /// outside MediaPull), whose path is then brought up to date.
    public func recipe(for url: URL) -> EditRecipe? {
        load()
        let path = Self.key(url.path)
        if let recipe = byPath[path] { return recipe }
        for (oldPath, recipe) in byPath where !FileManager.default.fileExists(atPath: oldPath) {
            guard let reference = recipe.source.reference, Self.resolve(reference) == path else { continue }
            var moved = recipe
            moved.source.path = path
            byPath[oldPath] = nil
            byPath[path] = moved
            write(moved)
            return moved
        }
        return nil
    }

    /// Paths with a recipe, so the Media pane can mark them.
    public func editedPaths() -> Set<String> {
        load()
        return Set(byPath.keys)
    }

    /// Keeps an edited recipe; a recipe with nothing edited is removed (Revert).
    public func save(_ recipe: EditRecipe) {
        load()
        var recipe = recipe
        let path = Self.key(recipe.source.path)
        recipe.source.path = path
        if recipe.source.reference == nil { recipe.source.reference = Self.reference(path) }
        guard recipe.isEdited else {
            remove(path)
            return
        }
        recipe.modified = Date()
        byPath[path] = recipe
        write(recipe)
    }

    public func remove(_ path: String) {
        load()
        let path = Self.key(path)
        guard let recipe = byPath.removeValue(forKey: path) else { return }
        try? FileManager.default.removeItem(at: url(for: recipe.id))
    }

    /// Recipes follow files MediaPull moved or renamed (R-4602).
    public func movePaths(_ moves: [(from: String, to: String)]) {
        load()
        guard !moves.isEmpty else { return }
        let remap = PathMoves(moves)
        for (path, recipe) in byPath {
            guard let destination = remap.destination(of: path) else { continue }
            var moved = recipe
            moved.source.path = Self.key(destination)
            byPath[path] = nil
            byPath[moved.source.path] = moved
            write(moved)
        }
    }

    private func url(for id: UUID) -> URL {
        folder.appendingPathComponent("\(id.uuidString).json")
    }

    private func write(_ recipe: EditRecipe) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(recipe) else { return }
        // lint:allow silent-write a recipe is MediaPull's own data; the original file is never touched
        try? data.write(to: url(for: recipe.id), options: .atomic)
    }

    /// A reference to the file at `path` that keeps naming it through renames and moves on its disk.
    static func reference(_ path: String) -> String? {
        guard let ref = CFURLCreateFileReferenceURL(nil, URL(fileURLWithPath: path) as CFURL, nil)?.takeRetainedValue() else {
            return nil
        }
        return CFURLGetString(ref) as String
    }

    static func resolve(_ reference: String) -> String? {
        guard let url = CFURLCreateWithString(nil, reference as CFString, nil),
              let path = CFURLCreateFilePathURL(nil, url, nil)?.takeRetainedValue() else { return nil }
        return (path as URL).standardizedFileURL.path
    }
}
