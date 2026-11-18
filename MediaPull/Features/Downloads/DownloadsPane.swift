import MediaPullCore
import MediaPullEngines
import MediaPullStore
import SwiftUI

/// What the Downloads pane is set up for (SPEC section 11.11).
enum DownloadTarget: Equatable {
    case empty
    case instagram(PullDraft)
    case video(URL)
    case gallery(URL, site: SiteInfo)
    case unknown(URL)
    /// Text that is not a web address, an @account or a #hashtag.
    case notAddress
    /// Several addresses at once (R-1111d), listed in `DownloadsModel.batch`.
    case list
    /// An Instagram page with no download of its own here (a location, the Reels feed, a highlight). Instagram traffic
    /// only goes through the Instagram options, which keep its pace, its one-at-a-time rule and its checkpoints (R-1113).
    case instagramPage(URL)
}

/// One window's Downloads pane: an address, the right tool for it, and its options (no sheets).
@Observable
final class DownloadsModel {
    var address = ""
    var target: DownloadTarget = .empty
    /// The address follows the browser until the person types their own.
    var followsBrowser = true
    var checking = false
    var range = ""
    var dateWindow: InstagramDateWindow = .allTime
    var dateFrom = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    var dateTo = Date()
    var onlyNew = true
    /// For a gallery: the parts of a profile and the site's switches, remembered per site.
    var include: Set<String> = []
    var switches: [String: Bool] = [:]
    @ObservationIgnored var checkTask: Task<Void, Never>?
    /// An address another app sent (Services, R-1111c) only fills in the pane: nothing is looked up on the network until
    /// the person asks (D-82, audit 7, C7-M5).
    var lookUpsHeld = false
    /// Several addresses at once (R-1111d): each one and what it is, and whether Download All is running.
    var batch: [BatchEntry] = []
    var batchRunning = false
    var batchStopping = false
    /// Said under the list: an address that arrived while Download All ran, or addresses past the 200 listed.
    var batchNotice: String?

    isolated deinit {
        checkTask?.cancel()
    }
    var app: AppModel { .shared }

    /// Sets the address and works out how to download it: Instagram, a video, or any other site gallery-dl supports.
    /// Several addresses typed or pasted at once become a list (R-1111d).
    func use(_ text: String, fromBrowser: Bool = false, fromOutside: Bool = false) {
        // While Download All runs, its list stays: nothing typed, sent or dropped replaces it, and the pane says so.
        if batchRunning {
            if !fromBrowser { batchNotice = "Download All is running. Add \(text) when it has finished." }
            return
        }
        if fromBrowser, !followsBrowser { return }
        if !fromBrowser { followsBrowser = text.isEmpty }
        // The browser's own page and anything typed are looked up as usual; only what came from outside waits (C8-m2).
        lookUpsHeld = fromOutside
        address = text
        checkTask?.cancel()
        checking = false
        if !fromBrowser, !batchRunning, let parts = Self.addresses(in: text) {
            useList(parts)
            return
        }
        target = immediateTarget(text, typed: !fromBrowser)
        guard case let .unknown(url) = target else { return }
        checking = true
        checkTask = Task { [weak self] in
            // Each check starts the engine; wait for a pause in typing so only the finished address is checked.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let site = await self?.app.engines.siteInfo(for: url)
            guard let self, !Task.isCancelled, self.address == text else { return }
            self.checking = false
            if let site { self.useGallery(url, site: site) }
        }
    }

