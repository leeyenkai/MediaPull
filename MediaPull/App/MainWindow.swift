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
    @State private var showActivity = false

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
                    .library: AnyView(LibraryPane(model: model, library: model.library)),
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
                        .organiseSource: AnyView(OrganiseFolderPane(model: model, organise: model.organise, pane: model.organise.source)),
                        .organiseWork: AnyView(OrganiseWorkPane(model: model, organise: model.organise)),
                        .organiseTarget: AnyView(OrganiseFolderPane(model: model, organise: model.organise, pane: model.organise.target)),
                    ]
                )
                .background(Color(nsColor: .windowBackgroundColor))
                .opacity(model.section == .organise ? 1 : 0)
                .allowsHitTesting(model.section == .organise)
                .accessibilityHidden(model.section != .organise)
                .onAppear {
                    organiseShown = true
                    model.organise.prepare()
                }
            }
        }
        .tint(app.preferences.theme.accent)
        .frame(minWidth: 1100, minHeight: 700)
        .onChange(of: app.preferences.theme) {
            model.gridRevision += 1
            model.library.revision += 1
        }
        .background(WindowAccessor { window in
            if model.hostWindow !== window { model.hostWindow = window }
        })
        .navigationTitle(windowName)
        .toolbar { toolbar }
        .focusedSceneValue(\.windowModel, model)
        .task { SelfTestRunner.startIfRequested(model) }
        .sheet(item: Binding(
            get: { app.walkthroughWindow === model ? app.walkthrough : nil },
            set: { app.walkthrough = $0 }
        )) { mode in
            WalkthroughView(mode: mode)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // The window's name, then the section tabs, right of the traffic lights (D-62).
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 12) {
                Text(windowName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 260, alignment: .leading)
                    .fixedSize(horizontal: windowName.count < 30, vertical: false)
                Picker("Section", selection: $model.section) {
                    ForEach(WindowSection.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Collect media from the web, or organise media in folders (⌃⌘1, ⌃⌘2)")
            }
            .padding(.leading, 4)
        }
        if model.section == .organise {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.organise.undoLast() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(!model.organise.history.contains { !$0.undone })
                    .help("Undo the last change (⌘Z)")
                activityButton
            }
        } else {
            collectToolbar
        }
    }

    private var windowName: String {
        model.section == .organise ? (model.organise.source.root?.lastPathComponent ?? "Organise")
            : (model.browser.title.isEmpty ? "MediaPull" : model.browser.title)
    }

    @ToolbarContentBuilder
    private var collectToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                if model.showDownloads {
                    model.setShowing(.downloads, false)
                } else {
                    model.showDownloads(model.pageKind.instagramUsername.map { "@\($0)" })
                }
            } label: {
                Label("Downloads", systemImage: model.showDownloads ? "arrow.down.circle.fill" : "arrow.down.circle")
            }
            .help("Download this page: an Instagram account, a video or a whole gallery (⌥⌘4)")
            activityButton
        }
    }

    private var activityButton: some View {
        Button { showActivity.toggle() } label: {
            Label("Activity", systemImage: app.jobs.activeCount > 0 ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
        }
        .badge(app.jobs.activeCount)
        .help("All jobs: downloads, analysis and organising (⇧⌘J)")
        .popover(isPresented: $showActivity, arrowEdge: .bottom) {
            ActivityView().frame(width: 460, height: 420)
        }
    }
}
