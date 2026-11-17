import MediaPullCore
import SwiftUI

enum BrowsingPanelTab: String, CaseIterable, Identifiable {
    case bookmarks, history

    var id: String { rawValue }
    var label: String { self == .bookmarks ? "Bookmarks" : "History" }
}

/// Bookmarks (in folders that can be renamed) and history (that can be cleared) (SPEC R-806, R-807).
struct BrowsingPanel: View {
    @Bindable var model: WindowModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $model.browsingPanelTab) {
                ForEach(BrowsingPanelTab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            if let problem = AppModel.shared.browsing.saveProblem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 10).padding(.bottom, 6)
            }
            Divider()
            switch model.browsingPanelTab {
            case .bookmarks: BookmarksList(model: model)
            case .history: HistoryList(model: model)
            }
        }
        .frame(width: 380, height: 500)
    }
}

/// Opens a page from the panel: in the current tab, or a new one with ⌘ held.
@MainActor
private func open(_ url: URL, in model: WindowModel, newTab: Bool = false) {
    if newTab || NSEvent.modifierFlags.contains(.command) {
        model.newTab(url, select: !NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift))
    } else {
        model.browser.load(url)
        model.showBrowsingPanel = false
    }
}

struct BookmarksList: View {
    @Bindable var model: WindowModel
    @State private var collapsed = Set<UUID>()
    @State private var renaming: UUID?
    @State private var draftName = ""
    @State private var folderToDelete: BookmarkFolder?
    @FocusState private var nameFocused: Bool
    private var store: BrowsingStore { AppModel.shared.browsing }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(store.bookmarks.folders) { folder in
                    Section {
                        if !collapsed.contains(folder.id) {
                            if folder.bookmarks.isEmpty {
                                Text("No bookmarks. Use the star in the address field or ⌘D.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(folder.bookmarks) { bookmark in
                                bookmarkRow(bookmark, in: folder)
                            }
                        }
                    } header: {
                        folderHeader(folder)
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Button {
                    var id = UUID()
                    store.edit { id = $0.addFolder(named: "New Folder") }
                    draftName = store.bookmarks.folders.first { $0.id == id }?.name ?? ""
                    renaming = id
                    nameFocused = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                if let url = model.browser.url, store.bookmark(for: url) == nil {
                    Button("Bookmark This Page") { store.addBookmark(title: model.browser.title, url: url) }
                        .buttonStyle(.borderless)
                }
            }
            .padding(10)
        }
        .alert("Delete the folder “\(folderToDelete?.name ?? "")”?", isPresented: Binding(
            get: { folderToDelete != nil }, set: { if !$0 { folderToDelete = nil } }
        )) {
            Button("Delete Folder and Bookmarks", role: .destructive) {
                if let folder = folderToDelete { store.edit { $0.removeFolder(folder.id) } }
                folderToDelete = nil
            }
            Button("Cancel", role: .cancel) { folderToDelete = nil }
        } message: {
            Text("Its \(folderToDelete?.bookmarks.count ?? 0) bookmarks are deleted too.")
        }
    }

    private func folderHeader(_ folder: BookmarkFolder) -> some View {
        HStack(spacing: 6) {
            Button {
                if collapsed.contains(folder.id) { collapsed.remove(folder.id) } else { collapsed.insert(folder.id) }
            } label: {
                Image(systemName: collapsed.contains(folder.id) ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            Image(systemName: "folder")
            if renaming == folder.id {
                TextField("Folder name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit { commitFolderName(folder.id) }
                    .onExitCommand { renaming = nil }
            } else {
                Text(folder.name)
                    .onTapGesture(count: 2) { startRenaming(folder) }
                Text("\(folder.bookmarks.count)").foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .font(.callout.weight(.semibold))
        .contextMenu {
            Button("Rename Folder") { startRenaming(folder) }
            Button("Move Up") { store.edit { $0.moveFolder(folder.id, by: -1) } }
                .disabled(store.bookmarks.folders.first?.id == folder.id)
            Button("Move Down") { store.edit { $0.moveFolder(folder.id, by: 1) } }
                .disabled(store.bookmarks.folders.last?.id == folder.id)
            Divider()
            Button("Open All in Tabs") { folder.bookmarks.forEach { model.newTab($0.url, select: false) } }
                .disabled(folder.bookmarks.isEmpty)
            Divider()
            Button(store.bookmarks.folders.count == 1 ? "Delete All Bookmarks in Folder…" : "Delete Folder…") {
                if folder.bookmarks.isEmpty, store.bookmarks.folders.count > 1 {
                    store.edit { $0.removeFolder(folder.id) }
                } else {
                    folderToDelete = folder
                }
            }
        }
    }

    private func startRenaming(_ folder: BookmarkFolder) {
        draftName = folder.name
        renaming = folder.id
        nameFocused = true
    }

    private func commitFolderName(_ id: UUID) {
        let name = draftName
        store.edit { $0.renameFolder(id, to: name) }
        renaming = nil
    }

    private func bookmarkRow(_ bookmark: Bookmark, in folder: BookmarkFolder) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "bookmark").foregroundStyle(.tint).font(.caption)
            if renaming == bookmark.id {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit {
                        let name = draftName
                        store.edit { $0.rename(bookmark.id, to: name) }
                        renaming = nil
                    }
                    .onExitCommand { renaming = nil }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(bookmark.title).lineLimit(1)
                    Text(bookmark.url.host ?? bookmark.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if renaming != bookmark.id { open(bookmark.url, in: model) } }
        .help(bookmark.url.absoluteString)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open(bookmark.url, in: model) }
        .contextMenu {
            Button("Open in New Tab") { open(bookmark.url, in: model, newTab: true) }
            Button("Rename…") {
                draftName = bookmark.title
                renaming = bookmark.id
                nameFocused = true
            }
            Menu("Move To") {
                ForEach(store.bookmarks.folders) { target in
                    Button(target.name) { store.edit { $0.move(bookmark.id, to: target.id) } }
                        .disabled(target.id == folder.id)
                }
            }
            Button("Copy Address") { Format.copy(bookmark.url.absoluteString) }
            Divider()
            Button("Delete Bookmark") { store.edit { $0.remove(bookmark.id) } }
        }
    }
}

struct HistoryList: View {
    @Bindable var model: WindowModel
    @State private var search = ""
    private var store: BrowsingStore { AppModel.shared.browsing }
    private var app: AppModel { .shared }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search History", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            let groups = BrowsingHistory.groupedByDay(Array(store.history.matching(search).prefix(1500)))
            if groups.isEmpty {
                Text(app.preferences.rememberHistory ? (search.isEmpty ? "No history yet." : "Nothing matches.")
                    : "History is turned off in Settings > General.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.day) { group in
                        Section(dayLabel(group.day)) {
                            ForEach(group.entries) { entry in row(entry) }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            Divider()
            HStack {
                Menu("Clear History") {
                    ForEach(BrowsingStore.ClearRange.allCases) { range in
                        Button(range.label) { store.clearHistory(range) }
                    }
                }
                .fixedSize()
                .disabled(store.history.entries.isEmpty)
                Spacer()
                Text("Kept only on this Mac").font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
        }
    }

    private func row(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title.isEmpty ? (entry.url.host ?? entry.url.absoluteString) : entry.title).lineLimit(1)
                Text(entry.url.host ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(entry.lastVisit.formatted(date: .omitted, time: .shortened))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture { open(entry.url, in: model) }
        .help(entry.url.absoluteString)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open(entry.url, in: model) }
        .contextMenu {
            Button("Open in New Tab") { open(entry.url, in: model, newTab: true) }
            Button("Bookmark") { store.addBookmark(title: entry.title, url: entry.url) }
                .disabled(store.bookmark(for: entry.url) != nil)
            Button("Copy Address") { Format.copy(entry.url.absoluteString) }
            Divider()
            Button("Remove from History") { store.removeHistory(entry.id) }
        }
    }

    private func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .complete, time: .omitted)
    }
}

/// The star in the address field: adds the page to Favourites, then lets you rename it, move it or remove it.
struct BookmarkStar: View {
    @Bindable var model: WindowModel
    @State private var editing = false
    @State private var title = ""
    @State private var folder: UUID?
    /// The bookmark being edited, fixed when the editor opens so a redirect cannot change which one is edited.
    @State private var bookmarkID: UUID?
    private var store: BrowsingStore { AppModel.shared.browsing }

    var body: some View {
        let existing = store.bookmark(for: model.browser.url)
        Button {
            openEditor()
        } label: {
            Image(systemName: existing == nil ? "star" : "star.fill")
                .foregroundStyle(existing == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        }
        .buttonStyle(.plain)
        .disabled(model.browser.url == nil)
        .help(existing == nil ? "Bookmark this page (⌘D)" : "Edit bookmark")
        .onChange(of: model.bookmarkRequest) { _, _ in openEditor() }
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Bookmark").font(.headline)
                TextField("Name", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commit() }
                Picker("Folder", selection: $folder) {
                    ForEach(store.bookmarks.folders) { Text($0.name).tag(Optional($0.id)) }
                }
                HStack {
                    Button("Remove", role: .destructive) {
                        if let id = bookmarkID { store.edit { $0.remove(id) } }
                        editing = false
                    }
                    Spacer()
                    Button("Done") { commit() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(14)
            .frame(width: 300)
        }
    }

    private func openEditor() {
        guard let url = model.browser.url else { return }
        if store.bookmark(for: url) == nil { store.addBookmark(title: model.browser.title, url: url) }
        let saved = store.bookmark(for: url)
        bookmarkID = saved?.bookmark.id
        title = saved?.bookmark.title ?? ""
        folder = saved?.folder.id
        editing = true
    }

    private func commit() {
        if let id = bookmarkID {
            let name = title
            let target = folder
            store.edit {
                $0.rename(id, to: name)
                if let target { $0.move(id, to: target) }
            }
        }
        editing = false
    }
}
