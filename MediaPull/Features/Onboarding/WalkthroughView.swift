import AppKit
import MediaPullCore
import SwiftUI

enum WalkthroughMode: String, Identifiable {
    /// First launch: welcome, the optional tour, then choosing a library folder and Instagram sign-in.
    case firstRun
    /// The tour alone, from Settings or the Help menu.
    case tour

    var id: String { rawValue }
}

/// A page of the tour: which pane it is about and what to say.
struct TourPage: Identifiable {
    let id: Int
    let pane: PaneID?
    let symbol: String
    let title: String
    let text: String

    static let all: [TourPage] = [
        TourPage(id: 0, pane: .source, symbol: "globe", title: "Browse any page",
                 text: "Open pages in tabs (⌘T), bookmark them (⌘D) and find them again in History (⌘Y). "
                     + "The address field also takes an Instagram handle such as @nasa."),
        TourPage(id: 1, pane: .extracted, symbol: "sparkle.magnifyingglass", title: "Media appears as you browse",
                 text: "Every image, video and stream on the page shows up in Extracted Media, including the ones that load as you scroll. "
                     + "Scroll to End fetches the rest; the chips and the resolution slider narrow it down."),
        TourPage(id: 2, pane: .preview, symbol: "crop.rotate", title: "Preview and edit",
                 text: "Select an item or a saved file to see it full size with its details and every version found. "
                     + "Crop, rotate, flip and rename it right there (⌘E)."),
        TourPage(id: 3, pane: .library, symbol: "folder.badge.plus", title: "Save into your folders",
                 text: "Drag items onto a Library folder or press ⌘S. MediaPull saves the largest version as JPEG, PNG, GIF or MP4, "
                     + "and in Archive folders adds a small metadata file next to each one."),
        TourPage(id: 4, pane: .source, symbol: "arrow.down.circle", title: "Download from hundreds of sites",
                 text: "The Downloads pane (⌥⌘4) follows the page you are on: whole Instagram, Bluesky or ArtStation profiles, "
                     + "galleries, and videos and playlists from YouTube and other video sites, each with its own options. "
                     + """
                         Sign in to a site in the browser to include what only signed-in visitors see. Later downloads fetch only what is \
                         new.
                         """),
        TourPage(id: 5, pane: nil, symbol: "rectangle.3.group", title: "Make it yours",
                 text: "Drag the dividers to resize panes. Move or stack them with the arrange button in each title bar or "
                     + "View > Arrange Panes, and choose a theme in Settings > Appearance."),
        TourPage(id: 6, pane: .library, symbol: "wand.and.stars", title: "Search and organise",
                 text: "Search your folders by name, text or what a photo shows, and filter by faces, colour, place and more. "
                     + "Switch to Organise at the top of the window to sort any folder by date, event, subject or person, with "
                     + "a preview first and undo afterwards. Analysis runs only on this Mac."),
        TourPage(id: 7, pane: nil, symbol: "lock.shield", title: "Read-only by design",
                 text: "MediaPull only reads from the web. It never uploads files and never likes, follows or posts. "
                     + "You can open this walkthrough again from Settings or the Help menu."),
    ]
}

/// The first-run walkthrough and the tour (SPEC 7.1, 7.2).
struct WalkthroughView: View {
    let mode: WalkthroughMode
    @State private var step = 0
    @State private var folder = AppModel.suggestedRootURL
    @State private var layout: SaveLayout = .archive
    private var app: AppModel { .shared }

    private enum Step: Equatable {
        case welcome, tour(Int), library, instagram
    }

    private var steps: [Step] {
        let tour = TourPage.all.map { Step.tour($0.id) }
        return mode == .firstRun ? [.welcome] + tour + [.library, .instagram] : tour
    }

