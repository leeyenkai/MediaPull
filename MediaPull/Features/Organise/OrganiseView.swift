import MediaPullCore
import MediaPullLibrary
import SwiftUI
import UniformTypeIdentifiers

/// The header every Organise pane shares with the Collect panes: title, controls, arrange menu.
struct PaneHeader<Controls: View>: View {
    let title: String
    let pane: PaneID
    @Bindable var model: WindowModel
    @ViewBuilder var controls: Controls
    private var app: AppModel { .shared }

    var body: some View {
        HStack(spacing: 8) {
            if !title.isEmpty { Text(title).font(.headline).lineLimit(1).fixedSize() }
            Spacer(minLength: 0)
            controls
            PaneMenu(pane: pane, window: model)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(app.preferences.theme.headerBackground)
    }
}

/// A folder pane of Organise (Source or Target): folder chooser, tree on top, media grid below, like the Library pane.
struct OrganiseFolderPane: View {
    @Bindable var model: WindowModel
    @Bindable var organise: OrganiseModel
    @Bindable var pane: OrganisePane
    @State private var dropTargeted = false
    @State private var headerTargeted = false
    private var app: AppModel { .shared }

    private func openDropped(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        Task {
            if let data = await provider.loadData(type: UTType.fileURL.identifier),
               let url = URL(dataRepresentation: data, relativeTo: nil),
               (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            {
                organise.open(url, in: pane)
            }
        }
        return true
    }

    private var mode: PaneViewMode { model.viewMode(for: pane.paneID) }
    private var columns: Bool { mode == .column }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: pane.role == .source ? "Source" : "Target", pane: pane.role == .source ? .organiseSource : .organiseTarget,
                       model: model) {
                FolderMenu(organise: organise, pane: pane)
                if pane.root != nil { ViewModePicker(model: model, pane: pane.role == .source ? .organiseSource : .organiseTarget) }
            }
            // A folder dropped on the header opens in this pane, whatever it shows now.
            .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: headerTargeted ? 2 : 0).allowsHitTesting(false))
            .onDrop(of: [.fileURL], isTargeted: $headerTargeted) { openDropped($0) }
            Divider()
            if let root = pane.root {
                VStack(spacing: 0) {
                    // A compact tree: the media grid gets the room. Column view is its own tree (R-1710).
                    if !columns {
                        OrganiseTree(organise: organise, pane: pane, root: root)
                            .frame(minHeight: 60, idealHeight: 150, maxHeight: 190)
                        Divider()
                    }
                    VStack(spacing: 0) {
                        HStack(spacing: 6) {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 4)
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        if !columns {
                            QueryBar(query: $pane.query, includeSubfolders: $pane.includeSubfolders, entries: pane.entries,
                                     focusToken: model.searchFocusTokens[pane.paneID] ?? 0)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        }
                        Divider()
                        if columns {
                            MediaColumns(base: root, roots: [], folder: pane.folder, revision: pane.treeRevision, owner: pane)
                        } else {
                            ZStack {
                                PaneMediaView(mode: mode, sections: pane.gridSections, selection: pane.selection, cellSize: pane.cellSize,
                                              revision: pane.revision, owner: pane)
                                if pane.shown.isEmpty, !pane.loading, mode == .icon || pane.listTopFolders.isEmpty {
                                    Text(pane.entries.isEmpty ? "No media in this folder." : "Nothing matches the search and filters.")
                                        .font(.callout).foregroundStyle(.secondary).allowsHitTesting(false)
                                }
                            }
                        }
                    }
                    .frame(minHeight: 160)
                }
            } else if pane.role == .target {
                NoTargetView(organise: organise, pane: pane)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                    Text("Choose a folder to organise").font(.headline)
                    Button("Choose Folder…") { organise.chooseFolder(for: pane) }.buttonStyle(.borderedProminent)
                    Text("Or drop a folder here from Finder.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: dropTargeted ? 2 : 0).allowsHitTesting(false))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            pane.root == nil ? openDropped(providers) : false
        }
        .onChange(of: app.analysis.revision) { _, _ in pane.reattach() }
    }

    private var subtitle: String {
        var parts = [
            pane.shown.count == pane.entries.count ? "\(pane.entries.count) files" : "\(pane.shown.count) of \(pane.entries.count) files"
        ]
        if pane.subfolderCount > 0 { parts.append("\(pane.subfolderCount) folder\(pane.subfolderCount == 1 ? "" : "s")") }
        if !pane.selection.isEmpty { parts.append("\(pane.selection.count) selected") }
        return parts.joined(separator: " · ")
    }
}

