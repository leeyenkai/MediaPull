import MediaPullCore
import MediaPullLibrary
import MediaPullStore
import SwiftUI
import UniformTypeIdentifiers

struct LibraryPane: View {
    @Bindable var model: WindowModel
    @Bindable var library: LibraryModel
    private var app: AppModel { .shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Library").font(.headline)
                Spacer()
                Menu {
                    Button("Add Folder…") { library.promptForRoot() }
                    if let folder = library.selectedFolder {
                        Button("New Folder in “\(folder.lastPathComponent)”") { library.newFolder(in: folder) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    }
                    Divider()
                    Button("Refresh") { library.refreshTree() }
                    Divider()
                    DuplicateCommands(library: library)
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add a library folder or create a new folder")
                ViewModePicker(model: model, pane: .library)
                PaneMenu(pane: .library, window: model)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(app.preferences.theme.headerBackground)
            Divider()
            if app.roots.isEmpty, library.otherFolder == nil {
                NoRootsView(library: library)
            } else {
                VStack(spacing: 0) {
                    // A compact tree: the media grid gets the room. Column view is its own tree (R-1710).
                    if model.viewMode(for: .library) != .column {
                        FolderTree(model: model, library: library)
                            .frame(minHeight: 60, idealHeight: 150, maxHeight: 190)
                        Divider()
                    }
                    FolderContents(model: model, library: library)
                        .frame(minHeight: 160)
                }
            }
        }
    }
}

struct NoRootsView: View {
    @Bindable var library: LibraryModel
    private var app: AppModel { .shared }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus").font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            Text("Choose where to save").font(.headline)
            Text("Saved media goes into library folders. Drag items onto a folder to save them there.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Use Pictures/MediaPull") { Task { await app.addDefaultRoot() } }
                .buttonStyle(.borderedProminent)
            Button("Choose a Folder…") { library.promptForRoot() }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FolderTree: View {
    @Bindable var model: WindowModel
    @Bindable var library: LibraryModel
    private var app: AppModel { .shared }

    var body: some View {
        // Reading the revisions makes the tree rebuild its nodes (and re-read folders) after changes,
        // while expansion state, keyed by path, is kept.
        let rootNodes = library.treeNodes()
        List(selection: Binding(get: { library.selectedFolder?.path }, set: { path in
            library.selectedFolder = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
        })) {
            ForEach(rootNodes) { node in
                OutlineGroup(node, children: \.children) { child in
                    FolderRow(model: model, library: library, node: child, root: app.roots.first { $0.id == node.rootID })
                        .tag(child.url.path)
                }
            }
        }
        .listStyle(.sidebar)
        .onAppear {
            if library.selectedFolder == nil { library.selectedFolder = app.defaultRoot?.url }
        }
        .onChange(of: app.roots.map(\.id)) { _, _ in
            if let other = library.otherFolder, app.root(containing: other) != nil { library.otherFolder = nil }
            if library.selectedFolder.map({ !library.shows($0) }) ?? true {
                library.selectedFolder = app.defaultRoot?.url
            }
        }
    }
}

struct FolderRow: View {
    @Bindable var model: WindowModel
    @Bindable var library: LibraryModel
    var node: FolderNode
    var root: LibraryRootInfo?
    @State private var targeted = false
    @State private var draft = ""
    @FocusState private var editing: Bool
    private var app: AppModel { .shared }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: node.isRoot ? (root?.isDefault == true ? "folder.fill.badge.person.crop" : "folder.fill") : "folder")
                .foregroundStyle(node.isRoot && root != nil ? Color.accentColor : .secondary)
            if library.renaming == node.url.path, !node.isRoot || root != nil {
                TextField("Name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($editing)
                    .onSubmit {
                        // A library folder's name in the list is its own (R-1702); the folder on disk keeps its name.
                        if let root {
                            library.renaming = nil
                            Task { await app.renameRoot(root.id, to: draft) }
                        } else {
                            library.commitRename(node.url, to: draft)
                        }
                    }
                    .onExitCommand { library.renaming = nil }
                    .onAppear {
                        draft = node.name
                        editing = true
                    }
            } else {
                Text(node.name).lineLimit(1)
            }
            if node.isRoot, root == nil {
                Spacer(minLength: 4)
                Text("Not in Library")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .background(.quaternary, in: Capsule())
            }
            if node.isRoot, let root, app.missingRoots.contains(root.id) {
                Spacer(minLength: 4)
                Text("Not Found")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5)
                    .background(.quaternary, in: Capsule())
                    .help("This folder was deleted, or is on a disk that is not connected. Use Locate… if it was moved.")
            } else if node.isRoot, let root {
                Spacer(minLength: 4)
                Text(root.layout.shortLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.vertical, 1)
        .background(targeted ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .onDrop(of: [DragTypes.itemsUTType, .fileURL], isTargeted: $targeted) { providers in
            handleDrop(providers)
        }
        .contextMenu {
            if !model.selection.isEmpty {
                Button("Save \(model.selection.count) Selected Item\(model.selection.count == 1 ? "" : "s") Here") {
                    app.save(model.selectedItems, from: model, to: node.url)
                }
                Divider()
            }
            Button("New Folder") { library.newFolder(in: node.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            Button("Organise This Folder…") {
                model.organise.open(node.url)
                model.section = .organise
            }
            Button("Check Folder") { library.checkFolder(node.url) }
            if let match = library.accountMatch(for: node.url) {
                Divider()
                Button("Update @\(match.account)") { library.update(match) }
                Button("Find Missing from @\(match.account)") { library.update(match, findMissing: true) }
            }
            if case let inside = app.accountFolders(inside: node.url).count, inside > 1 {
                Button("Update All Accounts (\(inside))") { library.updateAll(inside: node.url) }
            }
            if node.isRoot, let root {
                Divider()
                Button("Rename in List") { library.rename(node.url) }
                if app.missingRoots.contains(root.id) {
                    Button("Locate…") { app.locateRoot(root.id) }
                }
                if !root.isDefault {
                    Button("Use as Default Save Location") {
                        Task {
                            await app.store?.setDefault(root.id)
                            await app.reloadRoots()
                        }
                    }
                }
                Menu("Layout") {
                    ForEach(SaveLayout.allCases, id: \.self) { layout in
                        Button(layout.label + (root.layout == layout ? " ✓" : "")) {
                            Task {
                                await app.store?.updateRoot(root.id, layout: layout)
                                await app.reloadRoots()
                            }
                        }
                    }
                }
                Button("Remove from Library") { Task { await app.removeRoot(root.id) } }
            } else if node.isRoot {
                Divider()
                Button("Add to Library") {
                    Task {
                        await app.addRoot(node.url)
                        library.otherFolder = nil
                    }
                }
                Button("Stop Showing") {
                    library.otherFolder = nil
                    if library.selectedFolder.map({ !library.shows($0) }) ?? true { library.selectedFolder = app.defaultRoot?.url }
                }
            } else {
                Button("Rename") { library.rename(node.url) }
                Divider()
                Button("Move to Trash") { library.trash([node.url]) }
            }
        }
        .help(node.url.path)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let folder = node.url
        let move = !NSEvent.modifierFlags.contains(.option)
        let itemProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(DragTypes.itemsIdentifier) }
        if !itemProviders.isEmpty {
            Task {
                var payloads: [ItemDragPayload] = []
                for provider in itemProviders {
                    if let data = await provider.loadData(type: DragTypes.itemsIdentifier),
                       let payload = try? JSONDecoder().decode(ItemDragPayload.self, from: data)
                    {
                        payloads.append(payload)
                    }
                }
                for (windowID, group) in Dictionary(grouping: payloads, by: \.window) {
                    app.window(windowID)?.save(group.map(\.id), to: folder)
                }
            }
            return true
        }
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in fileProviders {
                if let data = await provider.loadData(type: UTType.fileURL.identifier),
                   let url = URL(dataRepresentation: data, relativeTo: nil)
                {
                    urls.append(url)
                }
            }
            let inLibrary = urls.allSatisfy { app.root(containing: $0) != nil }
            library.importFiles(urls, into: folder, move: move && inLibrary)
        }
        return true
    }
}

extension NSItemProvider {
    func loadData(type: String) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}

struct FolderContents: View {
    @Bindable var model: WindowModel
    @Bindable var library: LibraryModel
    private var app: AppModel { .shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(library.selectedFolder?.lastPathComponent ?? "No folder selected")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let match = library.account {
                    Button("Update @\(match.account)") { library.update(match) }
                        .controlSize(.small)
                        .disabled(library.isUpdating(match.folder))
                        .help("Add what @\(match.account) posted that “\(match.folder.lastPathComponent)” doesn't have yet. "
                            + "Files you deleted from it stay deleted.")
                }
                if let folder = library.selectedFolder, !model.selection.isEmpty {
                    Button("Save \(model.selection.count) Here") { app.save(model.selectedItems, from: model, to: folder) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .help("Save the selected extracted items into this folder (⌘S)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            if library.selectedFolder != nil, !columns {
                QueryBar(query: $library.query, includeSubfolders: $library.includeSubfolders, entries: library.entries,
                         focusToken: model.searchFocusTokens[.library] ?? 0)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            if let warning = library.selectedFolder.flatMap({ app.root(containing: $0) })
                .flatMap({ AppModel.locationWarning(for: $0.url) })
            {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
            if let message = library.message {
                Text(message).font(.caption).foregroundStyle(.red).padding(.horizontal, 12)
            }
            if library.checking || library.check != nil {
                CheckBar(library: library)
            }
            // Duplicates only take a line when there are some here, or while checking.
            if app.preferences.highlightDuplicates, library.selectedFolder != nil, !columns,
               library.duplicateProgress != nil || library.duplicatesHere > 0 || library.showOnlyDuplicates
            {
                DuplicateBar(library: library)
            }
            Divider()
            if columns {
                MediaColumns(base: nil, roots: library.columnRoots, folder: library.selectedFolder,
                             revision: app.libraryRevision &+ library.treeRevision, owner: library)
            } else {
                contents
            }
        }
        .onChange(of: app.libraryRevision) { _, _ in
            library.reload()
            // Saves and pulls make folders: the tree reads the folders it shows again, off the main actor.
            library.invalidateTree()
        }
        .onChange(of: app.analysis.revision) { _, _ in library.reattach() }
    }

    private var columns: Bool { model.viewMode(for: .library) == .column }

    private var contents: some View {
        ZStack {
            PaneMediaView(mode: model.viewMode(for: .library), sections: library.sections, selection: library.selection,
                          cellSize: library.cellSize, revision: library.revision, owner: library)
            if library.showOnlyDuplicates, library.shownFiles.isEmpty, !library.files.isEmpty {
                Text("No duplicates in this folder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
            if library.files.isEmpty, model.viewMode(for: .library) == .icon || library.listTopFolders.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down").font(.title).foregroundStyle(.tertiary)
                    Text("Drag media here to save it in this folder.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .allowsHitTesting(false)
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        let shown = library.shownFiles.count
        parts.append(shown == library.files.count ? "\(shown) file\(shown == 1 ? "" : "s")" : "\(shown) of \(library.files.count) files")
        if library.listingLimited { parts.append("only the first \(MediaListing.limit.formatted()) are listed") }
        if library.subfolderCount > 0 { parts.append("\(library.subfolderCount) folder\(library.subfolderCount == 1 ? "" : "s")") }
        if let root = library.selectedFolder.flatMap({ app.root(containing: $0) }) { parts.append(root.layout.label) }
        if let match = library.account {
            let record = app.accountFolder(containing: match.folder)
            if record?.cursor != nil {
                parts.append("@\(match.account): an earlier update stopped part way")
            } else if let date = record?.lastUpdate {
                parts.append("@\(match.account) updated \(date.formatted(.relative(presentation: .named)))")
            } else {
                parts.append("@\(match.account)")
            }
        }
        return parts.joined(separator: " · ")
    }
}

/// Settings for duplicate detection, in the Library menu and Settings (SPEC R-3303).
struct DuplicateCommands: View {
    var library: LibraryModel?
    @Bindable private var preferences = AppModel.shared.preferences
    private var app: AppModel { .shared }

    var body: some View {
        Toggle("Highlight Duplicates", isOn: Binding(
            get: { preferences.highlightDuplicates },
            set: {
                preferences.highlightDuplicates = $0
                rescan()
            }
        ))
        Picker("Count as Duplicates", selection: Binding(
            get: { preferences.duplicateSensitivity },
            set: {
                preferences.duplicateSensitivity = $0
                rescan()
            }
        )) {
            ForEach(DuplicateSensitivity.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .disabled(!preferences.highlightDuplicates)
        if let library {
            Toggle("Show Only Duplicates", isOn: Binding(get: { library.showOnlyDuplicates }, set: { library.showOnlyDuplicates = $0 }))
                .disabled(!preferences.highlightDuplicates || library.duplicates == nil)
        }
    }

    private func rescan() {
        for window in app.windows { window.library.scanDuplicates() }
    }
}

/// Progress and counts for duplicate detection under the folder title.
/// The result of Check Folder (R-1713), under the folder's title until another folder is chosen or it is closed.
struct CheckBar: View {
    @Bindable var library: LibraryModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if library.checking {
                ProgressView().controlSize(.mini)
                Text("Checking every file in this folder…")
            } else if let report = library.check {
                Image(systemName: report.isClean ? "checkmark.circle" : "exclamationmark.circle")
                    .foregroundStyle(report.isClean ? Color.secondary : Color.orange)
                Text(summary(report)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if !report.orphanedMetadata.isEmpty {
                    Button("Trash Orphaned Metadata") {
                        library.perform(FolderOperations.trash(report.orphanedMetadata)) { _ in
                            library.checkFolder(report.folder)
                        }
                    }
                    .help("Move the metadata files whose media file is gone to the Trash. Undo puts them back.")
                }
                let found = report.changed + report.withoutMetadata
                if !found.isEmpty {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(Array(found.prefix(200))) }
                }
                Button("Done") { library.check = nil }
            }
            Spacer(minLength: 0)
        }
        .controlSize(.mini)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.bottom, 5)
    }

    private func summary(_ report: FolderCheck.Report) -> String {
        func count(_ number: Int, _ one: String, _ many: String) -> String { "\(number.formatted()) \(number == 1 ? one : many)" }
        var parts: [String] = []
        if !report.changed.isEmpty {
            parts.append(count(report.changed.count, "file changed", "files changed") + " since saved (edited, or damaged)")
        }
        if !report.withoutMetadata.isEmpty {
            parts.append(count(report.withoutMetadata.count, "file has", "files have") + " no metadata file")
        }
        if !report.orphanedMetadata.isEmpty {
            parts.append(count(report.orphanedMetadata.count, "metadata file has", "metadata files have") + " no media file")
        }
        if !report.notDownloaded.isEmpty {
            parts.append(count(report.notDownloaded.count, "file is", "files are") + " only in iCloud")
        }
        let checked = "Checked " + count(report.checked, "file", "files")
        return parts.isEmpty ? checked + ": everything matches what was saved." : checked + ": " + parts.joined(separator: "; ") + "."
    }
}

struct DuplicateBar: View {
    @Bindable var library: LibraryModel

    var body: some View {
        HStack(spacing: 8) {
            if let progress = library.duplicateProgress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 60)
                Text("Checking for duplicates, \(progress.done) of \(progress.total)")
                    .lineLimit(1)
            } else if let report = library.duplicates {
                let here = library.duplicatesHere
                // One line when the pane is wide enough, two when it is narrow.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        summaryLabel(here: here, total: report.duplicateFileCount)
                        Spacer(minLength: 4)
                        if here > 0 { controls }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        summaryLabel(here: here, total: report.duplicateFileCount)
                        if here > 0 { HStack(spacing: 8) { controls } }
                    }
                }
            } else {
                Text("Checking for duplicates…")
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.bottom, 5)
    }

    private func summaryLabel(here: Int, total: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: here > 0 ? "square.on.square" : "checkmark.circle")
                .foregroundStyle(here > 0 ? Color.purple : Color.secondary)
            Text(summary(here: here, total: total))
                .lineLimit(1)
                .fixedSize()
        }
    }

    @ViewBuilder
    private var controls: some View {
        Legend(color: .orange, label: "Identical")
        Legend(color: .purple, label: "Look alike")
        Toggle("Only Duplicates", isOn: $library.showOnlyDuplicates)
            .toggleStyle(.button)
            .controlSize(.mini)
        Button("Trash Extra Copies…") { library.trashExtraCopies() }
            .controlSize(.mini)
            .help("Keep one file of each group (the largest picture) and move the others to the Trash. Undo puts them back.")
    }

    private func summary(here: Int, total: Int) -> String {
        if total == 0 { return "No duplicates in this library folder" }
        if here == 0 { return "None here · \(total) elsewhere" }
        return "\(here) here · \(total) in this library folder"
    }
}

private struct Legend: View {
    var color: Color
    var label: String

    var body: some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).strokeBorder(color, lineWidth: 1.5).frame(width: 9, height: 9)
            Text(label)
        }
        .fixedSize()
    }
}
