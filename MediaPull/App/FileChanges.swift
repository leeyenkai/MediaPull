import AppKit
import Foundation
import MediaPullCore
import MediaPullLibrary

/// Every change MediaPull makes to files in place (Library and Organise: rename, move, copy in, new folder, Move to Trash,
/// the automatic sorts) runs through the journal, so each can be undone and redone (R-3806, SPEC 21). Records keyed by
/// path (analysis, archive entries) follow the moves, and every window's History refreshes.
extension AppModel {
    func applyChange(_ plan: OrganisePlan, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> JournalEntry {
        var plan = plan
        plan.accountFolders = accountFolderList.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
        let entry = await journal.run(plan, progress: progress)
        await followMoves(entry.moves, changedBy: entry.id)
        // A window's save folder or Organise folder that went to the Trash is left for the folder above (audit 4, B4-m2).
        let trashed = entry.steps.compactMap { step -> String? in
            if case let .trash(original, _) = step { original } else { nil }
        }
        if !trashed.isEmpty {
            foldersGone(trashed)
            // An account folder in the Trash leaves the lists and Activity's Resume at once (audit 10, C10-m5).
            if entry.moves.isEmpty { await refreshAccountFolders(followJobs: false) }
        }
        fileChangeRevision += 1
        return entry
    }

    /// An editor Replace (an edited image, a trimmed video) as one journaled change ⌘Z takes back (D-107): records keyed by
    /// path follow the original to the edit, as they did before the change was journaled.
    func replaceFile(_ original: URL, identity: String?, with edit: URL, named wanted: URL, metadata: Data?, title: String)
        async throws -> (entry: JournalEntry, url: URL)
    {
        let entry = try await journal.replace(original, identity: identity, with: edit, named: wanted, metadata: metadata, title: title)
        let placed = entry.moves.last { !$0.to.hasSuffix(".json") }?.to ?? wanted.path
        await followMoves([(from: original.path, to: placed)], changedBy: entry.id)
        fileChangeRevision += 1
        return (entry, URL(fileURLWithPath: placed))
    }

    /// A metadata edit (section 45) as one journaled change ⌘Z takes back: analysis follows each file written in place to
    /// its new content (R-4506), and listings read `.xmp` files again.
    func editMetadata(_ items: [URL], _ edit: MetadataEdit, title: String,
                      progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> MetadataEditResult
    {
        let files = await Task.detached(priority: .userInitiated) {
            items.flatMap { item in
                [item] + UnitFiles.companions(of: item).filter { MediaFormat.fromExtension($0.pathExtension)?.kind == .image }
            }.map(\.path)
        }.value
        analysis.beginEdit(files)
        let previous = await analysis.currentStates(files)
        // Each file is followed as soon as it is replaced, so a stop part way never leaves analysis behind (D-126).
        let analysis = analysis
        let result = await journal.editMetadata(items, edit, title: title, progress: progress) { file in
            Task { @MainActor in await analysis.followEdit([file], previous: [:], editing: []) }
        }
        analysis.forgetXMP(result.xmpWritten)
        await analysis.followEdit(result.rewritten, previous: previous, editing: files)
        fileChangeRevision += 1
        return result
    }

    /// The `.xmp` files metadata steps write, read again afterwards.
    private static func xmpPaths(_ steps: [JournalStep]) -> [String] {
        steps.compactMap { step in
            if case let .metadata(path, _, _, _) = step, path.lowercased().hasSuffix(".xmp") { path } else { nil }
        }
    }

    /// The files metadata steps write, so analysis waits for them and follows them (R-4506).
    private static func editedPaths(_ steps: [JournalStep]) -> [String] {
        steps.compactMap { step in
            if case let .metadata(path, _, _, _) = step, !path.lowercased().hasSuffix(".xmp") { path } else { nil }
        }
    }

    /// Folders gone from where windows show or save to (trashed, or removed by Undo): the save folder and Organise panes
    /// go to the folder above (audit 4, B4-m2; audit 10, B10-m7).
    private func foldersGone(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        for window in windows {
            window.library.foldersTrashed(paths)
            window.organise.foldersTrashed(paths)
        }
    }

    /// Account folders put back from the Trash or trashed again show in the lists and Activity at once (audit 11, B11-m4,
    /// C11-m3); moves already refresh them.
    private func refreshAfterTrash(_ steps: [JournalStep], moved: [(from: String, to: String)]) async {
        guard moved.isEmpty, steps.contains(where: { if case .trash = $0 { true } else { false } }) else { return }
        await refreshAccountFolders(followJobs: false)
    }

    /// Folders an Undo removed or a Redo trashed.
    private func foldersRemoved(by steps: [JournalStep]) -> [String] {
        steps.compactMap { step -> String? in
            switch step {
            case let .makeFolder(path), let .trash(original: path, _): FileManager.default.fileExists(atPath: path) ? nil : path
            default: nil
            }
        }
    }

    /// Changes that left items under temporary names (a crash part way) are taken back at launch, so no photo stays hidden
    /// (audit 17, B17-M1, C17-M2). Each is a job, so Quit waits for it.
    func takeBackStranded() async {
        // Edits left hidden by an undone Replace go to the Trash first (R1-m2).
        let leftovers = await journal.parkLeftoverEdits()
        if !leftovers.isEmpty {
            let job = Job(kind: .organise, title: "Moving edited versions to the Trash")
            jobs.add(job)
            jobs.finish(job, .failed(leftovers.joined(separator: " ")), notify: false)
        }
        for id in await journal.stranded() {
            guard let entry = await journal.entry(id) else { continue }
            let job = Job(kind: .organise, title: "Taking back “\(entry.title)”")
            jobs.add(job)
            job.state = .running
            let undo = Task { await self.undoChange(id) }
            // Cancel reaches the Undo, which stops at its next stopping point (audit 19, C19-m2).
            job.task = Task { await withTaskCancellationHandler { _ = await undo.value } onCancel: { undo.cancel() } }
            // Said as it went: files still under hidden names are not "done" (audit 18, C18-m1).
            let report = await undo.value
            if let report, report.done > 0, !report.stopped {
                jobs.finish(job, .completed, notify: false)
            } else if report == nil {
                // Undone some other way meanwhile (History): nothing is left under temporary names (audit 20, B20-m3).
                jobs.finish(job, .completed, notify: false)
            } else {
                jobs.finish(job, .failed(report?.skipped.first ?? "Some files are still under temporary names. Undo it in History."),
                            notify: false)
            }
        }
    }

    func undoChange(_ id: UUID, progress: (@Sendable (Double) -> Void)? = nil) async -> UndoReport? {
        // ⌘Z and the History's Undo can both reach an entry: the second one does nothing.
        guard let entry = await journal.entry(id), !entry.undone else { return nil }
        if let refusal = libraryFolderRefusal(entry.steps) { return refusal }
        let edited = Self.editedPaths(entry.steps)
        analysis.beginEdit(edited)
        let previous = await analysis.currentStates(edited)
        let report = await journal.undo(id, progress: progress)
        analysis.forgetXMP(Self.xmpPaths(entry.steps))
        await analysis.followEdit(report.rewritten, previous: previous, editing: edited)
        await followMoves(report.moves, changedBy: id)
        foldersGone(foldersRemoved(by: entry.steps))
        await refreshAfterTrash(entry.steps, moved: report.moves)
        fileChangeRevision += 1
        return report
    }

    func redoChange(_ id: UUID, progress: (@Sendable (Double) -> Void)? = nil) async -> UndoReport {
        let before = await journal.entry(id)
        if let entry = before, let refusal = libraryFolderRefusal(entry.undoneSteps ?? []) { return refusal }
        let edited = Self.editedPaths(before?.undoneSteps ?? [])
        analysis.beginEdit(edited)
        let previous = await analysis.currentStates(edited)
        let report = await journal.redo(id, progress: progress)
        analysis.forgetXMP(Self.xmpPaths(before?.undoneSteps ?? []))
        await analysis.followEdit(report.rewritten, previous: previous, editing: edited)
        await followMoves(report.moves, changedBy: id)
        if let entry = await journal.entry(id) {
            foldersGone(foldersRemoved(by: entry.steps))
            await refreshAfterTrash(entry.steps, moved: report.moves)
        }
        fileChangeRevision += 1
        return report
    }

    /// Undo and Redo keep the rule changes keep: a library folder, or a folder holding one, is never moved, renamed or put
    /// in the Trash as a file (B4-M2, audit 9, B9-m6).
    private func libraryFolderRefusal(_ steps: [JournalStep]) -> UndoReport? {
        let roots = roots.map { AccountFolderStore.key($0.url.path) }
        func holdsRoot(_ path: String) -> Bool {
            let key = AccountFolderStore.key(path)
            return roots.contains { $0 == key || $0.hasPrefix(key + "/") }
        }
        let touches = steps.contains { step in
            switch step {
            case let .move(from, to, _, _): holdsRoot(from) || holdsRoot(to)
            case let .trash(original, _): holdsRoot(original)
            // A folder made or copied that became a library folder is never removed or trashed by Undo (B10-m2).
            case let .clone(_, to, _): holdsRoot(to)
            case let .makeFolder(path): holdsRoot(path)
            case .metadata: false
            }
        }
        guard touches else { return nil }
        return UndoReport(restored: 0, skipped: ["It would move a library folder, so nothing was changed. Use Remove from Library "
                + "or Locate in its menu instead."], moves: [])
    }

    private func followMoves(_ moves: [(from: String, to: String)], changedBy _: UUID) async {
        guard !moves.isEmpty else { return }
        await analysis.noteMoves(moves)
        await recipes.movePaths(moves)
        await store?.moveArchivePaths(moves)
        await accountFolders.moveFolders(moves)
        // Queued and running jobs show where their folder is now (audit 6, B6-m8), once (audit 8, B8-m6).
        LibraryModel.followQueuedDestinations(moves)
        await refreshAccountFolders(followJobs: false)
        // A window's save folder moved or renamed (in Organise, say) is followed, so Save goes where it went (B3-m8).
        for window in windows {
            let held = [window.library.selectedFolder, window.library.otherFolder].compactMap { $0?.standardizedFileURL.path }
            for move in moves where held.contains(where: { $0 == move.from || $0.hasPrefix(move.from + "/") }) {
                window.library.rootMoved(from: URL(fileURLWithPath: move.from, isDirectory: true),
                                         to: URL(fileURLWithPath: move.to, isDirectory: true))
            }
            // Organise's folders follow too, so its panes and its target stay on the folders they showed (audit 4, B4-m2).
            window.organise.foldersMoved(moves)
            window.edit.followMoves(moves)
        }
    }
}

/// The undo manager's target for one file change.
final class FileChangeUndoTarget {}

extension OrganisePlan {
    /// Copies (which may cross volumes and take a while) and long changes show in Activity; small changes are listed only
    /// while they run, so Quit still waits for them (audit 4, B4-m7).
    var showsInActivity: Bool { cloneCount > 0 || moves.count + itemsToTrash.count > 20 }
}

extension WindowModel {
    /// ⌘Z undoes the window's last file change, whichever section made it; ⇧⌘Z redoes it (SPEC 21). Text fields keep
    /// their own typing undo, as in any Mac app. Each change has its own undo target, so a change undone from the History
    /// or the toolbar can be taken off the ⌘Z stack (audit 4, B4-m8).
    func registerUndo(_ entry: JournalEntry) {
        guard let manager = hostWindow?.undoManager else { return }
        let target = undoTargets[entry.id] ?? FileChangeUndoTarget()
        undoTargets[entry.id] = target
        manager.registerUndo(withTarget: target) { [weak self] _ in
            MainActor.assumeIsolated { self?.undoChange(entry) }
        }
        manager.setActionName(entry.title)
        lastUndoRegistered = entry.id
        undoOrder.removeAll { $0 == entry.id }
        undoOrder.append(entry.id)
    }

    func undoChange(_ entry: JournalEntry) {
        if reinstating == entry.id, let manager = hostWindow?.undoManager, manager.isUndoing {
            // A Redo that did nothing: back on the redo stack, untouched (audit 14, C14-M3).
            reinstating = nil
            let target = undoTargets[entry.id] ?? FileChangeUndoTarget()
            undoTargets[entry.id] = target
            manager.registerUndo(withTarget: target) { [weak self] _ in
                MainActor.assumeIsolated { self?.redoChange(entry) }
            }
            manager.setActionName(entry.title)
            lastRedoRegistered = entry.id
            undoOrder.removeAll { $0 == entry.id }
            return
        }
        let viaManager = hostWindow?.undoManager?.isUndoing ?? false
        if let manager = hostWindow?.undoManager {
            if manager.isUndoing {
                // Only an undo the undo manager is running may register the redo: it then lands on the redo stack.
                undoOrder.removeAll { $0 == entry.id }
                let target = undoTargets[entry.id] ?? FileChangeUndoTarget()
                undoTargets[entry.id] = target
                manager.registerUndo(withTarget: target) { [weak self] _ in
                    MainActor.assumeIsolated { self?.redoChange(entry) }
                }
                manager.setActionName(entry.title)
                lastRedoRegistered = entry.id
            } else if undoTargets[entry.id] != nil {
                // From the History or the toolbar: the change on top of ⌘Z's stack is undone through it, so ⇧⌘Z redoes it;
                // one further down leaves the stack, so ⌘Z never reaches a change already undone.
                if undoOrder.last == entry.id, manager.canUndo, manager.undoActionName == entry.title {
                    manager.undo()
                    return
                }
                forgetUndo(entry.id)
            }
        }
        // Another window's ⌘Z stack may hold the change too.
        for other in app.windows where other !== self && !(hostWindow?.undoManager?.isUndoing ?? false) {
            other.forgetUndo(entry.id)
        }
        undoing.insert(entry.id)
        let job = changeJob(entry, undoing: true)
        let task = Task {
            var report: UndoReport?
            defer {
                finish(job, report: report)
                undoing.remove(entry.id)
            }
            report = await app.undoChange(entry.id, progress: Self.progress(of: job))
            guard let report else {
                // Undone elsewhere, or no longer kept in the undo history (audit 18, B18-m6): either way, off ⌘Z's stack.
                forgetUndo(entry.id)
                let kept = await app.journal.entry(entry.id) != nil
                showFileMessage(kept ? "“\(entry.title)” was already undone." : "“\(entry.title)” is no longer in the undo history.")
                return
            }
            // Nothing undone is said as such (audit 10, C10-m3, B10-m3). The change is still done, so ⇧⌘Z has nothing to
            // redo; History's Undo tries again (audit 13, B13-m3, B13-m4).
            if report.stopped {
                // Cancelled or quitting: what was undone is recorded; History undoes the rest (R-3807, audit 15, B15-M1).
                forgetUndo(entry.id)
                showFileMessage("“\(entry.title)” stopped part way: \(report.restored) item\(report.restored == 1 ? "" : "s") put back. "
                    + "History undoes the rest.", unsaved: report.unsaved)
            } else if report.done == 0 {
                // Still done: ⌘Z offers it again once what was in the way is gone (audit 14, C14-M3).
                if viaManager { putBack(entry, onUndoStack: true) } else { forgetUndo(entry.id) }
                showFileMessage("Nothing of “\(entry.title)” could be undone"
                    + (report.skipped.isEmpty ? "." : ": " + report.skipped.prefix(2).joined(separator: "; ")), unsaved: report.unsaved)
            } else if report.restored == 0, report.skipped.isEmpty {
                // A New Folder taken back puts no item back (B11-m5).
                showFileMessage("Undid “\(entry.title)”.", unsaved: report.unsaved)
            } else {
                showFileMessage(report.skipped.isEmpty
                    ? "Undid “\(entry.title)”: \(report.restored) item\(report.restored == 1 ? "" : "s") put back."
                    : "Undid “\(entry.title)” except \(report.skipped.count): " + report.skipped.prefix(2).joined(separator: "; "),
                    unsaved: report.unsaved)
            }
        }
        job.task = task
    }

    /// The change ⌘Z undoes in this window: the top of its file-change stack, whichever section made it.
    var lastFileChange: UUID? { undoOrder.last }

    /// The toolbar's Undo: exactly the change ⌘Z would undo, so ⇧⌘Z redoes it (audit 5, B5-m3). `known` is the History's
    /// list. False when this window has no file change left to undo.
    @discardableResult
    func undoLastFileChange(known: [JournalEntry]) -> Bool {
        while let id = lastFileChange {
            guard let entry = known.first(where: { $0.id == id }) else {
                // Not in the History yet (it refreshes just after a change): the journal has it.
                Task {
                    if let entry = await app.journal.entry(id), !entry.undone {
                        undoChange(entry)
                    } else {
                        // Undone elsewhere, or no longer kept: off the stack, so the next click reaches the change below
                        // (audit 19, B19-m3).
                        forgetUndo(id)
                        let kept = await app.journal.entry(id) != nil
                        showFileMessage(kept ? "That change was already undone." : "That change is no longer in the undo history.")
                    }
                }
                return true
            }
            if entry.undone {
                // Undone elsewhere since: it leaves the stack, and the change below it is next.
                forgetUndo(id)
                undoOrder.removeAll { $0 == id }
                continue
            }
            undoChange(entry)
            return true
        }
        return false
    }

    /// Takes a change off this window's undo and redo stacks.
    func forgetUndo(_ id: UUID) {
        // The markers go with the actions, so put-back never runs another change's action (audit 16, B16-m2).
        if lastUndoRegistered == id { lastUndoRegistered = nil }
        if lastRedoRegistered == id { lastRedoRegistered = nil }
        guard let target = undoTargets.removeValue(forKey: id) else { return }
        hostWindow?.undoManager?.removeAllActions(withTarget: target)
        undoOrder.removeAll { $0 == id }
    }

    func redoChange(_ entry: JournalEntry) {
        if reinstating == entry.id, hostWindow?.undoManager?.isRedoing ?? false {
            // An Undo that did nothing: back on the undo stack, untouched (audit 14, C14-M3).
            reinstating = nil
            registerUndo(entry)
            return
        }
        let viaManager = hostWindow?.undoManager?.isRedoing ?? false
        registerUndo(entry)
        redoing.insert(entry.id)
        let job = changeJob(entry, undoing: false)
        let task = Task {
            var result: UndoReport?
            defer {
                finish(job, report: result)
                redoing.remove(entry.id)
            }
            let report = await app.redoChange(entry.id, progress: Self.progress(of: job))
            result = report
            // Nothing done again is said as such (audit 7, B7-m6).
            // Something done again but no file moved (a New Folder made again) is a redo too (audit 8, B8-m2).
            if report.stopped {
                forgetUndo(entry.id)
                showFileMessage("“\(entry.title)” stopped part way. History does the rest again.", unsaved: report.unsaved)
            } else if report.done == 0 {
                // The change is still undone: ⇧⌘Z offers it again, and History's Redo (audit 13, B13-m3; audit 14, C14-M3).
                if viaManager { putBack(entry, onUndoStack: false) } else { forgetUndo(entry.id) }
                showFileMessage("Nothing of “\(entry.title)” could be done again"
                    + (report.skipped.isEmpty ? "." : ": " + report.skipped.prefix(2).joined(separator: "; ")), unsaved: report.unsaved)
            } else {
                showFileMessage(report.skipped.isEmpty
                    ? "Redid “\(entry.title)”."
                    : "Redid “\(entry.title)” except \(report.skipped.count): " + report.skipped.prefix(2).joined(separator: "; "),
                    unsaved: report.unsaved)
            }
        }
        job.task = task
    }

    /// Puts a change ⌘Z or ⇧⌘Z could not act on back where it was: the undo manager runs the opposite action it has just
    /// registered, which registers the change again on the original stack without clearing the other one.
    private func putBack(_ entry: JournalEntry, onUndoStack: Bool) {
        guard let manager = hostWindow?.undoManager, manager.groupingLevel == 0,
              onUndoStack ? manager.canRedo && lastRedoRegistered == entry.id : manager.canUndo && lastUndoRegistered == entry.id
        else {
            forgetUndo(entry.id)
            return
        }
        reinstating = entry.id
        if onUndoStack { manager.redo() } else { manager.undo() }
        if reinstating == entry.id {
            reinstating = nil
            forgetUndo(entry.id)
        }
    }

    /// Every Undo and Redo is a job, as every change is, so Quit waits for it, whatever its size: a few videos moved
    /// between disks take as long as many small files (R-3807, audit 16, B16-M1, B16-M3). Running, with its task, so Cancel
    /// stops it between items (B15-M1).
    private func changeJob(_ entry: JournalEntry, undoing: Bool) -> Job {
        let job = Job(kind: .organise, title: (undoing ? "Undoing " : "Redoing ") + "“\(entry.title)”")
        app.jobs.add(job)
        job.state = .running
        return job
    }

    /// How far an Undo or Redo has got, shown on its job (R-3807, audit 17, C17-m9).
    static func progress(of job: Job) -> @Sendable (Double) -> Void {
        let id = job.id
        return { fraction in
            Task { @MainActor in AppModel.shared.jobs.jobs.first { $0.id == id }?.fraction = fraction }
        }
    }

    /// Ends an Undo or Redo job as it went; one that went as asked leaves Activity, as small changes do (audit 16, B16-m3).
    private func finish(_ job: Job, report: UndoReport?) {
        guard let report else {
            app.jobs.finish(job, .failed("It was undone already, or is no longer in the undo history."), notify: false)
            return
        }
        if report.stopped {
            app.jobs.finish(job, .cancelled, notify: false)
        } else if report.done == 0 {
            app.jobs.finish(job, .failed(report.skipped.first ?? "Nothing could be done."), notify: false)
        } else {
            app.jobs.finish(job, .completed, notify: false)
            if report.skipped.isEmpty { app.jobs.jobs.removeAll { $0 === job } }
        }
    }

    /// A result of a file change, shown in the section the person is looking at.
    func showFileMessage(_ text: String, unsaved: Bool = false) {
        let text = unsaved ? text + " " + OperationJournal.unsavedNote : text
        switch section {
        case .organise: organise.message = text
        case .collect: library.message = text
        case .devices: devices.message = text
        case .edit: edit.message = text
        }
    }
}
