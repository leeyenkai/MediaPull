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
        // A recipe is never deleted here: only Revert removes one (D-127). A drive that is away, a card of the same name or
        // a file renamed outside MediaPull must never cost the person their edits.
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let recipe = EditRecipe.decode(data) else { continue }
            let path = Self.key(recipe.source.path)
            // Two recipes for one path (a crash between writes): the newer one is kept.
            if let other = byPath[path], other.modified > recipe.modified { continue }
            byPath[path] = recipe
        }
    }

    /// The file's creation date, which tells it apart from another file later given its name.
    static func created(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date
    }

    /// Whether `recipe` was made for the file now at `path` (R-4602): a recipe without a date is taken as it is.
    static func belongs(_ recipe: EditRecipe, to path: String) -> Bool {
        guard let made = recipe.source.created, let now = created(path) else { return true }
        return abs(made.timeIntervalSince(now)) < 1
    }

    static func key(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// The recipe for the file at `url`: by its path, else by a reference that now leads to it (it was moved or renamed
    /// outside MediaPull), whose path is then brought up to date.
    public func recipe(for url: URL) -> EditRecipe? {
        load()
        let path = Self.key(url.path)
        if let recipe = byPath[path] {
            if Self.belongs(recipe, to: path) { return recipe }
            // Another file with this name. The recipe is the other file's: where its reference leads now, if anywhere,
            // else it is kept as it is (that file may come back), and never shown for this one.
            if let reference = recipe.source.reference, let moved = Self.resolve(reference), moved != path {
                var followed = recipe
                followed.source.path = moved
                byPath[path] = nil
                byPath[moved] = followed
                write(followed)
            }
            return nil
        }
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

    /// Keeps an edited recipe; a recipe with nothing edited is removed (Revert). False when it could not be written.
    @discardableResult
    public func save(_ recipe: EditRecipe) -> Bool {
        load()
        var recipe = recipe
        let path = Self.key(recipe.source.path)
        recipe.source.path = path
        if recipe.source.reference == nil { recipe.source.reference = Self.reference(path) }
        if recipe.source.created == nil { recipe.source.created = Self.created(path) }
        guard recipe.isEdited else {
            remove(path)
            return true
        }
        recipe.modified = Date()
        byPath[path] = recipe
        return write(recipe)
    }

    /// At quit: writes a recipe at once, outside the actor (the app is about to end).
    public nonisolated func saveNow(_ recipe: EditRecipe) {
        guard recipe.isEdited else {
            // A Revert just before quitting: its file goes now.
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(recipe.id.uuidString).json"))
            return
        }
        var recipe = recipe
        recipe.modified = Date()
        if recipe.source.created == nil { recipe.source.created = Self.created(recipe.source.path) }
        _ = Self.write(recipe, to: folder.appendingPathComponent("\(recipe.id.uuidString).json"), folder: folder)
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
        let remap = PathMoves(moves.map { (Self.key($0.from), Self.key($0.to)) })
        // Built anew, so a recipe moving onto another's old path never pushes that one out.
        var next: [String: EditRecipe] = [:]
        for (path, recipe) in byPath {
            var moved = recipe
            var changed = false
            // As stored, or with links resolved (the journal records /private/var where a pane may show /var).
            if let destination = remap.destination(of: path)
                ?? remap.destination(of: URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
            {
                moved.source.path = Self.key(destination)
                // Moved to another disk, a file gets a new creation date: MediaPull moved it, so it is still this file.
                moved.source.created = Self.created(destination) ?? moved.source.created
                changed = true
            }
            // Picture layers follow their files too.
            for index in moved.layers.indices {
                if case let .image(picture) = moved.layers[index].kind, let destination = remap.destination(of: Self.key(picture)) {
                    moved.layers[index].kind = .image(path: destination)
                    changed = true
                }
            }
            next[moved.source.path] = moved
            if changed { write(moved) }
        }
        byPath = next
    }

    private func url(for id: UUID) -> URL {
        folder.appendingPathComponent("\(id.uuidString).json")
    }

    @discardableResult
    private func write(_ recipe: EditRecipe) -> Bool {
        Self.write(recipe, to: url(for: recipe.id), folder: folder)
    }

    /// False when it could not be written (a full disk): the caller says so.
    static func write(_ recipe: EditRecipe, to url: URL, folder: URL) -> Bool {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(recipe) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
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
