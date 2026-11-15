import SwiftUI

/// The folder Collect saves into, and a menu to change it: library folders, recent folders or any folder (D-70).
struct SaveFolderMenu: View {
    @Bindable var model: WindowModel
    private var app: AppModel { .shared }

    var body: some View {
        Menu {
            Section("Library Folders") {
                ForEach(app.roots) { root in
                    Toggle(root.name, isOn: Binding(get: { isCurrent(root.url) }, set: { _ in model.useSaveFolder(root.url) }))
                }
            }
            let recent = app.recentSaveFolders.filter { !isCurrent($0) }.prefix(6)
            if !recent.isEmpty {
                Section("Recent") {
                    ForEach(Array(recent), id: \.self) { folder in
                        Button(folder.lastPathComponent) { model.useSaveFolder(folder) }
                    }
                }
            }
            Divider()
            Button("Other Folder…") { model.chooseSaveFolder() }
            if let folder = model.saveFolder {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            }
        } label: {
            Label(model.saveFolderName, systemImage: "folder")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(model.saveFolder.map { "Saving into \($0.path). Choose another folder here or in the Library pane." } ?? "Choose where to save")
    }

    private func isCurrent(_ url: URL) -> Bool {
        model.saveFolder?.standardizedFileURL.path == url.standardizedFileURL.path
    }
}
