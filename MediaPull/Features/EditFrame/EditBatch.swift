import AppKit
import Foundation
import MediaPullCore
import MediaPullEdit

/// What Paste Settings carries (R-4611).
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

/// Copy Settings, Paste Settings and Export Selected (R-4611).
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

    /// Pastes the copied settings (only `groups`) onto `files`, as one change ⌘Z takes back.
    func pasteSettings(_ groups: Set<SettingGroup>, to files: [URL]) {
        guard let source = copiedSettings, !files.isEmpty else { return }
        flushSave()
        Task { [weak self] in
            var before: [(path: String, recipe: EditRecipe?)] = []
            for file in files {
                let kind = MediaFormat.fromExtension(file.pathExtension)?.kind ?? .image
                // A look, frame or layers mean nothing to audio.
                guard kind != .audio else { continue }
                let stored = await AppModel.shared.recipes.recipe(for: file)
                before.append((file.standardizedFileURL.path, stored))
                var recipe = stored ?? EditRecipe(source: EditSource(path: file.standardizedFileURL.path, kind: kind))
                for group in SettingGroup.allCases where groups.contains(group) {
                    group.apply(from: source, to: &recipe)
                }
                await AppModel.shared.recipes.save(recipe)
            }
            guard let self else { return }
            registerBatchUndo(before, name: "Paste Settings")
            reloadCurrentRecipe()
            message = before.isEmpty ? "These settings do not apply to audio."
                : "Settings pasted onto \(before.count) file\(before.count == 1 ? "" : "s")."
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
            for (item, other) in zip(recipes, redo) {
                if let recipe = item.recipe {
                    await AppModel.shared.recipes.save(recipe)
                } else if let id = other.recipe?.id {
                    await AppModel.shared.recipes.revert(id: id)
                }
            }
            self?.reloadCurrentRecipe()
        }
    }

    /// The open file's recipe as stored now (after a paste or its undo).
    func reloadCurrentRecipe() {
        guard let current else { return }
        let id = recipe?.id
        Task { [weak self] in
            // By its id first, wherever the file has gone since (a Finder rename), else by the path (audit 2026-11-21-6,
            // B6-m4).
            let byID: EditRecipe? = if let id { await AppModel.shared.recipes.recipe(id: id) } else { nil }
            let stored: EditRecipe? = if let byID { byID } else { await AppModel.shared.recipes.recipe(for: current) }
            let edited = await AppModel.shared.recipes.editedPaths()
            guard let self, self.current == current, let kind else { return }
            if let stored, stored.source.path != current.standardizedFileURL.path,
               FileManager.default.fileExists(atPath: stored.source.path)
            {
                self.current = URL(fileURLWithPath: stored.source.path)
            }
            recipe = stored ?? Self.newRecipe(for: current, kind: kind)
            editedPaths = edited
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

    /// Another window saved this recipe: shown again here unless this window has a change of its own not yet saved
    /// (audit 2026-11-21-6, B6-2).
    func recipeSavedElsewhere(_ id: UUID) {
        guard recipe?.id == id, !hasUnsavedChange else { return }
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

    /// Copy, Paste and Export Selected for the Media pane's menus.
    func batchMenuItems(for files: [URL]) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if files.count == 1, files[0].standardizedFileURL == current?.standardizedFileURL {
            items.append(ActionMenuItem("Copy Settings") { [weak self] in self?.copySettings() })
        }
        if copiedSettings != nil {
            let paste = NSMenuItem(title: "Paste Settings", action: nil, keyEquivalent: "")
            let menu = NSMenu(title: "Paste Settings")
            menu.addItem(ActionMenuItem("All") { [weak self] in self?.pasteSettings(Set(SettingGroup.allCases), to: files) })
            for group in SettingGroup.allCases {
                menu.addItem(ActionMenuItem(group.label) { [weak self] in self?.pasteSettings([group], to: files) })
            }
            paste.submenu = menu
            items.append(paste)
        }
        items.append(ActionMenuItem(files.count == 1 ? "Export" : "Export \(files.count) Files") { [weak self] in
            self?.selection = Set(files.map(\.path))
            self?.exportSelected()
        })
        return items
    }
}
