import MediaPullCore
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
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add a library folder or create a new folder")
                PaneMenu(pane: .library, window: model)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(app.preferences.theme.headerBackground)
            Divider()
            if app.roots.isEmpty {
                NoRootsView(library: library)
            } else {
                VSplitView {
                    FolderTree(model: model, library: library)
                        .frame(minHeight: 140, idealHeight: 260)
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
        let _ = (library.treeRevision, app.libraryRevision)
        let rootNodes = app.roots.map { FolderNode(url: $0.url, name: $0.name, isRoot: true, rootID: $0.id) }
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
            if library.selectedFolder == nil || app.root(containing: library.selectedFolder!) == nil {
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
    private var app: AppModel { .shared }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: node.isRoot ? (root?.isDefault == true ? "folder.fill.badge.person.crop" : "folder.fill") : "folder")
                .foregroundStyle(node.isRoot ? Color.accentColor : .secondary)
            Text(node.name).lineLimit(1)
            if node.isRoot, let root {
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
            if node.isRoot, let root {
                Divider()
                if !root.isDefault {
                    Button("Use as Default Save Location") {
                        Task {
                            await app.store?.setDefault(root.id)
                            await app.reloadRoots()
                        }
                    }
                }
                Menu("SaveLayout") {
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
            } else {
                Button("Rename…") { library.rename(node.url) }
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
                if let folder = library.selectedFolder, !model.selection.isEmpty {
                    Button("Save \(model.selection.count) Here") { app.save(model.selectedItems, from: model, to: folder) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .help("Save the selected extracted items into this folder")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            if let warning = library.selectedFolder.flatMap({ app.root(containing: $0) }).flatMap({ AppModel.locationWarning(for: $0.url) }) {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
            if let message = library.message {
                Text(message).font(.caption).foregroundStyle(.red).padding(.horizontal, 12)
            }
            Divider()
            ZStack {
                MediaGrid(sections: library.sections, selection: library.selection, cellSize: library.cellSize, revision: library.revision,
                          owner: library)
                if library.files.isEmpty {
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
        .onChange(of: app.libraryRevision) { _, _ in library.reload() }
    }

    private var subtitle: String {
        var parts: [String] = []
        parts.append("\(library.files.count) file\(library.files.count == 1 ? "" : "s")")
        if library.subfolderCount > 0 { parts.append("\(library.subfolderCount) folder\(library.subfolderCount == 1 ? "" : "s")") }
        if let root = library.selectedFolder.flatMap({ app.root(containing: $0) }) { parts.append(root.layout.label) }
        return parts.joined(separator: " · ")
    }
}
