import AppKit
import Foundation
import MediaPullLibrary

/// Every change MediaPull makes to files in place (Library and Organise: rename, move, copy in, new folder, Move to Trash,
/// the automatic sorts) runs through the journal, so each can be undone and redone (R-3806, SPEC 21). Records keyed by
/// path (analysis, archive entries) follow the moves, and every window's History refreshes.
extension AppModel {
    func applyChange(_ plan: OrganisePlan, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> JournalEntry {
        let entry = await journal.run(plan, progress: progress)
        await followMoves(entry.moves)
        // A window's save folder or Organise folder that went to the Trash is left for the folder above (audit 4, B4-m2).
        let trashed = entry.steps.compactMap { step -> String? in
            if case let .trash(original, _) = step { original } else { nil }
        }
        if !trashed.isEmpty {
            for window in windows {
                window.library.foldersTrashed(trashed)
                window.organise.foldersTrashed(trashed)
            }
        }
        fileChangeRevision += 1
        return entry
    }

    func undoChange(_ id: UUID) async -> UndoReport? {
        // ⌘Z and the History's Undo can both reach an entry: the second one does nothing.
        guard let entry = await journal.entry(id), !entry.undone else { return nil }
        let report = await journal.undo(id)
        await followMoves(report.moves)
        fileChangeRevision += 1
        return report
    }

    func redoChange(_ id: UUID) async -> UndoReport {
        let report = await journal.redo(id)
        await followMoves(report.moves)
        fileChangeRevision += 1
        return report
    }

    private func followMoves(_ moves: [(from: String, to: String)]) async {
        guard !moves.isEmpty else { return }
        await analysis.noteMoves(moves)
        await store?.moveArchivePaths(moves)
        await accountFolders.moveFolders(moves)
        await refreshAccountFolders()
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
            showFileMessage(report.skipped.isEmpty
                ? "Undid “\(entry.title)”: \(report.restored) item\(report.restored == 1 ? "" : "s") put back."
                : "Undid “\(entry.title)” except \(report.skipped.count): " + report.skipped.prefix(2).joined(separator: "; "))
        }
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
            showFileMessage(report.skipped.isEmpty
                ? "Redid “\(entry.title)”."
                : "Redid “\(entry.title)” except \(report.skipped.count): " + report.skipped.prefix(2).joined(separator: "; "))
        }
    }

    /// A result of a file change, shown in the section the person is looking at.
    func showFileMessage(_ text: String) {
        if section == .organise { organise.message = text } else { library.message = text }
    }
}
