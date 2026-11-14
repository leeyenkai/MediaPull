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

    var body: some View {
        PaneSplit(
            arrangement: app.preferences.paneArrangement,
            visible: model.visiblePanes,
            panes: [
                .source: AnyView(BrowserPane(model: model)),
                .extracted: AnyView(ExtractedPane(model: model)),
                .preview: AnyView(PreviewPane(model: model)),
                .library: AnyView(LibraryPane(model: model, library: model.library)),
            ]
        )
        .tint(app.preferences.theme.accent)
        .frame(minWidth: 1100, minHeight: 700)
        .onChange(of: app.preferences.theme) {
            model.gridRevision += 1
            model.library.revision += 1
        }
        .background(WindowAccessor { window in
            if model.hostWindow !== window { model.hostWindow = window }
        })
        .navigationTitle(model.browser.title.isEmpty ? "MediaPull" : model.browser.title)
        .toolbar { toolbar }
        .focusedSceneValue(\.windowModel, model)
        .task { SelfTestRunner.startIfRequested(model) }
        .sheet(item: $model.pullDraft) { draft in
            PullSheet(model: model, draft: draft)
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
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.extractionEnabled.toggle()
            } label: {
                Label(model.extractionEnabled ? "Extraction On" : "Extraction Off",
                      systemImage: model.extractionEnabled ? "sparkle.magnifyingglass" : "pause.circle")
            }
            .help(model.extractionEnabled ? "Finding media on pages. Click to pause." : "Paused. Click to find media on pages again.")
            Button {
                model.pullDraft = app.engines.draft(username: model.pageKind.instagramUsername ?? "")
            } label: {
                Label("Pull Account", systemImage: "person.crop.rectangle.stack")
            }
            .help("Pull an Instagram account into a folder")
            Button { openWindow(id: "activity") } label: {
                Label("Activity", systemImage: app.jobs.activeCount > 0 ? "arrow.down.circle.dotted" : "arrow.down.circle")
            }
            .badge(app.jobs.activeCount)
            .help("Downloads and jobs")
            Button { model.setShowing(.preview, !model.showPreview) } label: { Label("Preview", systemImage: "photo.on.rectangle") }
                .help("Show or hide the Preview pane (⌘I)")
        }
    }
}
