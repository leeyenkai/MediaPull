import AppKit
import Foundation
import MediaPullLibrary

/// Every change MediaPull makes to files in place (Library and Organise: rename, move, copy in, new folder, Move to Trash,
/// the automatic sorts) runs through the journal, so each can be undone and redone (R-3806, SPEC 21). Records keyed by
/// path (analysis, archive entries) follow the moves, and every window's History refreshes.
extension AppModel {
    func applyChange(_ plan: OrganisePlan, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> JournalEntry {
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

    func undoChange(_ id: UUID) async -> UndoReport? {
        // ⌘Z and the History's Undo can both reach an entry: the second one does nothing.
        guard let entry = await journal.entry(id), !entry.undone else { return nil }
        if let refusal = libraryFolderRefusal(entry.steps) { return refusal }
        let report = await journal.undo(id)
        await followMoves(report.moves, changedBy: id)
        foldersGone(foldersRemoved(by: entry.steps))
        await refreshAfterTrash(entry.steps, moved: report.moves)
        fileChangeRevision += 1
        return report
    }

    func redoChange(_ id: UUID) async -> UndoReport {
        let before = await journal.entry(id)
        if let entry = before, let refusal = libraryFolderRefusal(entry.undoneSteps ?? []) { return refusal }
        let report = await journal.redo(id)
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
            }
        }
        guard touches else { return nil }
        return UndoReport(restored: 0, skipped: ["It would move a library folder, so nothing was changed. Use Remove from Library "
                + "or Locate in its menu instead."], moves: [])
    }

    private func followMoves(_ moves: [(from: String, to: String)], changedBy _: UUID) async {
        guard !moves.isEmpty else { return }
        await analysis.noteMoves(moves)
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
        undoOrder.removeAll { $0 == entry.id }
        undoOrder.append(entry.id)
    }

    func undoChange(_ entry: JournalEntry) {
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
        Task {
            guard let report = await app.undoChange(entry.id) else {
                showFileMessage("“\(entry.title)” was already undone.")
                return
            }
            // Nothing undone is said as such (audit 10, C10-m3, B10-m3). The change is still done, so ⇧⌘Z has nothing to
            // redo; History's Undo tries again (audit 13, B13-m3, B13-m4).
            if report.done == 0 {
                forgetUndo(entry.id)
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
                    if let entry = await app.journal.entry(id), !entry.undone { undoChange(entry) }
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
        guard let target = undoTargets.removeValue(forKey: id) else { return }
        hostWindow?.undoManager?.removeAllActions(withTarget: target)
        undoOrder.removeAll { $0 == id }
    }

    func redoChange(_ entry: JournalEntry) {
        registerUndo(entry)
        Task {
            let report = await app.redoChange(entry.id)
            // Nothing done again is said as such (audit 7, B7-m6).
            // Something done again but no file moved (a New Folder made again) is a redo too (audit 8, B8-m2).
            if report.done == 0 {
                // The change is still undone: ⌘Z has nothing to undo, and History's Redo tries again (audit 13, B13-m3).
                forgetUndo(entry.id)
                showFileMessage("Nothing of “\(entry.title)” could be done again"
                    + (report.skipped.isEmpty ? "." : ": " + report.skipped.prefix(2).joined(separator: "; ")), unsaved: report.unsaved)
            } else {
                showFileMessage(report.skipped.isEmpty
                    ? "Redid “\(entry.title)”."
                    : "Redid “\(entry.title)” except \(report.skipped.count): " + report.skipped.prefix(2).joined(separator: "; "),
                    unsaved: report.unsaved)
            }
        }
    }

    /// A result of a file change, shown in the section the person is looking at.
    func showFileMessage(_ text: String, unsaved: Bool = false) {
        let text = unsaved ? text + " " + OperationJournal.unsavedNote : text
        if section == .organise { organise.message = text } else { library.message = text }
    }
}