    /// What an address is, without asking the engine: an Instagram download, a likely video, or a page still to check
    /// (`.unknown`). `typed` allows a bare username (R-1104); the browser's own address never is one.
    func immediateTarget(_ text: String, typed: Bool) -> DownloadTarget {
        var input = AddressInput.parse(text.hasPrefix("#") ? "https://www.instagram.com/explore/tags/\(text.dropFirst())/" : text)
        if case .invalid = input, typed, let name = AddressInput.bareUsername(text) { input = .handle(name) }
        func hashtagDraft(_ tag: String) -> DownloadTarget {
            var draft = app.engines.draft(username: "")
            draft.hashtag = tag
            draft.folderName = tag
            draft.incremental = false
            return .instagram(draft)
        }
        if let tag = Self.hashtag(text) { return hashtagDraft(tag) }
        if case let .web(url) = input, let host = url.host?.lowercased(), host == "instagram.com" || host.hasSuffix(".instagram.com") {
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count >= 3, parts[0] == "explore", parts[1] == "tags", let tag = Self.hashtag("#" + parts[2]) {
                return hashtagDraft(tag)
            }
            return .instagramPage(url)
        }
        switch input {
        case .invalid:
            return text.isEmpty ? .empty : .notAddress
        case let .instagramPost(_, url), let .instagramHighlight(_, url):
            return .instagram(app.engines.draft(username: "", postURL: url))
        case let .instagramStories(name, url):
            // The person's own tray of stories from accounts they follow (signed in), not an account called "me".
            if name == "me" {
                var draft = app.engines.draft(username: "")
                draft.content = [.storiesTray]
                draft.contentFromAddress = true
                return .instagram(draft)
            }
            // A link to one story gets that story; a link to someone's stories gets their stories, not the whole account.
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count >= 3, parts[2].allSatisfy(\.isNumber) {
                return .instagram(app.engines.draft(username: "", postURL: url))
            }
            var draft = app.engines.draft(username: name)
            draft.content = [.stories]
            draft.contentFromAddress = true
            return .instagram(draft)
        case let .instagramProfile(_, url) where AddressInput.isSavedCollection(url):
            // Saved posts and collections are the person's own (signed in), saved into Saved posts (D-52), never the
            // account named in the link (audit 4, C4-M3).
            var draft = app.engines.draft(username: "")
            draft.content = [.saved]
            draft.collectionURL = url
            draft.contentFromAddress = true
            return .instagram(draft)
        case .instagramProfile, .handle:
            return .instagram(app.engines.draft(username: input.instagramUsername ?? ""))
        case let .web(url):
            return VideoPage.isLikely(url) ? .video(url) : .unknown(url)
        }
    }

    private func useGallery(_ url: URL, site: SiteInfo) {
        (include, switches) = rememberedOptions(site)
        target = .gallery(url, site: site)
    }

    /// The parts of a profile and the switches last chosen for a site, or its defaults.
    func rememberedOptions(_ site: SiteInfo) -> (include: Set<String>, switches: [String: Bool]) {
        let prefs = app.preferences
        let choices = SiteCatalogue.visibleChoices(site.choices)
        let remembered = prefs.galleryChoices[site.category].map { Set($0).intersection(choices) }
        let include = remembered.flatMap { $0.isEmpty ? nil : $0 } ?? Set(site.defaults).intersection(choices)
        let key = SiteInfoKey(category: site.category, baseCategory: site.baseCategory)
        let switches = Dictionary(uniqueKeysWithValues: app.sites.switches(key).map {
            ($0.key, prefs.gallerySwitches[site.category]?[$0.key] ?? $0.default)
        })
        return (include, switches)
    }

    /// Remembers the choices for the site, so the next download from it starts the same way.
    func remember(_ site: SiteInfo) {
        app.preferences.galleryChoices[site.category] = Array(include).sorted()
        app.preferences.gallerySwitches[site.category] = switches
    }

    static func hashtag(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        let tag = trimmed.dropFirst().filter { $0.isLetter || $0.isNumber || $0 == "_" }
        return tag.isEmpty ? nil : String(tag).lowercased()
    }
}