/// The Target pane before a target is chosen: sorting happens in place, and a target is one click away (D-68).
struct NoTargetView: View {
    @Bindable var organise: OrganiseModel
    @Bindable var pane: OrganisePane
    private var app: AppModel { .shared }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
            Text("Organising in place").font(.headline)
            Text("Sorts make folders inside the source folder. Choose a target folder to leave the source as it is.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Choose Target Folder…") { organise.chooseFolder(for: pane) }.buttonStyle(.borderedProminent)
            if let library = app.defaultRoot, let source = organise.source.root, app.root(containing: source) == nil {
                Button("Copy into “\(library.name)”") {
                    organise.moveToTarget = false
                    organise.open(library.url, in: pane)
                }
                .help("Import: organised copies go into the library and the source stays as it is")
            }
            Text("Or drop a folder here from Finder.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The folder a pane shows: library folders, recent folders, or any folder on the Mac.
struct FolderMenu: View {
    @Bindable var organise: OrganiseModel
    @Bindable var pane: OrganisePane
    private var app: AppModel { .shared }

    var body: some View {
        Menu {
            Section("Library Folders") {
                ForEach(app.roots) { root in Button(root.name) { organise.open(root.url, in: pane) } }
            }
            let recent = organise.recentFolders.filter { r in !app.roots.contains { $0.url.path == r.path } }
            if !recent.isEmpty {
                Section("Recent") {
                    ForEach(recent.prefix(6), id: \.self) { folder in Button(folder.lastPathComponent) { organise.open(folder, in: pane) } }
                }
            }
            if pane.role == .target, pane.root != nil {
                Button("None (Organise In Place)") { organise.clearTarget() }
            }
            Divider()
            Button("Other Folder…") { organise.chooseFolder(for: pane) }
        } label: {
            Label(pane.root?.lastPathComponent ?? (pane.role == .target ? "None" : "Choose Folder"), systemImage: "folder")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose the folder for this pane; any folder on the Mac works")
    }
}

/// A folder tree rooted at the pane's folder. Rows take dropped files, rename in place and offer the folder operations.
struct OrganiseTree: View {
    @Bindable var organise: OrganiseModel
    @Bindable var pane: OrganisePane
    var root: URL

    var body: some View {
        // A view body cannot discard with `_ =`; reading the revision rebuilds the tree after changes.
        // swiftlint:disable:next redundant_discardable_let
        let _ = pane.treeRevision
        let node = pane.rootNode(root)
        List(selection: Binding(get: { pane.folder?.path }, set: { path in
            pane.folder = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
        })) {
            OutlineGroup(node, children: \.children) { child in
                OrganiseFolderRow(organise: organise, pane: pane, node: child)
                    .tag(child.url.path)
            }
        }
        .listStyle(.inset)
    }
}

struct OrganiseFolderRow: View {
    @Bindable var organise: OrganiseModel
    @Bindable var pane: OrganisePane
    var node: FolderNode
    @State private var targeted = false
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: node.isRoot ? "folder.fill" : "folder").foregroundStyle(node.isRoot ? Color.accentColor : .secondary)
            if organise.renaming == node.url.path {
                TextField("Name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($editing)
                    .onSubmit { organise.commitRename(node.url, to: draft) }
                    .onExitCommand { organise.renaming = nil }
                    .onAppear {
                        draft = node.name
                        editing = true
                    }
            } else {
                Text(node.name).lineLimit(1)
            }
        }
        .padding(.vertical, 1)
        .background(targeted ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let data = await provider.loadData(type: UTType.fileURL.identifier),
                       let url = URL(dataRepresentation: data, relativeTo: nil)
                    {
                        urls.append(url)
                    }
                }
                organise.drop(Sidecar.withoutCompanions(urls), into: node.url)
            }
            return true
        }
        .contextMenu {
            Button("New Folder") { organise.newFolder(in: node.url) }
            if !node.isRoot { Button("Rename") { organise.renaming = node.url.path } }
            Divider()
            Button("Flatten") { organise.flatten(node.url) }
            if !node.isRoot {
                Button("Remove Folder, Keep Contents") { organise.removeFolder(node.url) }
                Menu("Merge Into") {
                    if let target = organise.targetFolder, target != node.url {
                        Button("Target: \(target.lastPathComponent)") { organise.merge(node.url, into: target) }
                    }
                    ForEach(organise.siblings(of: node.url), id: \.self) { other in
                        Button(other.lastPathComponent) { organise.merge(node.url, into: other) }
                    }
                }
            }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            if !node.isRoot {
                Button("Move to Trash") { organise.run(FolderOperations.trash([node.url])) }
            }
        }
        .help(node.url.path)
    }
}

/// The middle pane: choose how to organise, see what will happen, apply; people; history (R-3802 to R-3806).
struct OrganiseWorkPane: View {
    @Bindable var model: WindowModel
    @Bindable var organise: OrganiseModel
    private var app: AppModel { .shared }

