import AppKit
import Foundation
import MediaPullCore
import MediaPullEdit

/// What applying one file's edits to others carries (R-4611, D-134).
enum SettingGroup: String, CaseIterable, Identifiable {
    case look, adjustments, frame, layers

    var id: String { rawValue }

    var label: String {
        switch self {
        case .look: "Look"
        case .adjustments: "Adjustments"
        case .frame: "Frame"
        case .layers: "Text and Shapes"
        }
    }

    func apply(from source: EditRecipe, to recipe: inout EditRecipe) {
        switch self {
        case .look:
            recipe.look = source.look
        case .adjustments:
            recipe.adjust = source.adjust
        case .frame:
            recipe.frame = source.frame
        case .layers:
            // New layer identities, so each file's layers are its own.
            recipe.layers = source.layers.map { layer in
                var copy = layer
                copy.id = UUID()
                return copy
            }
        }
    }
}

/// Copy Settings, applying edits to a selection, and Export Selected (R-4611, D-134).
extension EditModel {
    func copySettings() {
        guard let recipe else { return }
        copiedSettings = recipe
        message = "Settings of “\(URL(fileURLWithPath: recipe.source.path).lastPathComponent)” copied."
    }

    /// The selected files, in the order shown.
    var selectedFiles: [URL] {
        entries.filter { selection.contains($0.path) }.map(\.url)
    }

    /// Where a batch's edits come from (D-134): settings copied earlier, else the open file when it has edits.
    var batchSource: EditRecipe? {
        if let copiedSettings { return copiedSettings }
        guard kind != .audio, let recipe, recipe.isEdited else { return nil }
        return recipe
    }

    /// The selected files the batch's edits go to: every one but the file they come from.
    var batchTargets: [URL] {
        guard let source = batchSource else { return [] }
        let from = URL(fileURLWithPath: source.source.path).resolvingSymlinksInPath().path
        return selectedFiles.filter { $0.resolvingSymlinksInPath().path != from }
    }

    /// Applies the batch's edits (only `groups`) to the selected files but their source, as one change ⌘Z takes back.
    func applyToSelection(_ groups: Set<SettingGroup>) {
        guard let source = batchSource else { return }
        pasteSettings(groups, to: batchTargets, from: source)
    }

    /// Pastes `source` (the copied settings unless given; only `groups`) onto `files`, as one change ⌘Z takes back.
    func pasteSettings(_ groups: Set<SettingGroup>, to files: [URL], from source: EditRecipe? = nil) {
        guard let source = source ?? copiedSettings, !files.isEmpty else { return }
        flushSave()
        Task { [weak self] in
            var before: [(path: String, recipe: EditRecipe?)] = []
            var failed: [String] = []
            var written = Set<UUID>()
            for file in files {
                let kind = MediaFormat.fromExtension(file.pathExtension)?.kind ?? .image
                // A look, frame or layers mean nothing to audio.
                guard kind != .audio else { continue }
                let stored = await AppModel.shared.recipes.recipe(for: file)
                var recipe = stored ?? EditRecipe(source: EditSource(path: file.standardizedFileURL.path, kind: kind))
                for group in SettingGroup.allCases where groups.contains(group) {
                    group.apply(from: source, to: &recipe)
                }
                // A file no longer there (renamed or deleted in the Finder) or a full disk is said, never counted
                // (audit 2026-11-21-8, B8-3, B8-10).
                guard let kept = await AppModel.shared.recipes.store(recipe) else {
                    failed.append(file.lastPathComponent)
                    continue
                }
                written.insert(kept.id)
                before.append((file.standardizedFileURL.path, stored))
            }
            guard let self else { return }
            registerBatchUndo(before, name: "Apply Edits")
            reloadCurrentRecipe()
            await refreshEdited()
            // By id too: a window still naming a file's old name after a Finder rename is told (round 11, B11-2).
            Self.recipesChanged(Set(before.map(\.path)), ids: written, by: self)
            let name = URL(fileURLWithPath: source.source.path).lastPathComponent
            if let first = failed.first {
                let total = before.count + failed.count
                message = "Edits of “\(name)” applied to \(before.count) of \(total) file\(total == 1 ? "" : "s"); “\(first)” "
                    + "is no longer there or the disk is full."
                filesChanged()
            } else {
                message = before.isEmpty ? "These edits do not apply to audio."
                    : "Edits of “\(name)” applied to \(before.count) file\(before.count == 1 ? "" : "s")."
            }
        }
    }

