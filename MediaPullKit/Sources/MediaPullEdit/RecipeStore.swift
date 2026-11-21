import Foundation
import MediaPullCore

/// Edit/Frame recipes (R-4602, D-127), one file each in Application Support, never in a library folder. Kept by their own
/// id, so one path can hold several (two cards with one name): a file is shown the newest recipe made for it, found by its
/// path and creation date, or by a reference that follows it through renames and moves on its disk.
///
/// The store alone knows which file a recipe belongs to (its path, creation date and reference): callers change only the
/// edits, so an Undo or a save from a window can never give a recipe an identity that is out of date. Recipes are never
/// deleted: Revert keeps one blank, so ⌘Z brings the edits back wherever the file has gone since (audit 2026-11-21-5).
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
        // A drive that is away, a card of the same name or a file renamed outside MediaPull must never cost the person
        // their edits: nothing is pruned.
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
    public static func belongs(_ recipe: EditRecipe, to path: String) -> Bool {
        guard let made = recipe.source.created, let now = created(path) else { return true }
        return abs(made.timeIntervalSince(now)) < 1
    }

    static func key(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// The edited recipes, the ones marked in the Media pane; a blank one (reverted, or holding only export settings) is
    /// still the file's and is opened with it, so its export settings and ⌘Z stay (audit 2026-11-21-6, B6-m2).
    private var edited: [UUID: EditRecipe] { byID.filter(\.value.isEdited) }

    /// The newest recipe at `path` that was made for the file there.
    private func belonging(at path: String) -> EditRecipe? {
        byID.values.filter { $0.source.path == path && Self.belongs($0, to: path) }.max { $0.modified < $1.modified }
    }

    /// The recipe of this id, wherever its file is now.
    public func recipe(id: UUID) -> EditRecipe? {
        load()
        guard let recipe = byID[id] else { return nil }
        relocate(only: nil, ids: [id])
        return byID[id] ?? recipe
    }

    /// Whether the recipe's file is still where it says: there, and the same file.
    private static func inPlace(_ recipe: EditRecipe) -> Bool {
        FileManager.default.fileExists(atPath: recipe.source.path) && belongs(recipe, to: recipe.source.path)
    }

    /// Where a recipe not in place leads, and when that was looked up: a reference is resolved again only after a few
    /// seconds, so a batch does not resolve every kept recipe for each file (B4-m3). A recipe found away for the first
    /// time is always resolved at once, so a rename in the Finder is followed straight away (B5-2).
    private var resolved: [UUID: (path: String?, at: Date)] = [:]

    private func leads(_ id: UUID, _ recipe: EditRecipe) -> String? {
        if let known = resolved[id], Date().timeIntervalSince(known.at) < 10 { return known.path }
        let path = recipe.source.reference.flatMap(Self.resolve)
        resolved[id] = (path, Date())
        return path
    }

    /// Recipes whose file was moved or renamed outside MediaPull are brought to where their reference leads now. Only
    /// those not in place are looked up, and none is ever written over another. With a `target`, only recipes whose
    /// reference is that file's are looked at, one comparison each (B6-m3).
    private func relocate(only target: String? = nil, ids: Set<UUID>? = nil) {
        let named = target.flatMap(Self.reference)
        for (id, recipe) in byID where ids?.contains(id) ?? true {
            if target != nil, named == nil || recipe.source.reference != named { continue }
            guard !Self.inPlace(recipe) else {
                resolved[id] = nil
                continue
            }
            guard let moved = leads(id, recipe), moved != recipe.source.path, target == nil || moved == target else { continue }
            var followed = recipe
            followed.source.path = moved
            byID[id] = followed
            resolved[id] = nil
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
        // Marked as shown: by the newest recipe made for the file there (B7-3).
        var newest: [String: EditRecipe] = [:]
        for recipe in byID.values where Self.belongs(recipe, to: recipe.source.path) {
            if let other = newest[recipe.source.path], other.modified >= recipe.modified { continue }
            newest[recipe.source.path] = recipe
        }
        return Set(newest.filter(\.value.isEdited).keys)
    }

    /// Keeps a recipe's edits; one with nothing edited is kept blank (Revert). False when it could not be written.
    @discardableResult
    public func save(_ recipe: EditRecipe) -> Bool {
        store(recipe) != nil
    }

    /// Keeps a recipe's edits and gives back the recipe as kept, or nil when it could not be written.
    ///
    /// The file a held recipe belongs to is the store's to say. A file has one recipe at a time: a new recipe for a file
    /// that has one already (two windows, a paste) takes that one's place and id, so no recipe ever hides another
    /// (audit 2026-11-21-7, B7-3). A new recipe knows its file as it is when it is first kept, since a metadata edit may
    /// have given the file a new reference since it was opened (B7-1).
    @discardableResult
    public func store(_ recipe: EditRecipe) -> EditRecipe? {
        load()
        var recipe = recipe
        // A recipe merged into its file's one recipe is known by that one's id from then on (B8-2).
        if let merged = merged[recipe.id] { recipe.id = merged }
        if let stored = byID[recipe.id] {
            recipe.source = stored.source
        } else {
            // A new recipe goes with the file it was made for (audit 2026-11-21-8, B8-1; round 9, B9-1, B9-2): the file at
            // its path when that is the one (same creation date); else where its reference leads (renamed in the Finder
            // while open); never to a newcomer at its name; none for a file no longer anywhere (B8-3).
            var path = Self.key(recipe.source.path)
            var own = FileManager.default.fileExists(atPath: path) && Self.belongs(recipe, to: path)
            if !own, let moved = relocated(recipe), moved != path {
                path = moved
                own = true
            }
            guard own || FileManager.default.fileExists(atPath: path) else { return nil }
            recipe.source.path = path
            if own, let existing = belonging(at: path) {
                // The file has its recipe already (another window, a paste): this one takes its place.
                merged[recipe.id] = existing.id
                recipe.id = existing.id
                recipe.source = existing.source
            } else if own {
                recipe.source.reference = Self.reference(path) ?? recipe.source.reference
                recipe.source.created = Self.created(path) ?? recipe.source.created
            }
            // Else a newcomer has its name: kept apart under its own creation date, never shown for the newcomer.
        }
        // Where a held recipe's pictures are is the store's to say: a layer brought back with a name its picture was moved
        // away from (an Undo, a stale window) keeps the name the store followed it to (D-128, round 13, B13-1; round 14,
        // B14-2, B14-3).
        if let stored = byID[recipe.id] {
            for index in recipe.layers.indices {
                guard case let .image(path) = recipe.layers[index].kind,
                      movedAway[recipe.layers[index].id]?.contains(Self.key(path)) == true,
                      let same = stored.layers.first(where: { $0.id == recipe.layers[index].id }),
                      case let .image(kept) = same.kind else { continue }
                recipe.layers[index].kind = .image(path: kept)
            }
            if let artwork = recipe.tags?.artworkPath, artworkMovedAway[recipe.id]?.contains(Self.key(artwork)) == true,
               let kept = stored.tags?.artworkPath
            {
                recipe.tags?.artworkPath = kept
            }
        }
        recipe.modified = Date()
        byID[recipe.id] = recipe
        resolved[recipe.id] = nil
        return write(recipe) ? recipe : nil
    }

    /// The names each picture layer's file (by layer id) and each recipe's artwork (by recipe id) were moved away from:
    /// never written back by a recipe kept later.
    private var movedAway: [UUID: Set<String>] = [:]
    private var artworkMovedAway: [UUID: Set<String>] = [:]

    /// Ids of recipes merged into another (two windows, one file), for an Undo that still names the first.
    private var merged: [UUID: UUID] = [:]

    /// Where a new recipe's own reference leads now, when its file has moved on.
    private func relocated(_ recipe: EditRecipe) -> String? {
        recipe.source.reference.flatMap(Self.resolve)
    }

    /// At quit: writes a recipe's edits at once, outside the actor (the app is about to end), under the file identity
    /// the store last wrote for it (B5-m2).
    public nonisolated func saveNow(_ recipe: EditRecipe) {
        let url = folder.appendingPathComponent("\(recipe.id.uuidString).json")
        var recipe = recipe
        recipe.modified = Date()
        if let data = try? Data(contentsOf: url), let stored = EditRecipe.decode(data) {
            recipe.source = stored.source
            // A picture no longer at the name the window has is where the store last kept it (round 14, B14-m3).
            for index in recipe.layers.indices {
                guard case let .image(path) = recipe.layers[index].kind, !FileManager.default.fileExists(atPath: path),
                      let same = stored.layers.first(where: { $0.id == recipe.layers[index].id }),
                      case let .image(kept) = same.kind, FileManager.default.fileExists(atPath: kept) else { continue }
                recipe.layers[index].kind = .image(path: kept)
            }
        } else if FileManager.default.fileExists(atPath: recipe.source.path), Self.belongs(recipe, to: recipe.source.path) {
            // First kept at quit: the file as it is now (B7-1), only if it is still the one it was made for (B8-1).
            recipe.source.created = Self.created(recipe.source.path) ?? recipe.source.created
            recipe.source.reference = Self.reference(recipe.source.path) ?? recipe.source.reference
        }
        _ = Self.write(recipe, to: url, folder: folder)
    }

    /// Revert of a file not open: the recipes made for the file at `path` are kept blank, never another file's.
    public func revert(_ path: String) {
        load()
        let path = Self.key(path)
        for recipe in edited.values where recipe.source.path == path && Self.belongs(recipe, to: path) {
            revert(id: recipe.id)
        }
    }

    /// Revert of one recipe, wherever its file is: kept blank, so ⌘Z brings its edits back.
    public func revert(id: UUID) {
        load()
        guard let recipe = byID[id] else { return }
        save(EditRecipe(id: id, source: recipe.source))
    }

    /// The recipes whose files are not where they say, asked just before MediaPull moves or rewrites files. Files renamed
    /// in the Finder are followed first, while their references still lead to them (audit 2026-11-21-6, B6-1).
    public func awayIDs() -> Set<UUID> {
        load()
        relocate()
        return Set(byID.filter { !Self.inPlace($0.value) }.keys)
    }

    /// Recipes follow files MediaPull moved or renamed (R-4602). `awayBefore`: `awayIDs()` from before the moves, which
    /// tells, on a move to another disk, the file's own recipe from one of another file once at that path; a recipe made
    /// during a long change is not in it, so it goes with its file (B5-m4).
    public func movePaths(_ moves: [(from: String, to: String)], awayBefore: Set<UUID> = []) {
        load()
        guard !moves.isEmpty else { return }
        resolved = [:]
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
                             wasInPlace: !awayBefore.contains(id))
            {
                moved.source.path = Self.key(destination)
                // Moved to another disk, a file gets a new creation date: MediaPull moved it, so it is still this file.
                moved.source.created = Self.created(destination) ?? moved.source.created
                moved.source.reference = Self.reference(destination) ?? moved.source.reference
                changed = true
            }
            // Picture layers and artwork follow their files too, never into a hidden name (a Replace's edit, a rename's
            // temporary name, round 14, B14-1); the names they left are remembered.
            for index in moved.layers.indices {
                guard case let .image(picture) = moved.layers[index].kind,
                      let destination = Self.visible(remap.destination(of: Self.key(picture))) else { continue }
                moved.layers[index].kind = .image(path: destination)
                movedAway[moved.layers[index].id, default: []].insert(Self.key(picture))
                changed = true
            }
            if let artwork = moved.tags?.artworkPath, let destination = Self.visible(remap.destination(of: Self.key(artwork))) {
                moved.tags?.artworkPath = destination
                artworkMovedAway[id, default: []].insert(Self.key(artwork))
                changed = true
            }
            byID[id] = moved
            if changed { write(moved) }
        }
    }

    /// A destination a picture may follow to: none under a hidden name.
    public static func visible(_ destination: String?) -> String? {
        destination.flatMap { (($0 as NSString).lastPathComponent).hasPrefix(".") ? nil : $0 }
    }

    /// The pictures a recipe draws from other files (picture layers, audio artwork) follow them where they went; one rule
    /// for the store, a window's open recipe and its copied settings (audit 2026-11-21-12, B12-1, B12-m5). True when any did.
    public static func picturesFollow(_ recipe: inout EditRecipe, _ destination: (String) -> String?) -> Bool {
        var changed = false
        for index in recipe.layers.indices {
            if case let .image(picture) = recipe.layers[index].kind, let moved = destination(picture) {
                recipe.layers[index].kind = .image(path: moved)
                changed = true
            }
        }
        if let artwork = recipe.tags?.artworkPath, let moved = destination(artwork) {
            recipe.tags?.artworkPath = moved
            changed = true
        }
        return changed
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
