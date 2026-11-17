import MediaPullBrowser
import MediaPullCore
import MediaPullEngines
import MediaPullNet
import SwiftUI

/// Settings (SPEC section 20).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }
            ConversionSettings().tabItem { Label("Formats", systemImage: "photo.on.rectangle") }
            AnalysisSettings().tabItem { Label("Analysis", systemImage: "sparkle.magnifyingglass") }
            FaceSettings().tabItem { Label("Faces", systemImage: "person.2") }
            InstagramSettings().tabItem { Label("Instagram", systemImage: "person.crop.square") }
            EngineSettings().tabItem { Label("Engines", systemImage: "shippingbox") }
            AdvancedSettings().tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 660, height: 560)
        .tint(AppModel.shared.preferences.theme.accent)
    }
}

/// Theme and pane arrangement (SPEC R-2010, R-701a).
struct AppearanceSettings: View {
    @Bindable var preferences = AppModel.shared.preferences

    var body: some View {
        Form {
            Section("Theme") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 10) {
                    ForEach(AppTheme.allCases) { theme in
                        ThemeSwatch(theme: theme, selected: preferences.theme == theme)
                            .onTapGesture { preferences.theme = theme }
                    }
                }
                .padding(.vertical, 4)
                Text("The theme colours buttons, selections and pane titles. System uses the accent colour from System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Panes") {
                Picker("Arrangement", selection: $preferences.paneArrangement) {
                    ForEach(PaneArrangement.presets, id: \.name) { preset in
                        Text(preset.name).tag(preset.arrangement)
                    }
                    if !PaneArrangement.presets.contains(where: { $0.arrangement == preferences.paneArrangement }) {
                        Text("Custom").tag(preferences.paneArrangement)
                    }
                }
                PaneDiagram(arrangement: preferences.paneArrangement, accent: preferences.theme.accent)
                    .frame(height: 92)
                Text("Drag the dividers to resize panes. To move a pane, use the arrange button in its title bar or View > Arrange Panes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reset Pane Sizes") { PaneSplitController.resetSavedSizes() }
            }
        }
        .formStyle(.grouped)
    }
}

