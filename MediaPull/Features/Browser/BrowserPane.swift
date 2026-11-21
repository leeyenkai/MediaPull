import MediaPullCore
import SwiftUI

struct AddressField: View {
    @Bindable var model: WindowModel
    @FocusState private var focused: Bool
    @State private var text = ""
    /// True only while the person is editing (clicked, ⌘L or typed). The window can give the field focus
    /// on its own at launch; that must not hide the page's address.
    @State private var editing = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            ZStack(alignment: .leading) {
                TextField("Enter a web address or @instagram handle", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .opacity(editing ? 1 : 0)
                    .onSubmit {
                        model.submitAddress(text)
                        endEditing()
                    }
                    .onExitCommand {
                        text = model.browser.addressText
                        endEditing()
                    }
                    .onChange(of: text) { _, newValue in
                        if focused, newValue != model.browser.addressText { editing = true }
                    }
                if !editing {
                    // Shown from its start while not being edited; a long address fades out before the star.
                    let shown = model.browser.addressText
                    // Drawn in an overlay so a long address never widens the bar.
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 17)
                        .overlay(alignment: .leading) {
                            Text(shown.isEmpty ? "Enter a web address or @instagram handle" : shown)
                                .foregroundStyle(shown.isEmpty ? .tertiary : .primary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .clipped()
                        .mask {
                            HStack(spacing: 0) {
                                Rectangle()
                                LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 36)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { beginEditing() }
                        .accessibilityHidden(true)
                }
            }
            .padding(.trailing, 8)
            if model.browser.isLoading {
                ProgressView(value: model.browser.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 60)
            }
            BookmarkStar(model: model)
                .padding(.leading, 2)
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: TopBarStyle.radius, style: .continuous))
        .onChange(of: model.browser.addressText) { _, newValue in
            if !editing { text = newValue }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { editing = false }
        }
        .onChange(of: model.focusAddressToken) { _, _ in
            beginEditing()
        }
        .onChange(of: model.selectedTabID) { _, _ in
            text = model.browser.addressText
            endEditing()
        }
        .onAppear { text = model.browser.addressText }
        .accessibilityLabel("Address")
    }

    private func beginEditing() {
        text = model.browser.addressText
        editing = true
        focused = true
    }

    private func endEditing() {
        editing = false
        focused = false
    }

    private var icon: String {
        if text.hasPrefix("@") { return "at" }
        switch model.pageKind {
        case .instagramProfile, .instagramPost, .instagramStories, .instagramHighlight: return "person.crop.circle"
        default: return model.browser.url?.scheme == "https" ? "lock.fill" : "globe"
        }
    }
}

/// Navigation for the selected tab, inside the Browser pane (SPEC R-802): back, forward, reload,
/// the address field with its bookmark star, Bookmarks and History, and the pane's arrange menu.
struct BrowserBar: View {
    @Bindable var model: WindowModel
    private var app: AppModel { .shared }

    var body: some View {
        HStack(spacing: 4) {
            Button { model.browser.goBack() } label: { Image(systemName: "chevron.backward").frame(width: 24, height: 24) }
                .accessibilityLabel("Back")
                .disabled(!model.browser.canGoBack)
                .help("Back (⌘[)")
            Button { model.browser.goForward() } label: { Image(systemName: "chevron.forward").frame(width: 24, height: 24) }
                .accessibilityLabel("Forward")
                .disabled(!model.browser.canGoForward)
                .help("Forward (⌘])")
            Button { model.browser.reloadOrStop() } label: {
                Image(systemName: model.browser.isLoading ? "xmark" : "arrow.clockwise").frame(width: 24, height: 24)
            }
            .disabled(model.browser.url == nil)
            .help(model.browser.isLoading ? "Stop loading" : "Reload this page (⌘R)")
            AddressField(model: model)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 4)
            if VideoPage.isLikely(model.browser.url) {
                Button { model.showDownloads(video: true) } label: { Image(systemName: "film.stack").frame(width: 24, height: 24) }
                    .accessibilityLabel("Save Video")
                    .help("Save the video on this page, choosing its format and resolution")
            }
            Button { model.showBrowsingPanel.toggle() } label: { Image(systemName: "bookmark").frame(width: 24, height: 24) }
                .accessibilityLabel("Bookmarks and History")
                .help("Bookmarks and History (⌥⌘B, ⌘Y)")
                .popover(isPresented: $model.showBrowsingPanel, arrowEdge: .bottom) {
                    BrowsingPanel(model: model)
                }
            PaneMenu(pane: .source, window: model)
        }
        .buttonStyle(.borderless)
        .imageScale(.medium)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(app.preferences.theme.headerBackground)
    }
}

struct BrowserPane: View {
    @Bindable var model: WindowModel
    private var app: AppModel { .shared }

