import Foundation
import MediaPullCore

/// Edit/Frame recipes (R-4602, D-127), one file each in Application Support, never in a library folder. Kept by their own
/// id, so one path can hold several (two cards with one name): a file is shown the newest recipe made for it, found by its
/// path and creation date, or by a reference that follows it through renames and moves on its disk.
public actor RecipeStore {
    public nonisolated let folder: URL
    private var byID: [UUID: EditRecipe] = [:]
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
            guard let data = try? Data(contentsOf: file), var recipe = EditRecipe.decode(data) else { continue }
            recipe.source.path = Self.key(recipe.source.path)
            byID[recipe.id] = recipe
        }
    }

    /// The file's creation date, which tells it apart from another file later given its name.
    public static func created(_ path: String) -> Date? {
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

    /// The newest recipe at `path` that was made for the file there.
    private func belonging(at path: String) -> EditRecipe? {
        byID.values.filter { $0.source.path == path && Self.belongs($0, to: path) }.max { $0.modified < $1.modified }
    }

    /// Whether the recipe's file is still where it says: there, and the same file.
    private static func inPlace(_ recipe: EditRecipe) -> Bool {
        FileManager.default.fileExists(atPath: recipe.source.path) && belongs(recipe, to: recipe.source.path)
    }

    /// Where each recipe not in place now leads (nil: nowhere), worked out at most every few seconds: recipes are never
    /// deleted, so a batch would otherwise look every one of them up for each file (audit 2026-11-21-4, B4-m3).
    private var away: [UUID: String?]?
    private var awayChecked = Date.distantPast

    private func awayTargets() -> [UUID: String?] {
        if let away, Date().timeIntervalSince(awayChecked) < 10 { return away }
        var found: [UUID: String?] = [:]
        for (id, recipe) in byID where !Self.inPlace(recipe) {
            found[id] = recipe.source.reference.flatMap(Self.resolve)
        }
        away = found
        awayChecked = Date()
        return found
    }

    /// Recipes whose file was moved or renamed outside MediaPull are brought to where their reference leads now. Only
    /// those not in place are looked up, and none is ever written over another.
    private func relocate(only target: String? = nil) {
        for (id, leads) in awayTargets() {
            guard let moved = leads, var followed = byID[id], moved != followed.source.path, target == nil || moved == target
            else { continue }
            followed.source.path = moved
            byID[id] = followed
            away?[id] = nil
            write(followed)
        }
    }

    /// Files rewritten in place (a metadata edit swaps in a new file): their recipes take the new file's reference, so a
    /// later rename in the Finder is still followed (audit 2026-11-21-4, B4-m1).
    public func refreshReferences(_ paths: [String]) {
        load()
        let wanted = Set(paths.map(Self.key))
        for (id, recipe) in byID where wanted.contains(recipe.source.path) && Self.belongs(recipe, to: recipe.source.path) {
            guard let reference = Self.reference(recipe.source.path), reference != recipe.source.reference else { continue }
            var updated = recipe
            updated.source.reference = reference
            byID[id] = updated
            write(updated)
        }
    }

    /// The recipe for the file at `url`: the newest made for it at its path, else one whose reference now leads to it
    /// (it was moved or renamed outside MediaPull). A recipe of another file once at this path is kept and never shown.
    public func recipe(for url: URL) -> EditRecipe? {
        load()
        let path = Self.key(url.path)
        if let recipe = belonging(at: path) { return recipe }
        relocate(only: path)
        return belonging(at: path)
    }

    /// Paths whose file has a recipe made for it, so the Media pane can mark them.
    public func editedPaths() -> Set<String> {
        load()
        relocate()
        return Set(byID.values.filter { Self.belongs($0, to: $0.source.path) }.map(\.source.path))
    }

    /// Keeps an edited recipe; a recipe with nothing edited is removed (Revert). False when it could not be written.
    @discardableResult
    public func save(_ recipe: EditRecipe) -> Bool {
        load()
        var recipe = recipe
        let path = Self.key(recipe.source.path)
        recipe.source.path = path
        // The store knows the file best: a move may have given it a new creation date the caller's copy does not have.
        if let stored = byID[recipe.id], stored.source.path == path {
            recipe.source.created = stored.source.created ?? recipe.source.created
            recipe.source.reference = stored.source.reference ?? recipe.source.reference
        }
        if recipe.source.reference == nil { recipe.source.reference = Self.reference(path) }
        if recipe.source.created == nil { recipe.source.created = Self.created(path) }
        guard recipe.isEdited else {
            remove(id: recipe.id)
            return true
        }
        recipe.modified = Date()
        byID[recipe.id] = recipe
        away?[recipe.id] = nil
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

    /// Revert of a file not open: only the recipes made for the file at `path` go, never another file's.
    public func remove(_ path: String) {
        load()
        let path = Self.key(path)
        for recipe in byID.values where recipe.source.path == path && Self.belongs(recipe, to: path) {
            remove(id: recipe.id)
        }
    }

    public func remove(id: UUID) {
        load()
        byID[id] = nil
        away?[id] = nil
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// The recipes whose files are where they say (there, and the same file), asked just before MediaPull moves files.
    public func inPlaceIDs() -> Set<UUID> {
        load()
        return Set(byID.filter { Self.inPlace($0.value) }.keys)
    }

    /// Recipes follow files MediaPull moved or renamed (R-4602). `inPlaceBefore`: `inPlaceIDs()` from before the moves,
    /// which tells, on a move to another disk, the file's own recipe from one of another file once at that path.
    public func movePaths(_ moves: [(from: String, to: String)], inPlaceBefore: Set<UUID>? = nil) {
        load()
        guard !moves.isEmpty else { return }
        away = nil
        let remap = PathMoves(moves.map { (Self.key($0.from), Self.key($0.to)) })
        for (id, recipe) in byID {
            var moved = recipe
            var changed = false
            let path = recipe.source.path
            // As stored, or with links resolved (the journal records /private/var where a pane may show /var). A recipe of
            // another file once at that path stays where it was: on one disk the moved file is known by its reference or
            // its creation date; to another disk neither survives, so whether it was in place before the move decides.
            if let destination = remap.destination(of: path)
                ?? remap.destination(of: URL(fileURLWithPath: path).resolvingSymlinksInPath().path),
                Self.follows(recipe, to: destination, crossesDisks: Self.volume(path) != Self.volume(destination),
                             wasInPlace: inPlaceBefore?.contains(id) ?? true)
            {
                moved.source.path = Self.key(destination)
                // Moved to another disk, a file gets a new creation date: MediaPull moved it, so it is still this file.
                moved.source.created = Self.created(destination) ?? moved.source.created
                moved.source.reference = Self.reference(destination) ?? moved.source.reference
                changed = true
            }
            // Picture layers follow their files too.
            for index in moved.layers.indices {
                if case let .image(picture) = moved.layers[index].kind, let destination = remap.destination(of: Self.key(picture)) {
                    moved.layers[index].kind = .image(path: destination)
                    changed = true
                }
            }
            byID[id] = moved
            if changed { write(moved) }
        }
    }

    /// Whether a recipe at a path MediaPull moved goes with the file now at `destination`.
    static func follows(_ recipe: EditRecipe, to destination: String, crossesDisks: Bool, wasInPlace: Bool) -> Bool {
        if recipe.source.reference.flatMap(resolve) == key(destination) || belongs(recipe, to: destination) { return true }
        return crossesDisks && wasInPlace
    }

    /// The disk a path is on, from its nearest folder that is still there.
    static func volume(_ path: String) -> String? {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            url.deleteLastPathComponent()
        }
        return ((try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier).map { "\($0)" }
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
    public static func reference(_ path: String) -> String? {
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