    private var current: Step { steps[min(step, steps.count - 1)] }
    private var accent: Color { app.preferences.theme.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch current {
                case .welcome: welcome
                case let .tour(index): tourPage(TourPage.all[index])
                case .library: library
                case .instagram: instagram
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            .id(step)
            footer
        }
        .padding(26)
        .frame(width: 580, height: 520)
        .tint(accent)
        .interactiveDismissDisabled(mode == .firstRun)
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text("Welcome to MediaPull").font(.largeTitle.weight(.semibold))
            Text("Collect the images and videos from any web page, or download whole profiles, galleries and videos from hundreds "
                + "of sites, into your own folders at the highest quality available.")
                .fixedSize(horizontal: false, vertical: true)
            Label("Only reads from the web. MediaPull never uploads files and never posts, likes or follows.", systemImage: "lock.shield")
            Label("Saves normal JPEG, PNG, GIF and MP4 files. WebP and other modern formats are converted for you.", systemImage: "photo")
            Spacer(minLength: 0)
            Text("Would you like a one-minute tour? You can skip it and open it later from Settings.")
                .foregroundStyle(.secondary)
            Text(InstagramNotice.terms)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tourPage(_ page: TourPage) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            WindowSketch(highlight: page.pane, symbol: page.symbol, accent: accent, theme: app.preferences.theme)
                .frame(height: 230)
                .frame(maxWidth: .infinity)
            Text(page.title).font(.title2.weight(.semibold))
            Text(page.text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where should saved media go?").font(.title2.weight(.semibold))
            HStack {
                Image(systemName: "folder.fill").foregroundStyle(.tint)
                Text(folder.path).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Change…") {
                    FolderPicker.chooseFolder(title: "Library Folder", prompt: "Choose", start: folder.deletingLastPathComponent(),
                                              window: nil) { url in if let url { folder = url } }
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            if let warning = AppModel.locationWarning(for: folder) {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
            Picker("Layout", selection: $layout) {
                ForEach(SaveLayout.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Text(layout == .archive
                ? "Recommended. Each file gets a small JSON file with its caption, date, source and post grouping, in the gallery-dl "
                + "format that media-library and archiving tools import."
                : "Only the media files, nothing else.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var instagram: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Signing in to sites (optional)").font(.title2.weight(.semibold))
            Text("Some sites, such as Instagram and Twitter, only show posts to signed-in visitors. Sign in to them in MediaPull's "
                + "browser whenever you need to; your password goes only to the site, and MediaPull never sees it.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Downloads wait between requests so accounts are not flagged. If a site asks you to confirm it is you, the page "
                + "opens in the browser and downloads pause until you are done.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Sign In to Instagram Now") { finish(signIn: true) }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if case .tour = current {
                HStack(spacing: 6) {
                    ForEach(TourPage.all) { page in
                        Circle()
                            .fill(current == .tour(page.id) ? accent : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }
                .accessibilityLabel("Page \(tourIndex + 1) of \(TourPage.all.count)")
            }
            Spacer()
            switch current {
            case .welcome:
                Button("Skip Tour") { go(to: steps.firstIndex(of: .library) ?? 0) }
                Button("Take the Tour") { go(to: step + 1) }
                    .keyboardShortcut(.defaultAction) // lint:allow shortcut the walkthrough is a sheet
                    .buttonStyle(.borderedProminent)
            case .tour:
                if step > 0 { Button("Back") { go(to: step - 1) } }
                if mode == .tour {
                    if step < steps.count - 1 {
                        Button("Close") { close() }
                            .keyboardShortcut(.cancelAction) // lint:allow shortcut the walkthrough is a sheet
                    }
                } else if step < steps.count - 1 {
                    Button("Skip") { go(to: steps.firstIndex(of: .library) ?? step + 1) }
                }
                Button(step == steps.count - 1 ? "Done" : "Next") {
                    if step == steps.count - 1 { close() } else { go(to: step + 1) }
                }
                .keyboardShortcut(.defaultAction) // lint:allow shortcut the walkthrough is a sheet
                .buttonStyle(.borderedProminent)
            case .library:
                Button("Back") { go(to: step - 1) }
                Button("Continue") { go(to: step + 1) }
                    .keyboardShortcut(.defaultAction) // lint:allow shortcut the walkthrough is a sheet
                    .buttonStyle(.borderedProminent)
            case .instagram:
                Button("Back") { go(to: step - 1) }
                Button("Start Using MediaPull") { finish(signIn: false) }
                    .keyboardShortcut(.defaultAction) // lint:allow shortcut the walkthrough is a sheet
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.top, 16)
    }

    private var tourIndex: Int {
        if case let .tour(index) = current { return index }
        return 0
    }

    private func go(to target: Int) {
        let next = min(max(target, 0), steps.count - 1)
        // Reduce Motion (R-2401): pages change without the transition.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { step = next } else {
            withAnimation(.easeInOut(duration: 0.22)) { step = next }
        }
    }

    private func close() {
        app.walkthrough = nil
    }

    private func finish(signIn: Bool) {
        let folder = folder
        let layout = layout
        app.preferences.defaultLayout = layout
        app.preferences.onboardingDone = true
        Task {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            await app.addRoot(folder, layout: layout, makeDefault: true)
            app.frontWindow?.library.selectedFolder = folder
        }
        if signIn { app.frontWindow?.browser.load(URL(string: "https://www.instagram.com/accounts/login/")!) }
        app.walkthrough = nil
    }
}

/// A small drawing of the window with one pane picked out, for the tour.
struct WindowSketch: View {
    var highlight: PaneID?
    var symbol: String
    var accent: Color
    var theme: AppTheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.background.secondary)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            VStack(spacing: 8) {
                HStack(spacing: 5) {
                    ForEach(0 ..< 3, id: \.self) { _ in Circle().fill(.secondary.opacity(0.35)).frame(width: 8, height: 8) }
                    Capsule().fill(.secondary.opacity(0.15)).frame(height: 12).padding(.leading, 30).padding(.trailing, 60)
                }
                HStack(spacing: 6) {
                    pane(.source).frame(maxWidth: .infinity)
                    VStack(spacing: 6) {
                        pane(.extracted)
                        pane(.preview).frame(height: 62)
                    }
                    .frame(maxWidth: .infinity)
                    pane(.library).frame(width: 78)
                }
            }
            .padding(12)
            if highlight == nil {
                Image(systemName: symbol)
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(.white)
                    .padding(20)
                    .background(accent.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: accent.opacity(0.4), radius: 12, y: 4)
            }
        }
        .frame(width: 440)
        .accessibilityHidden(true)
    }

    private func pane(_ id: PaneID) -> some View {
        let lit = highlight == id
        return RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(lit ? AnyShapeStyle(theme == .system ? AnyShapeStyle(accent.gradient) : AnyShapeStyle(theme.gradient))
                : AnyShapeStyle(Color.secondary.opacity(0.12)))
            .overlay {
                if lit {
                    VStack(spacing: 4) {
                        Image(systemName: symbol).font(.system(size: 22, weight: .medium))
                        Text(id.title).font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                } else {
                    Text(id.title).font(.system(size: 8)).foregroundStyle(.tertiary)
                }
            }
            .opacity(highlight == nil || lit ? 1 : 0.7)
    }
}