    var body: some View {
        VStack(spacing: 0) {
            BrowserBar(model: model)
            TabStrip(model: model)
            if let message = app.engines.gateMessage {
                Banner(symbol: "exclamationmark.shield.fill", tint: .orange, text: message) {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Button("Resume") { Task { await app.engines.resumeAfterCheckpoint() } }
                            .disabled(!app.engines.canResume)
                    }
                    Button("Cancel Instagram Jobs") {
                        for job in app.jobs.jobs where job.kind == .pull || job.kind == .scan {
                            if !job.state.isFinished { job.cancel() }
                        }
                        app.engines.gate = .ready
                    }
                }
            }
            if let message = model.addressMessage {
                Banner(symbol: "info.circle.fill", tint: .blue, text: message) {
                    Button("Dismiss") { model.addressMessage = nil }
                }
            }
            if let error = model.browser.lastError {
                Banner(symbol: "wifi.exclamationmark", tint: .red, text: error) {
                    Button("Try Again") { model.browser.reloadOrStop() }
                }
            }
            ZStack {
                WebViewHost(webView: model.browser.webView)
                if model.browser.url == nil {
                    StartPage(model: model)
                }
            }
        }
    }
}

struct Banner<Actions: View>: View {
    var symbol: String
    var tint: Color
    var text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Shown before the first page loads.
struct StartPage: View {
    @Bindable var model: WindowModel
    @Environment(\.openWindow) private var openWindow
    private var app: AppModel { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("MediaPull")
                        .font(.largeTitle.weight(.semibold))
                    Text("""
                        Browse any page and every image and video on it appears in Extracted Media, including the ones that load as you \
                        scroll. Save them into a folder, or download whole profiles, galleries and videos from hundreds of sites.
                        """)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                StartBookmarks(model: model)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Try").font(.headline)
                    StartRow(symbol: "globe", title: "Open a web page",
                             detail: "Type an address above, for example nytimes.com/international") {
                        model.focusAddressToken += 1
                    }
                    StartRow(
                        symbol: "arrow.down.circle", title: "Or download from one of the supported sites",
                        detail: "Instagram, YouTube, Bluesky, Pinterest and hundreds more: whole profiles, galleries, videos and playlists"
                    ) {
                        model.showDownloads("")
                    }
                    StartRow(symbol: "iphone", title: "Bring in from a phone or camera",
                             detail: "Plug in an iPhone, an Android phone or a camera card and copy only what is new") {
                        model.section = .devices
                    }
                    StartRow(symbol: "folder", title: "Organise a folder",
                             detail: "Sort photos by date, subject or person, find duplicates and people, in place or into a new folder") {
                        model.section = .organise
                    }
                    StartRow(symbol: "arrow.triangle.2.circlepath", title: "Convert WebP, AVIF or HEIC files",
                             detail: "Drop files on the Converter to make high-quality JPEG or PNG copies") {
                        openWindow(id: "converter")
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Label("Read-only", systemImage: "lock.shield")
                        .font(.headline)
                    Text("""
                        MediaPull only reads from the web. It never uploads files and never likes, follows or posts anything. Pages you \
                        browse here can still send their own forms, such as a sign-in form.
                        """)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(32)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
    }
}

struct StartRow: View {
    var symbol: String
    var title: String
    var detail: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium))
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Bookmarks and recently visited pages on the start page of a new tab.
struct StartBookmarks: View {
    @Bindable var model: WindowModel
    private var store: BrowsingStore { AppModel.shared.browsing }

    var body: some View {
        let bookmarks = Array(store.bookmarks.folders.flatMap(\.bookmarks).prefix(8))
        let recent = Array(store.history.entries.prefix(6))
        if !bookmarks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Bookmarks").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(bookmarks) { bookmark in
                        Button { model.browser.load(bookmark.url) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Image(systemName: "bookmark.fill").foregroundStyle(.tint)
                                Text(bookmark.title).font(.callout.weight(.medium)).lineLimit(2)
                                Text(bookmark.url.host ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                            .padding(10)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(bookmark.url.absoluteString)
                    }
                }
            }
        }
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Recently Visited").font(.headline)
                    Spacer()
                    Button("Show All History") {
                        model.browsingPanelTab = .history
                        model.showBrowsingPanel = true
                    }
                    .buttonStyle(.link)
                }
                ForEach(recent) { entry in
                    Button { model.browser.load(entry.url) } label: {
                        HStack {
                            Image(systemName: "clock").foregroundStyle(.secondary)
                            Text(entry.title.isEmpty ? (entry.url.host ?? entry.url.absoluteString) : entry.title).lineLimit(1)
                            Spacer()
                            Text(entry.url.host ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
