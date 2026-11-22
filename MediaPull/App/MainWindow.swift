import MediaPullCore
import SwiftUI

struct WindowModelKey: FocusedValueKey {
    typealias Value = WindowModel
}

extension FocusedValues {
    var windowModel: WindowModel? {
        get { self[WindowModelKey.self] }
        set { self[WindowModelKey.self] = newValue }
    }
}

/// The main window: Browser, Extracted Media, Preview and Library in a movable arrangement (SPEC section 7).
struct MainWindow: View {
    @State private var model = WindowModel()
    @Environment(\.openWindow) private var openWindow
    private var app: AppModel { .shared }

    /// Organise is created when first shown, then kept so its state survives switching back and forth.
    @State private var organiseShown = false
    /// Devices, like Organise, is made when first shown and then kept.
    @State private var devicesShown = false
    /// Edit/Frame, like Devices, is made when first shown and then kept.
    @State private var editShown = false
    @State private var showActivity = false
    @State private var showNotes = false

    var body: some View {
        // The Collect panes stay mounted while Organise is shown, so the Browser never reloads (D-62).
        ZStack {
            PaneSplit(
                arrangement: app.preferences.paneArrangement,
                visible: model.visiblePanes,
                panes: [
                    .source: AnyView(BrowserPane(model: model)),
                    .extracted: AnyView(ExtractedPane(model: model)),
                    .preview: AnyView(PreviewPane(model: model)),
                    .library: AnyView(LibraryPane(model: model, library: model.library).background(PaneSurface.list.color)),
                    .downloads: AnyView(DownloadsPane(model: model, downloads: model.downloads)),
                ]
            )
            .opacity(model.section == .collect ? 1 : 0)
            .allowsHitTesting(model.section == .collect)
            .accessibilityHidden(model.section != .collect)
            if organiseShown || model.section == .organise {
                PaneSplit(
                    arrangement: app.preferences.organiseArrangement,
                    visible: model.organiseVisiblePanes,
                    panes: [
                        .organiseSource: AnyView(OrganiseFolderPane(model: model, organise: model.organise, pane: model.organise.source)
                            .background(PaneSurface.list.color)),
                        .organiseWork: AnyView(OrganiseWorkPane(model: model, organise: model.organise)),
                        .organiseTarget: AnyView(OrganiseFolderPane(model: model, organise: model.organise, pane: model.organise.target)
                            .background(PaneSurface.list.color)),
                        .organiseMap: AnyView(OrganiseMapPane(model: model, organise: model.organise)),
                    ]
                )
                .background(Color(nsColor: .windowBackgroundColor))
                .opacity(model.section == .organise ? 1 : 0)
                .allowsHitTesting(model.section == .organise)
                .accessibilityHidden(model.section != .organise)
                .onChange(of: app.fileChangeRevision) { _, _ in model.organise.fileChanged() }
                .onChange(of: app.libraryRevision) { _, _ in model.organise.libraryChanged() }
                .onAppear {
                    organiseShown = true
                    model.organise.prepare()
                }
            }
            if devicesShown || model.section == .devices {
                PaneSplit(
                    arrangement: app.preferences.devicesArrangement,
                    visible: model.devicesVisiblePanes,
                    panes: [
                        .devicesList: AnyView(DevicesListPane(model: model, devices: model.devices).background(PaneSurface.list.color)),
                        .devicesMedia: AnyView(DeviceMediaPane(model: model, devices: model.devices).background(PaneSurface.list.color)),
                        .devicesImport: AnyView(DeviceImportPane(model: model, devices: model.devices)),
                    ]
                )
                .background(Color(nsColor: .windowBackgroundColor))
                .opacity(model.section == .devices ? 1 : 0)
                .allowsHitTesting(model.section == .devices)
                .accessibilityHidden(model.section != .devices)
                .onAppear { devicesShown = true }
            }
            if editShown || model.section == .edit {
                PaneSplit(
                    arrangement: app.preferences.editArrangement,
                    visible: model.editVisiblePanes,
                    panes: [
                        .editMedia: AnyView(EditMediaPane(model: model, edit: model.edit)),
                        .editCanvas: AnyView(EditCanvasPane(model: model, edit: model.edit)),
                        .editInspector: AnyView(EditInspectorPane(model: model, edit: model.edit)),
                    ]
                )
                .background(Color(nsColor: .windowBackgroundColor))
                .opacity(model.section == .edit ? 1 : 0)
                .allowsHitTesting(model.section == .edit)
                .accessibilityHidden(model.section != .edit)
                .onChange(of: app.fileChangeRevision) { _, _ in model.edit.filesChanged() }
                .onAppear { editShown = true }
            }
        }
        .tint(app.preferences.theme.accent)
        .frame(minWidth: 1100, minHeight: 700)
        .onChange(of: app.preferences.theme) {
            model.gridRevision += 1
            model.library.revision += 1
            model.organise.source.revision += 1
            model.organise.target.revision += 1
        }
        .background(WindowAccessor { window in
            if model.hostWindow !== window { model.hostWindow = window }
        })
        .navigationTitle(windowName)
        .toolbar { toolbar }
        .focusedSceneValue(\.windowModel, model)
        .task {
            // Lets an address sent from another app open a window when none is open (R-1111c).
            app.openMainWindow = { [openWindow] in openWindow(id: "main") }
            if let address = app.pendingDownloadAddress {
                app.pendingDownloadAddress = nil
                model.showDownloads(address, fromOutside: true)
            }
            SelfTestRunner.startIfRequested(model)
        }
        .sheet(item: Binding(
            get: { app.walkthroughWindow === model ? app.walkthrough : nil },
            set: { app.walkthrough = $0 }
        )) { mode in
            WalkthroughView(mode: mode)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // The section tabs, then the window's name, right of the traffic lights (D-62). No glass capsules: the title bar uses
        // the same straight edges and small corners as the address and search fields.
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 12) {
                SectionTabs(section: $model.section)
                Rectangle().fill(.separator).frame(width: 1, height: 16)
                Text(windowName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 320, alignment: .leading)
                    .fixedSize(horizontal: windowName.count < 34, vertical: false)
            }
            .padding(.leading, 4)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
        if model.section == .devices {
            ToolbarItem(placement: .automatic) { activityButton }
                .sharedBackgroundVisibility(.hidden)
        } else if model.section == .edit {
            ToolbarItem(placement: .automatic) {
                // Undo and Redo of the open file's edits, as ⌘Z and ⇧⌘Z (R-704, D-132).
                HStack(spacing: 2) {
                    TopBarButton(title: "Undo", symbol: "arrow.uturn.backward") { model.edit.undo() }
                        .disabled(!model.edit.canUndo)
                        .help("Undo the last edit (⌘Z)")
                    TopBarButton(title: "Redo", symbol: "arrow.uturn.forward") { model.edit.redo() }
                        .disabled(!model.edit.canRedo)
                        .help("Redo (⇧⌘Z)")
                    activityButton
                }
                // Any step added, undone or redone (⌘Z too, or a file operation elsewhere) changes what these can do.
                .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidCloseUndoGroup)) { _ in model.edit.undoTick += 1 }
                .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { _ in model.edit.undoTick += 1 }
                .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange)) { _ in model.edit.undoTick += 1 }
            }
            .sharedBackgroundVisibility(.hidden)
        } else if model.section == .organise {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 2) {
                    TopBarButton(title: "Undo", symbol: "arrow.uturn.backward") { model.organise.undoLast() }
                        .disabled(!model.organise.canUndoLast)
                        .help("Undo the last change (⌘Z)")
                    activityButton
                }
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 2) {
                    TopBarButton(title: "Notes", symbol: "note.text", active: showNotes) { showNotes.toggle() }
                        .help("Notes: a scratchpad kept in MediaPull, not in any folder")
                        .popover(isPresented: $showNotes, arrowEdge: .bottom) {
                            NotesView(store: app.notes).frame(width: 560, height: 400)
                        }
                    TopBarButton(title: "Downloads", symbol: "arrow.down.circle", active: model.showDownloads) {
                        if model.showDownloads {
                            model.setShowing(.downloads, false)
                        } else {
                            model.showDownloads(model.instagramPageAddress)
                        }
                    }
                    .help("Download this page: an Instagram account, a video or a whole gallery (⌥⌘4)")
                    activityButton
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }

    private var windowName: String {
        switch model.section {
        case .organise: model.organise.source.root?.lastPathComponent ?? "Organise"
        case .devices: model.devices.device?.name ?? "Devices"
        case .edit: model.edit.current?.lastPathComponent ?? "Edit/Frame"
        case .collect: model.browser.title.isEmpty ? "MediaPull" : model.browser.title
        }
    }

    private var activityButton: some View {
        TopBarButton(title: "Activity", symbol: "list.bullet.rectangle", active: showActivity, badge: app.jobs.activeCount) {
            showActivity.toggle()
        }
        .help("All jobs: downloads, analysis and organising (⇧⌘J)")
        .popover(isPresented: $showActivity, arrowEdge: .bottom) {
            ActivityView().frame(width: 460, height: 420)
        }
    }
}
