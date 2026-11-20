import AppKit
import MediaPullCore
import MediaPullLibrary

/// Duplicates under one folder (SPEC section 33): the Library pane scans the library folder holding its folder, each
/// Organise pane the folder it has open (D-114). Marks, the duplicates bar and Trash Extra Copies read from here.
@Observable
final class DuplicateScan {
    private(set) var report: DuplicateFinder.Report?
    private(set) var progress: (done: Int, total: Int)?
    /// The scanned folder is a library folder (copy in the bar says so).
    private(set) var inLibrary = true
    var showOnly = false {
        didSet { if showOnly != oldValue { onChange?() } }
    }

    /// Called when what the grid shows changes: a new report, or Only Duplicates turned on or off.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The scan whose progress may show; a scan that was replaced or stopped reports into nothing.
    @ObservationIgnored private var scanID = UUID()

    private var app: AppModel { .shared }

    isolated deinit { task?.cancel() }

    /// Scans `root` after a short pause, so a burst of reloads costs one scan; nil (or highlighting off) clears the marks.
    func scan(root: URL?, inLibrary: Bool) {
        task?.cancel()
        let id = UUID()
        scanID = id
        guard app.preferences.highlightDuplicates, let root else {
            stop()
            return
        }
        self.inLibrary = inLibrary
        if let report, report.root.standardizedFileURL != root.standardizedFileURL {
            self.report = nil
            showOnly = false
        }
        let finder = app.duplicates
        let sensitivity = app.preferences.duplicateSensitivity
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let report = await finder.scan(root: root, sensitivity: sensitivity) { done, total in
                Task { @MainActor in
                    guard let self, self.scanID == id else { return }
                    self.progress = total > 30 && done < total ? (done, total) : nil
                }
            }
            guard !Task.isCancelled, let self, self.scanID == id else { return }
            self.report = report
            self.progress = nil
            self.onChange?()
        }
    }

    func stop() {
        task?.cancel()
        scanID = UUID()
        let had = report != nil || showOnly
        report = nil
        progress = nil
        showOnly = false
        if had { onChange?() }
    }

    /// The file's group while duplicates are highlighted.
    func group(for url: URL) -> DuplicateFinder.Group? {
        guard app.preferences.highlightDuplicates else { return nil }
        return report?.group(for: url)
    }

    func count(in urls: [URL]) -> Int {
        guard let report else { return 0 }
        return urls.count { report.group(for: $0) != nil }
    }

    /// Only the duplicates of `entries`, copies side by side.
    func onlyDuplicates<T>(_ items: [T], url: (T) -> URL) -> [T] {
        guard let report else { return items }
        let keyed = items.compactMap { item -> (Int, String, T)? in
            let file = url(item)
            guard let group = report.groupOf[file.standardizedFileURL.path] else { return nil }
            return (group, file.lastPathComponent, item)
        }
        return keyed.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }

    /// Grid marks: orange for an identical twin, purple for a look-alike (R-3301).
    func mark(_ info: inout GridCellInfo, for url: URL) {
        guard let group = group(for: url), let report else { return }
        let identical = report.isIdentical(url)
        let color: NSColor = identical ? .systemOrange : .systemPurple
        info.highlight = color
        info.stateSymbol = identical ? "doc.on.doc.fill" : "square.on.square"
        info.stateColor = color
        info.secondary += " · \(group.members.count - 1) other\(group.members.count == 2 ? "" : "s")"
    }

    /// "Copies and Look-alikes" for one file's context menu; choosing one reveals it.
    func copiesMenuItem(for url: URL, reveal: @escaping (URL) -> Void) -> NSMenuItem? {
        guard let group = group(for: url), let report else { return nil }
        let root = report.root.standardizedFileURL.path
        let copies = NSMenu()
        for other in group.members where other != url.standardizedFileURL {
            let relative = String(other.path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let kind = report.areIdentical(url, other) ? "Identical" : "Looks alike"
            copies.addItem(ActionMenuItem("\(relative.isEmpty ? other.lastPathComponent : relative) (\(kind))") { reveal(other) })
        }
        let item = NSMenuItem(title: "Copies and Look-alikes", action: nil, keyEquivalent: "")
        item.submenu = copies
        return item
    }

    /// Trash Extra Copies (R-3305): one file of each duplicate group among `here` stays, the others go to the Trash as one
    /// operation, after a confirmation; ⌘Z puts them all back. Returns a message when there is nothing to do.
    /// `confirm` asks before anything moves (the self-test answers it).
    func trashExtraCopies(here files: [URL], confirm: @escaping @MainActor (_ title: String, _ detail: String) -> Bool = DuplicateScan.ask,
                          perform: @escaping (OrganisePlan) -> Void) -> String?
    {
        guard let report else { return nil }
        let here = Set(files.map(\.standardizedFileURL.path))
        // Copies of each other side by side in one folder: one of them stays there, and copies in other folders (another
        // account's folder, a collab post saved twice, a subfolder shown with Include Subfolders) are never touched
        // (audits 2 and 3, C2-M6, B3-M5).
        let groups = report.groups.flatMap { group -> [(members: [URL], identical: Bool)] in
            let inHere = group.members.filter { here.contains($0.standardizedFileURL.path) }
            return Dictionary(grouping: inHere) { $0.deletingLastPathComponent().standardizedFileURL.path }.values
                .filter { $0.count > 1 }.map { ($0, group.identical) }
        }
        guard !groups.isEmpty else { return "No file here has a copy in this same folder." }
        let members = groups.map(\.members)
        let alike = groups.filter { !$0.identical }.count
        Task {
            let plan = await Task.detached(priority: .userInitiated) { ExtraCopies.plan(members) }.value
            guard !plan.trash.isEmpty else { return }
            let title = "Move \(plan.trash.count) extra cop\(plan.trash.count == 1 ? "y" : "ies") in this folder to the Trash?"
            let detail = "One file of each of the \(groups.count) groups stays: the largest picture, then one with a "
                + "metadata file, then the oldest. This frees \(Format.bytes(plan.bytes))."
                + (alike > 0 ? " \(alike) of the groups only look alike, so their files are not identical." : "")
                + " Undo puts everything back."
            guard confirm(title, detail) else { return }
            perform(FolderOperations.trash(plan.trash))
        }
        return nil
    }

    static func ask(_ title: String, _ detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }
}
