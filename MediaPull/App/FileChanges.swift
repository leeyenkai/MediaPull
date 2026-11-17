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
        }
    }
}

extension WindowModel {
    /// ⌘Z undoes the window's last file change, whichever section made it; ⇧⌘Z redoes it (SPEC 21). Text fields keep
    /// their own typing undo, as in any Mac app.
    func registerUndo(_ entry: JournalEntry) {
        guard let manager = hostWindow?.undoManager else { return }
        manager.registerUndo(withTarget: self) { window in
            MainActor.assumeIsolated { window.undoChange(entry) }
        }
        manager.setActionName(entry.title)
    }

    func undoChange(_ entry: JournalEntry) {
        // Only an undo the undo manager is running may register the redo: it then lands on the redo stack. From the
        // History it would land on the undo stack, and ⌘Z would do the change again.
        if let manager = hostWindow?.undoManager, manager.isUndoing {
            manager.registerUndo(withTarget: self) { window in
                MainActor.assumeIsolated { window.redoChange(entry) }
            }
            manager.setActionName(entry.title)
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