struct DownloadsPane: View {
    @Bindable var model: WindowModel
    @Bindable var downloads: DownloadsModel
    @FocusState private var focused: Bool
    @Environment(\.openWindow) private var openWindow
    private var app: AppModel { .shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Downloads").font(.headline)
                Spacer()
                PaneMenu(pane: .downloads, window: model)
                Button { model.setShowing(.downloads, false) } label: { Image(systemName: "xmark").foregroundStyle(.secondary) }
                    .accessibilityLabel("Close Downloads")
                    .buttonStyle(.borderless)
                    .help("Close Downloads (⌥⌘4)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(app.preferences.theme.headerBackground)
            Divider()
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
                TextField("Address, @account or #hashtag to download",
                          text: Binding(get: { downloads.address }, set: { downloads.use($0) }))
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .disabled(downloads.batchRunning)
                if !downloads.followsBrowser, let url = model.browser.url {
                    Button("This Page") {
                        downloads.followsBrowser = true
                        downloads.use(url.absoluteString, fromBrowser: true)
                    }
                    .controlSize(.small)
                    .help("Download from the page in the browser")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    form
                    ActiveDownloads()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { if let url = model.browser.url { downloads.use(url.absoluteString, fromBrowser: true) } }
        .onChange(of: model.browser.url) { _, url in if let url { downloads.use(url.absoluteString, fromBrowser: true) } }
        .onChange(of: model.downloadsFocus) { _, _ in focused = true }
        // A link dropped here fills in the address, as one sent from another app does: nothing is looked up or started
        // until the person asks (R-1111c, D-82, audit 8, A8-M1).
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }) else { return false }
            downloads.use(url.absoluteString, fromOutside: true)
            return true
        }
    }

    private var symbol: String {
        switch downloads.target {
        case .instagram: "camera"
        case .video: "film"
        case .gallery: "photo.stack"
        case .list: "list.bullet"
        default: "arrow.down.circle"
        }
    }

    @ViewBuilder
    private var form: some View {
        switch downloads.target {
        case .empty:
            hint("""
                Open a page in the browser, or type an address, @account or #hashtag. Instagram, YouTube, Bluesky, Pinterest, ArtStation \
                and hundreds of other sites work here.
                """)
        case let .instagram(draft):
            InstagramForm(model: model, draft: Binding(get: { draft }, set: { downloads.target = .instagram($0) }))
                .id(draft.username + (draft.hashtag ?? "") + (draft.postURL?.absoluteString ?? ""))
        case let .video(url):
            VideoForm(model: model, url: url).id(url)
        case let .gallery(url, site):
            GalleryForm(model: model, downloads: downloads, url: url, site: site).id(url)
        case .list:
            DownloadList(model: model, downloads: downloads)
        case .notAddress:
            hint("Enter a web address, an Instagram @account or a #hashtag.")
        case .instagramPage:
            hint("Instagram downloads use the Instagram options: enter an @account, a post or reel link, or a #hashtag.")
        case let .unknown(url):
            if downloads.checking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking what can be downloaded here…").foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    hint("There is no gallery download for this page. Media on it still appears in Extracted Media as you browse.")
                    Button("Look for a Video on This Page") { downloads.target = .video(url) }
                        .controlSize(.small)
                        .help("Video pages on over a thousand sites can be downloaded, even when they are not recognised here")
                }
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Any site gallery-dl supports (SPEC R-1111b): the site and what is at the address, the parts of a profile to download,
/// the site's own switches, sign-in, dates and folder; the same care as the Instagram options.
struct GalleryForm: View {
    @Bindable var model: WindowModel
    @Bindable var downloads: DownloadsModel
    let url: URL
    let site: SiteInfo
    @State private var hasSession = false
    private var app: AppModel { .shared }
    private var key: SiteInfoKey { SiteInfoKey(category: site.category, baseCategory: site.baseCategory) }
    private var name: String { app.sites.name(key) }
    private var choices: [String] { SiteCatalogue.visibleChoices(site.choices) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(.quaternary)
                    Image(systemName: "photo.stack").foregroundStyle(.secondary)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline)
                    Text(pageDescription).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Save As…") { model.chooseExactFolder { start(into: $0) } }
                    .disabled(!choices.isEmpty && downloads.include.isEmpty)
                    .help("Choose the folder the files go into, exactly; only what it does not hold yet is added")
                Button("Download") { start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!choices.isEmpty && downloads.include.isEmpty || model.saveFolder == nil)
            }
            signInNotice
            if !choices.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Download").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Use Defaults") { downloads.include = Set(site.defaults).intersection(choices) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    FlowToggles(items: choices, isOn: { downloads.include.contains($0) }, label: \.choiceLabel) { choice, on in
                        if on { downloads.include.insert(choice) } else { downloads.include.remove(choice) }
                    }
                }
            }
            let switches = app.sites.switches(key)
            if !switches.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Include").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    FlowToggles(items: switches, isOn: { downloads.switches[$0.key] ?? $0.default }, label: \.label) { item, on in
                        downloads.switches[item.key] = on
                    }
                }
            }
            LabeledContent("Posted") {
                Picker("Posted", selection: $downloads.dateWindow) {
                    ForEach(InstagramDateWindow.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if downloads.dateWindow == .custom {
                HStack {
                    DatePicker("From", selection: $downloads.dateFrom, in: ...Date(), displayedComponents: .date)
                    DatePicker("To", selection: $downloads.dateTo, in: ...Date(), displayedComponents: .date)
                }
            }
            LabeledContent("Items") {
                TextField("All", text: $downloads.range, prompt: Text("All, or a range such as 1-50"))
                    .labelsHidden()
            }
            // What the library holds now is skipped (D-103, audit 19, A19-m2).
            Toggle("Skip what was downloaded from this address and is still here", isOn: $downloads.onlyNew)
            if choices.count > 1 {
                Toggle(
                    "Sort into folders by type (\(choices.prefix(2).map(SiteCatalogue.choiceLabel).joined(separator: ", "))…)",
                    isOn: Binding(get: { app.preferences.typeSubfolders }, set: { app.preferences.typeSubfolders = $0 })
                )
            }
            if let keys = SiteKeys.forSite(site.category, baseCategory: site.baseCategory) {
                SiteKeyFields(model: model, category: site.category, siteName: name, keys: keys)
            }
            SaveFolderRow(model: model)
            HStack {
                Spacer()
                // The form's own address, which can differ from the page in the browser.
                Button("List in Extracted Media") { _ = app.engines.startSiteScan(url: url, category: site.category, window: model) }
                    .help("List everything without saving it, then pick what to save")
            }
        }
        .task(id: site.category) {
            // The same domain the download sends cookies for (EngineService.startGalleryDownload).
            let domain = PublicSuffix.shared.registrableDomain(url.host ?? "")
            hasSession = !(await app.cookies(forDomain: domain)).isEmpty
        }
    }

    private var pageDescription: String {
        let kind: String = switch site.subcategory {
        case "user", "profile", "artist", "creator", "account", "channel", "blog": "Profile"
        case "post", "image", "status", "tweet", "work", "artwork", "deviation", "submission", "photo", "video", "note": "One post"
        case "search": "Search results"
        case "tag", "tags", "hashtag": "Tag"
        default: SiteCatalogue.choiceLabel(site.subcategory)
        }
        let what = choices.isEmpty ? "every image and video here" : "the parts chosen below"
        return "\(kind) · \(what), at the highest quality"
    }

    @ViewBuilder
    private var signInNotice: some View {
        let signIn = app.sites.signIn(key)
        let home = site.root ?? URL(string: app.sites.site(key)?.home ?? "")
        switch signIn {
        case .none:
            EmptyView()
        case .optional, .cookies, .required:
            if hasSession {
                Label("Uses your \(name) session from the browser.", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                notice(signIn == .optional ? "Sign in to \(name) in the browser to include private or age-restricted posts."
                    : "\(name) needs you signed in. Sign in in the browser, then download.", button: home)
            }
        case .oauth, .key:
            if SiteKeys.forSite(site.category, baseCategory: site.baseCategory) != nil {
                notice("Public pages work with a shared key that \(name) sometimes limits. Your own key, below, avoids that.", button: nil)
            } else {
                notice(signIn == .key ? "\(name) may ask for an API key for some pages. Public pages usually work without one."
                    : "Some \(name) pages need the site's own app sign-in, which MediaPull does not set up. Public pages usually work.",
                    button: nil)
            }
        }
    }

    private func notice(_ text: String, button url: URL?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill").foregroundStyle(.orange)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let url {
                Button("Sign In") { model.browser.load(url) }.controlSize(.small)
            }
        }
        .padding(8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    /// `exactFolder`: Save As (D-108), exactly into that folder.
    private func start(into exactFolder: URL? = nil) {
        guard var root = (exactFolder ?? model.saveFolder).map(app.destination(for:)) else { return }
        root.exact = exactFolder != nil
        downloads.remember(site)
        let dates = downloads.dateWindow.bounds(from: downloads.dateFrom, to: downloads.dateTo)
        let include = choices.filter { downloads.include.contains($0) }
        let switches = Dictionary(uniqueKeysWithValues: app.sites.switches(key).map { ($0.key, downloads.switches[$0.key] ?? $0.default) })
        app.engines.startGalleryDownload(url: url, site: site, include: include, switches: switches, range: downloads.range.nonEmpty,
                                         from: dates.from, to: dates.to, onlyNew: downloads.onlyNew, root: root, window: model)
    }
}

private extension String {
    var choiceLabel: String { SiteCatalogue.choiceLabel(self) }
}

/// The person's own API key for a site, optional, kept in the Keychain (SPEC R-1111b).
struct SiteKeyFields: View {
    @Bindable var model: WindowModel
    let category: String
    let siteName: String
    let keys: SiteKeys
    @State private var values: [String: String] = [:]
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text("""
                    Optional. Your own key avoids the limits of the shared one and uses your account's settings. It is kept in the \
                    Keychain and only sent to \(siteName).
                    """)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(keys.fields, id: \.self) { field in
                    SecureField(field.label, text: Binding(get: { values[field.option] ?? "" }, set: { value in
                        values[field.option] = value
                        SiteKeychain.set(value, category, field.option)
                    }))
                    .textFieldStyle(.roundedBorder)
                }
                if let page = keys.getKeyURL {
                    Button("Get a Key in the Browser") { model.browser.load(page) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .padding(.top, 4)
        } label: {
            Label(values.values.contains { !$0.isEmpty } ? "Using your own \(siteName) API key" : "Your own \(siteName) API key",
                  systemImage: "key")
                .font(.callout)
        }
        .onAppear { values = SiteKeychain.keys(for: category, fields: keys.fields) }
    }
}

/// Downloads in progress and just finished, with their progress.
struct ActiveDownloads: View {
    private var app: AppModel { .shared }

    var body: some View {
        let jobs = app.jobs.jobs.filter { [.pull, .stream, .scan].contains($0.kind) }.prefix(6)
        if !jobs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                ForEach(Array(jobs)) { job in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.title).font(.callout).lineLimit(1)
                            Text([job.state.label, job.summary].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if job.state.isActive {
                                if let progress = job.progress {
                                    ProgressView(value: progress)
                                } else {
                                    ProgressView().progressViewStyle(.linear)
                                }
                            }
                        }
                        if job.state.canCancel {
                            Button { job.cancel() } label: { Image(systemName: "xmark.circle") }
                                .accessibilityLabel("Cancel").buttonStyle(.borderless).help("Cancel")
                        } else if let url = job.destination {
                            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                                .accessibilityLabel("Show in Finder")
                                .buttonStyle(.borderless).help("Show in Finder")
                        }
                    }
                }
            }
        }
    }
}