/// A small picture of the arrangement.
struct PaneDiagram: View {
    var arrangement: PaneArrangement
    var accent: Color

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(arrangement.columns.enumerated()), id: \.offset) { _, column in
                VStack(spacing: 4) {
                    ForEach(column, id: \.self) { pane in
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(pane == .preview ? accent.opacity(0.35) : Color.secondary.opacity(0.18))
                            .overlay { Text(pane.title).font(.caption2).lineLimit(1).minimumScaleFactor(0.7).padding(2) }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct GeneralSettings: View {
    @Bindable var preferences = AppModel.shared.preferences
    private var app: AppModel { .shared }

    var body: some View {
        Form {
            Section("Getting started") {
                HStack {
                    Text("A short tour of the browser, Extracted Media, the Preview, saving and Instagram.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show Walkthrough") { app.showWalkthrough(.tour) }
                }
            }
            Section("Duplicates") {
                DuplicateCommands(library: nil)
                Text("Duplicates are found with checksums and perceptual hashes of each picture, on this Mac, within each library folder. "
                    + "Orange frames mark identical files; purple frames mark the same or a similar picture saved differently.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Browser") {
                Toggle("Remember browsing history", isOn: $preferences.rememberHistory)
                HStack {
                    Text("""
                        \(app.browsing.history.entries.count) pages in history, \
                        \(app.browsing.bookmarks.folders.reduce(0) { $0 + $1.bookmarks.count }) bookmarks. Both stay on this Mac.
                        """)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Menu("Clear History") {
                        ForEach(BrowsingStore.ClearRange.allCases) { range in
                            Button(range.label) { app.browsing.clearHistory(range) }
                        }
                    }
                    .fixedSize()
                    .disabled(app.browsing.history.entries.isEmpty)
                }
            }
            Section("Library folders") {
                ForEach(app.roots) { root in
                    HStack {
                        Image(systemName: root.isDefault ? "folder.fill.badge.person.crop" : "folder")
                        VStack(alignment: .leading) {
                            Text(root.name)
                            Text(root.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            if let warning = AppModel.locationWarning(for: root.url) {
                                Text(warning).font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Text(root.layout.shortLabel).foregroundStyle(.secondary)
                        if !root.isDefault {
                            Button("Make Default") {
                                Task {
                                    await app.store?.setDefault(root.id)
                                    await app.reloadRoots()
                                }
                            }
                        }
                        Button("Remove") { Task { await app.removeRoot(root.id) } }
                    }
                }
                Button("Add Folder…") {
                    FolderPicker.chooseFolder(title: "Add a Library Folder", prompt: "Add",
                                              start: AppModel.suggestedRootURL, window: nil) { url in
                        if let url { Task { await app.addRoot(url) } }
                    }
                }
            }
            Section("Saving") {
                Picker("Layout for new folders", selection: $preferences.defaultLayout) {
                    ForEach(SaveLayout.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("""
                    Archive keeps a small JSON file next to each item with its caption, date, source and post grouping, in the format \
                    gallery-dl uses. Media-library and archiving tools can import these folders with their details intact.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("When a file name is taken", selection: $preferences.conflict) {
                    ForEach(ConflictPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Set file dates to the post or page date", isOn: $preferences.setFileDates)
                Toggle("Record where each file came from (Finder Get Info)", isOn: $preferences.setWhereFroms)
                Stepper("Save \(preferences.saveConcurrency) files at a time", value: $preferences.saveConcurrency, in: 1 ... 8)
            }
            Section("Name templates") {
                TemplateField(title: "Archive, Instagram", text: $preferences.archiveEngineTemplate, archive: true)
                TemplateField(title: "Archive, web pages", text: $preferences.archiveWebTemplate, archive: true)
                TemplateField(title: "Plain", text: $preferences.plainTemplate, archive: false)
                Text("Tokens: " + NameTemplate.tokens.map { "{\($0)}" }.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Extracted media") {
                Toggle("Clear the list when moving to another page", isOn: $preferences.clearOnNavigation)
                Toggle("Look up sizes of visible items automatically", isOn: $preferences.autoProbe)
                Toggle("Notify when long jobs finish", isOn: $preferences.notifyWhenDone)
            }
        }
        .formStyle(.grouped)
    }
}

struct TemplateField: View {
    var title: String
    @Binding var text: String
    var archive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(title, text: $text)
                .font(.body.monospaced())
            let problems = archive ? NameTemplate(text).archiveProblems() : []
            if let problem = problems.first {
                Text(problem + " The default is used until this is fixed.").font(.caption).foregroundStyle(.red)
            } else {
                Text("Example: " + example).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var example: String {
        var context = NameContext(date: Date(), index: 7)
        context.code = "CnAbCdEfGh"
        context.num = 2
        context.count = 3
        context.username = "example.account"
        context.host = "example.com"
        context.originalName = "photo"
        context.hash = "9f2c4e0b7a1d"
        return NameTemplate(text).render(context) + ".jpg"
    }
}

struct ConversionSettings: View {
    @Bindable var preferences = AppModel.shared.preferences

    var body: some View {
        Form {
            Section("Images") {
                Text("""
                    WebP, AVIF, HEIC and JPEG XL images are converted: lossy images to JPEG at maximum quality, lossless or transparent \
                    images to PNG. Colour profiles and photo metadata are kept.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Keep WebP, AVIF and HEIC as they are in Plain folders", isOn: $preferences.keepOriginalModernImages)
                Picker("Animated images become", selection: $preferences.animated) {
                    ForEach(AnimatedPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("SVG and audio files are saved only in Plain folders.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Video") {
                Picker("Codec", selection: $preferences.video) {
                    ForEach(VideoCodecPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text(preferences.video.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct InstagramSettings: View {
    @Bindable var preferences = AppModel.shared.preferences
    private var app: AppModel { .shared }
    @State private var cleared = false

    var body: some View {
        Form {
            Section("Session") {
                HStack {
                    Image(systemName: app.engines.signedIn ? "checkmark.seal.fill" : "xmark.seal")
                        .foregroundStyle(app.engines.signedIn ? .green : .secondary)
                    Text(app.engines.signedIn ? "Signed in to Instagram in MediaPull's browser" : "Not signed in")
                    Spacer()
                    Button("Sign In…") {
                        app.frontWindow?.browser.load(URL(string: "https://www.instagram.com/accounts/login/")!)
                    }
                }
                Button("Clear Instagram Session") {
                    Task {
                        await CookieBridge.clearWebsiteData(matching: ["instagram", "facebook", "fbcdn", "cdninstagram"])
                        await app.engines.refreshSignIn()
                        cleared = true
                    }
                }
                if cleared { Text("Instagram data was removed from MediaPull.").font(.caption).foregroundStyle(.secondary) }
                Text("""
                    MediaPull never sees your password. Your session stays in this app's browser and is shared with the download engine \
                    only while a job runs.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Pulls") {
                Text("Chosen for new pulls").font(.caption).foregroundStyle(.secondary)
                ForEach(InstagramContent.allCases.filter { $0.group != .yours }, id: \.self) { content in
                    Toggle(content.label, isOn: Binding(
                        get: { preferences.defaultContent.contains(content) },
                        set: { on in
                            if on { preferences.defaultContent.insert(content) } else { preferences.defaultContent.remove(content) }
                        }
                    ))
                }
                Button("Restore Defaults") {
                    preferences.defaultContent = preferences.defaultContent.filter { $0.group == .yours }.union(InstagramContent.defaults)
                }
                Picker("Pace", selection: $preferences.pacing) {
                    ForEach(PacingPreset.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Sort into folders by type", isOn: $preferences.typeSubfolders)
                Text("""
                    posts, reels, stories, highlights and profile pictures folders inside each account folder. Stories and highlights \
                    always get their own folders.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper("Stop a sync after \(preferences.stopAfterKnown) posts already saved",
                        value: $preferences.stopAfterKnown, in: 3 ... 60)
            }
            Section {
                Text("""
                    Automated collection may breach Instagram's terms. The signed-in account bears any limits or checks Instagram applies, \
                    and you are responsible for respecting the rights of the people whose media you save.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct EngineSettings: View {
    @Bindable var preferences = AppModel.shared.preferences
    private var app: AppModel { .shared }

    var body: some View {
        Form {
            Section("Installed") {
                LabeledContent("gallery-dl", value: app.engineVersions?.galleryDL ?? "unknown")
                LabeledContent("yt-dlp", value: app.engineVersions?.ytDLP ?? "unknown")
                LabeledContent("Python", value: app.engineVersions?.python ?? "unknown")
                LabeledContent("ffmpeg", value: app.engineVersions?.ffmpeg ?? "unknown")
                ForEach(app.engineProblems, id: \.self) { problem in
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Updates") {
                Toggle("Check for engine updates every week", isOn: $preferences.weeklyEngineCheck)
                HStack {
                    Button("Check Now") { Task { await app.checkForEngineUpdates(automatic: false) } }
                        .disabled(app.isCheckingEngines)
                    if app.isCheckingEngines { ProgressView().controlSize(.small) }
                    Spacer()
                    if let last = preferences.lastEngineCheck {
                        Text("Last checked \(Format.relative(last))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(app.engineUpdates) { update in
                    HStack {
                        Text("\(update.name) \(update.current) → \(update.available)")
                        Spacer()
                        if let reason = update.blockedReason { Text(reason).font(.caption).foregroundStyle(.orange) }
                    }
                }
                if app.engineUpdates.contains(where: { $0.blockedReason == nil }) {
                    Button("Install Updates") { Task { await app.installEngineUpdates() } }
                        .buttonStyle(.borderedProminent)
                }
                if let message = app.engineMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("Use Previous Version") {
                        Task {
                            do {
                                try await app.engineManager?.usePreviousVersions()
                                app.engineMessage = "Using the previous engine versions."
                            } catch {
                                app.engineMessage = "The previous versions could not be used: \(error.localizedDescription)"
                            }
                            await app.refreshEngineVersions()
                        }
                    }
                    Button("Reset to Built-In Engines") {
                        Task {
                            do {
                                try await app.engineManager?.resetToBuiltIn()
                                app.engineMessage = "Using the engines built into MediaPull."
                            } catch {
                                app.engineMessage = "The engines could not be reset: \(error.localizedDescription)"
                            }
                            await app.refreshEngineVersions()
                        }
                    }
                }
                Text("""
                    Updates are downloaded from PyPI, checked against their published checksums and tested before they are used. Instagram \
                    changes often, so keeping the engines current keeps pulls working.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Licences") {
                Button("Show Licences and Sources") {
                    if let folder = Bundle.main.resourceURL?.appendingPathComponent("Licenses") {
                        NSWorkspace.shared.open(folder)
                    }
                }
                Text("""
                    gallery-dl (GPL-2.0), yt-dlp (Unlicense), Python (PSF), ffmpeg (LGPL-2.1) and their dependencies are included \
                    unmodified.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AdvancedSettings: View {
    @State private var entries: [EgressEntry] = []
    private var app: AppModel { .shared }

    var body: some View {
        Form {
            Section("Network activity") {
                Text("Every request MediaPull makes by itself, newest first. All are reads (GET or HEAD); nothing is uploaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Table(entries.reversed()) {
                    TableColumn("Time") { Text($0.time.formatted(date: .omitted, time: .standard)) }
                        .width(70)
                    TableColumn("Method") { Text($0.method) }
                        .width(50)
                    TableColumn("Host") { Text($0.host) }
                    TableColumn("Purpose") { Text($0.purpose.rawValue) }
                        .width(80)
                    TableColumn("Status") { Text($0.status.map(String.init) ?? "") }
                        .width(45)
                }
                .frame(minHeight: 220)
                Button("Refresh") { Task { entries = await app.gate.entries() } }
            }
            Section("Website data") {
                Button("Clear All Website Data") {
                    Task {
                        await CookieBridge.clearWebsiteData(matching: nil)
                        await app.gate.clearCache()
                        await app.engines.refreshSignIn()
                    }
                }
                Button("Show Logs Folder") {
                    NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs"))
                }
            }
        }
        .formStyle(.grouped)
        .task { entries = await app.gate.entries() }
    }
}