    var body: some View {
        VStack(spacing: 0) {
            // The Sort, People and History tabs name the pane.
            PaneHeader(title: "", pane: .organiseWork, model: model) {
                ChipTabs(selection: $organise.tab, items: OrganiseTab.allCases, label: \.label)
                    .fixedSize()
            }
            Divider()
            if organise.batchRename != nil {
                BatchRenameRow(organise: organise)
                Divider()
            }
            switch organise.tab {
            case .sort: sortTab
            case .people: PeopleView(inline: true).padding(12)
            case .history: historyTab
            }
            if let message = organise.message {
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button { organise.message = nil } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Dismiss Message").buttonStyle(.borderless)
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private var sortTab: some View {
        if let pending = organise.pending {
            PlanPreview(organise: organise, pending: pending)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        if organise.mode == .inPlace {
                            Label("In place, inside the source folder", systemImage: "arrow.triangle.branch")
                                .font(.callout)
                                .help("Choose another target folder in the Target pane to copy or move results there instead")
                        } else {
                            Picker("Results", selection: $organise.moveToTarget) {
                                Text("Copy to Target").tag(false)
                                Text("Move to Target").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .help(organise.mode.detail)
                        }
                    }
                    Text(scope).font(.callout).fixedSize(horizontal: false, vertical: true)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
                        ForEach(AutoSort.allCases) { kind in
                            Button { organise.autoSort(kind) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Image(systemName: kind.symbol).font(.title3).foregroundStyle(Color.accentColor)
                                    Text(kind.label).font(.callout.weight(.semibold))
                                    Text(kind.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
                                .padding(10)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .disabled(organise.working != nil || organise.destination == nil)
                        }
                    }
                    if let working = organise.working {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(working).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !organise.source.selectedURLs.isEmpty, let target = organise.targetFolder, organise.mode != .inPlace {
                        Divider()
                        Text("\(organise.source.selectedURLs.count) selected in the source").font(.callout.weight(.semibold))
                        HStack {
                            Button("Copy to \(target.lastPathComponent)") {
                                organise.run(FolderOperations.copy(organise.source.selectedURLs, to: target))
                            }
                            Button("Move to \(target.lastPathComponent)") {
                                organise.run(FolderOperations.move(organise.source.selectedURLs, to: target))
                            }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(12)
            }
        }
    }

    private var scope: String {
        let source = organise.source
        let count = source.selection.isEmpty ? source.shown.count : source.selection.count
        let what = source.selection.isEmpty
            ? "the \(count) file\(count == 1 ? "" : "s") shown"
            : "the \(count) selected file\(count == 1 ? "" : "s")"
        guard let destination = organise.destination else { return "Choose a target folder first." }
        return "Sort \(what) into folders in “\(destination.lastPathComponent)” by"
    }

    @ViewBuilder
    private var historyTab: some View {
        if organise.history.isEmpty {
            Text("Changes you make appear here, and each can be undone.").font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(organise.history.prefix(50)) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).lineLimit(1)
                        Text("""
                            \(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(entry.fileCount) \
                            file\(entry.fileCount == 1 ? "" : "s")
                            """)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if entry.undone {
                        Text("Undone").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Undo") { organise.undo(entry) }.controlSize(.small)
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

/// What a change will do, in the Organise pane, before it runs (R-3805).
struct PlanPreview: View {
    @Bindable var organise: OrganiseModel
    let pending: PendingPlan
    /// What the copies cost: it reads every copied file's size and volume, so it is worked out once, off the main actor.
    @State private var copyNote: String?
    private var organiseShown: Bool { organise.window?.section == .organise }

    var body: some View {
        let plan = pending.plan
        let destinations = plan.destinations
        VStack(alignment: .leading, spacing: 10) {
            Text(plan.title).font(.title3.weight(.semibold))
            Text(summary(plan, folders: destinations.count)).font(.callout).fixedSize(horizontal: false, vertical: true)
                .task(id: pending.id) {
                    guard plan.cloneCount > 0 else { return }
                    let count = plan.cloneCount
                    let cost = await Task.detached(priority: .userInitiated) { plan.clonesAreFree ? nil : plan.cloneBytes }.value
                    copyNote = cost.map { "\(count) cop\(count == 1 ? "y" : "ies") will use \(Format.bytes($0))." }
                        ?? "\(count) cop\(count == 1 ? "y" : "ies") will be made, taking no extra space."
                }
            if let note = pending.note {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            List {
                ForEach(destinations.prefix(200), id: \.folder) { destination in
                    HStack(spacing: 10) {
                        HStack(spacing: 3) {
                            ForEach(destination.files.prefix(3), id: \.self) { url in PreviewThumb(url: url) }
                        }
                        .frame(width: 3 * 37, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(relative(destination.folder, to: plan.root)).lineLimit(1).truncationMode(.middle)
                            Text("\(destination.files.count) file\(destination.files.count == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !plan.foldersToTrash.isEmpty {
                    Label("\(plan.foldersToTrash.count) emptied folder\(plan.foldersToTrash.count == 1 ? "" : "s") to the Trash",
                          systemImage: "trash")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
            HStack {
                // ⌘. and ⌘Return rather than Escape and Return, and only while Organise is shown: the section stays
                // mounted behind Collect, where Return in the address field or a web form must never apply a sort (D-47).
                Button("Discard") { organise.pending = nil }
                    .keyboardShortcut(".", modifiers: .command, enabled: organiseShown)
                    .help("Discard (⌘.)")
                Spacer()
                Button(applyTitle(plan)) { organise.execute(plan) }
                    .keyboardShortcut(.return, modifiers: .command, enabled: organiseShown)
                    .help("Apply (⌘Return)")
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
    }

    private func applyTitle(_ plan: OrganisePlan) -> String {
        let moves = plan.moves.filter { $0.kind == .move }.count
        if moves == 0, plan.cloneCount > 0 { return "Copy \(plan.cloneCount) File\(plan.cloneCount == 1 ? "" : "s")" }
        return moves == 0 ? "Apply" : "Move \(moves) File\(moves == 1 ? "" : "s")"
    }

    private func summary(_ plan: OrganisePlan, folders: Int) -> String {
        var parts: [String] = []
        let moves = plan.moves.filter { $0.kind == .move }.count
        if moves > 0 { parts.append("\(moves) file\(moves == 1 ? "" : "s") will move into \(folders) folder\(folders == 1 ? "" : "s").") }
        if plan.cloneCount > 0 {
            parts.append(copyNote ?? "\(plan.cloneCount) cop\(plan.cloneCount == 1 ? "y" : "ies") will be made.")
        }
        if plan.unsorted > 0 {
            parts.append(
                plan.unchanged >= plan.unsorted
                    ? "\(plan.unsorted) stay where they are."
                    : "\(plan.unsorted) go to “\(FolderNames.unsorted)”."
            )
        }
        if plan.renamed > 0 { parts.append("\(plan.renamed) get a number because the name is taken.") }
        return parts.isEmpty ? "Nothing to move." : parts.joined(separator: " ")
    }

    /// The folder relative to the folder being sorted. Paths are compared by components, ignoring the /private prefix
    /// macOS adds or drops depending on whether a folder exists yet.
    private func relative(_ folder: URL, to root: URL) -> String {
        func parts(_ url: URL) -> [String] {
            var c = url.standardizedFileURL.pathComponents.filter { $0 != "/" }
            if c.first == "private" { c.removeFirst() }
            return c
        }
        let f = parts(folder), r = parts(root)
        guard f.count >= r.count, Array(f.prefix(r.count)) == r else { return folder.path }
        let rest = f.dropFirst(r.count).joined(separator: "/")
        return rest.isEmpty ? root.lastPathComponent : rest
    }
}

struct PreviewThumb: View {
    let url: URL
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill) }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task { image = await AppModel.shared.thumbnails.localThumbnail(for: url, maxPixel: 96)?.image }
    }
}

private extension View {
    /// A keyboard shortcut that exists only while `enabled`, so a hidden section's buttons never receive key presses.
    @ViewBuilder
    func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers, enabled: Bool) -> some View {
        if enabled { keyboardShortcut(key, modifiers: modifiers) } else { self }
    }
}

/// The pattern for renaming several files at once, with the first new names as they will be (R-3808).
struct BatchRenameRow: View {
    @Bindable var organise: OrganiseModel

    var body: some View {
        if let draft = organise.batchRename {
            VStack(alignment: .leading, spacing: 8) {
                Text("Rename \(draft.files.count) Files").font(.headline)
                if draft.archive {
                    Text("Files in Archive folders keep the names MediaPull gave them, since their metadata files and later "
                        + "downloads rely on them. Rename files in Plain folders, or move them to one first.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    TextField("Pattern", text: Binding(get: { draft.pattern }, set: { organise.batchRename?.pattern = $0 }))
                        .textFieldStyle(.roundedBorder)
                    Text("{name} is the current name, {n} a number in order, {date} the day the file was last changed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(organise.batchPreview(draft), id: \.old) { row in
                        Text("\(row.old)  →  \(row.new)").font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    }
                }
                HStack {
                    Spacer()
                    Button("Cancel") { organise.batchRename = nil }
                    if !draft.archive {
                        Button("Rename") { organise.applyBatchRename() }
                            .buttonStyle(.borderedProminent)
                            .disabled(draft.pattern.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .controlSize(.small)
            }
            .padding(12)
        }
    }
}