    /// ⌘Z puts back each file's recipe as it was before a paste; ⇧⌘Z pastes again.
    func registerBatchUndo(_ before: [(path: String, recipe: EditRecipe?)], name: String) {
        guard let manager = undoManager else { return }
        Task { [weak self] in
            var after: [(path: String, recipe: EditRecipe?)] = []
            for item in before {
                after.append((item.path, await AppModel.shared.recipes.recipe(for: URL(fileURLWithPath: item.path))))
            }
            // Left the section meanwhile: ⌘Z elsewhere must never undo this out of sight (R-4602).
            guard let self, window?.section == .edit else { return }
            manager.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated { model.restoreRecipes(before, redo: after) }
            }
            manager.setActionName(name)
        }
    }

    private func restoreRecipes(_ recipes: [(path: String, recipe: EditRecipe?)], redo: [(path: String, recipe: EditRecipe?)]) {
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restoreRecipes(redo, redo: recipes) }
        }
        Task { [weak self] in
            // By id: the store knows where each file is now (B5-1). A file with no recipe before gets the recipe the
            // change made kept blank.
            var written = Set<UUID>()
            for (item, other) in zip(recipes, redo) {
                if let recipe = item.recipe {
                    if let kept = await AppModel.shared.recipes.store(recipe) { written.insert(kept.id) }
                } else if let id = other.recipe?.id {
                    await AppModel.shared.recipes.revert(id: id)
                    written.insert(id)
                }
            }
            self?.reloadCurrentRecipe()
            await self?.refreshEdited()
            Self.recipesChanged(Set(recipes.map(\.path)), ids: written, by: self)
        }
    }

    /// Marks and thumbnails follow recipes written for files other than the open one.
    func refreshEdited() async {
        let edited = await AppModel.shared.recipes.editStamps()
        guard edited != editStamps else { return }
        editStamps = edited
        revision += 1
    }

    /// The open file's recipe as stored now (after a paste or its undo).
    func reloadCurrentRecipe() {
        guard let current else { return }
        let id = recipe?.id
        let generation = saveGenerationNow
        Task { [weak self] in
            // By its id first, wherever the file has gone since (a Finder rename), else by the path (audit 2026-11-21-6,
            // B6-m4).
            let byID: EditRecipe? = if let id { await AppModel.shared.recipes.recipe(id: id) } else { nil }
            let stored: EditRecipe? = if let byID { byID } else { await AppModel.shared.recipes.recipe(for: current) }
            let edited = await AppModel.shared.recipes.editStamps()
            // A change made meanwhile is kept, never replaced by what was stored before it (B7-m1).
            guard let self, self.current == current, let kind, saveGenerationNow == generation else { return }
            if let stored, stored.source.path != current.standardizedFileURL.path,
               FileManager.default.fileExists(atPath: stored.source.path)
            {
                self.current = URL(fileURLWithPath: stored.source.path)
            }
            recipe = stored ?? Self.newRecipe(for: current, kind: kind)
            // A drag under way counts from what is shown now, so its ⌘Z never takes back another window's change (B8-9).
            restartGesture()
            editStamps = edited
            revision += 1
            render()
        }
    }

    /// A new recipe for the file at `url`, knowing that file (its creation date and reference) from the start (B6-m4).
    static func newRecipe(for url: URL, kind: MediaKind) -> EditRecipe {
        let path = url.standardizedFileURL.path
        return EditRecipe(source: EditSource(path: path, reference: RecipeStore.reference(path), created: RecipeStore.created(path),
                                             kind: kind))
    }

    /// Another window wrote the recipe of one of `paths`: shown again here when it is the open file's, unless this window
    /// has a change of its own not yet saved.
    func recipeChanged(_ paths: Set<String>, ids: Set<UUID> = []) {
        guard let current, paths.contains(current.standardizedFileURL.path) || recipe.map({ paths.contains($0.source.path) }) == true
            || recipe.map({ ids.contains($0.id) }) == true,
            !hasUnsavedChange else { return }
        reloadCurrentRecipe()
    }

    /// Exports every selected file with its own recipe and the open file's export settings, as one job (R-4611).
    func exportSelected() {
        let files = selectedFiles
        guard !files.isEmpty, !exporting else { return }
        flushSave()
        let settings = recipe?.export ?? ExportSettings()
        // The open file's export settings go to files of its kind; others keep their own (a photo's size is not a video's).
        let settingsKind = kind
        let destination = exportFolder
        let job = Job(kind: .export, title: files.count == 1 ? "Export “\(files[0].lastPathComponent)”" : "Export \(files.count) Files")
        job.state = .running
        AppModel.shared.jobs.add(job)
        exporting = true
        job.task = Task { [weak self] in
            var done = 0
            var problems: [String] = []
            for (index, file) in files.enumerated() {
                if Task.isCancelled { break }
                job.fraction = Double(index) / Double(files.count)
                job.summaryOverride = "\(index) of \(files.count)"
                let kind = MediaFormat.fromExtension(file.pathExtension)?.kind ?? .image
                var recipe = await AppModel.shared.recipes.recipe(for: file)
                    ?? EditRecipe(source: EditSource(path: file.standardizedFileURL.path, kind: kind))
                if kind == settingsKind { recipe.export = settings }
                let folder = destination ?? file.deletingLastPathComponent()
                let result: Result<URL, Error> = switch kind {
                case .video: await Self.exportVideo(file, recipe: recipe, into: folder) { _ in }
                case .audio: await Self.exportAudio(file, recipe: recipe, into: folder) { _ in }
                default: await Self.export(file, recipe: recipe, into: folder)
                }
                switch result {
                case .success: done += 1
                case let .failure(error) where error is CancellationError: break
                case let .failure(error as ExportedWithProblem):
                    done += 1
                    problems.append(error.localizedDescription)
                case let .failure(error): problems.append("“\(file.lastPathComponent)”: \(error.localizedDescription)")
                }
            }
            let stopped = Task.isCancelled
            AppModel.shared.jobs.finish(job, stopped ? .cancelled : problems.isEmpty ? .completed : .failed(problems[0]), notify: false)
            let summary = files.count == 1 ? (done == 1 ? "Exported “\(files[0].lastPathComponent)”." : "Nothing was exported.")
                : "Exported \(done) of \(files.count) files."
            self?.message = summary + (problems.first.map { " \($0)" } ?? "")
            self?.exporting = false
            AppModel.shared.fileChangeRevision += 1
        }
    }

    /// Copy, Apply Edits and Export Selected for the Media pane's menus.
    func batchMenuItems(for files: [URL]) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if files.count == 1, files[0].standardizedFileURL == current?.standardizedFileURL {
            items.append(ActionMenuItem("Copy Settings") { [weak self] in self?.copySettings() })
        }
        // As the bar under Media offers it: the source's edits to the chosen files but the source itself (D-134).
        if let source = batchSource {
            let from = URL(fileURLWithPath: source.source.path).resolvingSymlinksInPath().path
            let targets = files.filter { $0.resolvingSymlinksInPath().path != from }
            if !targets.isEmpty {
                let title = "Apply Edits of “\(URL(fileURLWithPath: source.source.path).lastPathComponent)”"
                let apply = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let menu = NSMenu(title: title)
                menu.addItem(ActionMenuItem("All") { [weak self] in
                    self?.pasteSettings(Set(SettingGroup.allCases), to: targets, from: source)
                })
                for group in SettingGroup.allCases {
                    menu.addItem(ActionMenuItem(group.label) { [weak self] in self?.pasteSettings([group], to: targets, from: source) })
                }
                apply.submenu = menu
                items.append(apply)
            }
        }
        items.append(ActionMenuItem(files.count == 1 ? "Export" : "Export \(files.count) Files") { [weak self] in
            self?.selection = Set(files.map(\.path))
            self?.exportSelected()
        })
        return items
    }
}
