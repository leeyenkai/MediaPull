import MediaPullCore
import MediaPullEngines
import MediaPullStore
import SwiftUI

/// What the Downloads pane is set up for (SPEC section 11.11).
enum DownloadTarget: Equatable {
    case empty
    case instagram(PullDraft)
    case video(URL)
    case gallery(URL, category: String)
    case unknown(URL)
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
    var rootID: UUID? = AppModel.shared.defaultRoot?.id
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    private var app: AppModel { .shared }

    /// Sets the address and works out how to download it: Instagram, a video, or any other site gallery-dl supports.
    func use(_ text: String, fromBrowser: Bool = false) {
        if fromBrowser, !followsBrowser { return }
        if !fromBrowser { followsBrowser = text.isEmpty }
        address = text
        checkTask?.cancel()
        let input = AddressInput.parse(text.hasPrefix("#") ? "https://www.instagram.com/explore/tags/\(text.dropFirst())/" : text)
        if let tag = Self.hashtag(text) {
            var draft = app.engines.draft(username: "")
            draft.hashtag = tag
            draft.folderName = tag
            draft.incremental = false
            target = .instagram(draft)
            return
        }
        switch input {
        case .invalid:
            target = text.isEmpty ? .empty : .unknown(URL(string: text) ?? URL(fileURLWithPath: "/"))
        case let .instagramPost(_, url):
            target = .instagram(app.engines.draft(username: "", postURL: url))
        case .instagramProfile, .handle, .instagramStories:
            target = .instagram(app.engines.draft(username: input.instagramUsername ?? ""))
        case .instagramHighlight(_, let url), .web(let url):
            if case .instagramHighlight = input {
                target = .unknown(url)
                return
            }
            if VideoPage.isLikely(url) {
                target = .video(url)
                return
            }
            target = .unknown(url)
            checking = true
            checkTask = Task { [weak self] in
                let category = await self?.app.engines.supportedCategory(for: url)
                guard let self, !Task.isCancelled, self.address == text else { return }
                self.checking = false
                if let category { self.target = .gallery(url, category: category) }
            }
        }
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
                    .buttonStyle(.borderless)
                    .help("Close Downloads (⌥⌘4)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(app.preferences.theme.headerBackground)
            Divider()
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
                TextField("Address, @account or #hashtag to download", text: Binding(get: { downloads.address }, set: { downloads.use($0) }))
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
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
    }

    private var symbol: String {
        switch downloads.target {
        case .instagram: "camera"
        case .video: "film"
        case .gallery: "photo.stack"
        default: "arrow.down.circle"
        }
    }

    @ViewBuilder
    private var form: some View {
        switch downloads.target {
        case .empty:
            hint("Open a page, or type an address, @account or #hashtag.")
        case let .instagram(draft):
            InstagramForm(model: model, draft: Binding(get: { draft }, set: { downloads.target = .instagram($0) }))
                .id(draft.username + (draft.hashtag ?? "") + (draft.postURL?.absoluteString ?? ""))
        case let .video(url):
            VideoForm(model: model, url: url).id(url)
        case let .gallery(url, category):
            GalleryForm(model: model, downloads: downloads, url: url, category: category)
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

/// Any site gallery-dl supports: everything at the address, or part of it (SPEC section 12).
struct GalleryForm: View {
    @Bindable var model: WindowModel
    @Bindable var downloads: DownloadsModel
    let url: URL
    let category: String
    private var app: AppModel { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(category.capitalized) gallery: every image and video at this address, at the highest quality.",
                  systemImage: "photo.stack")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Items, such as 1-50 (all if empty)", text: $downloads.range)
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
            Toggle("Only what is new since the last download", isOn: $downloads.onlyNew)
            DestinationPicker(rootID: $downloads.rootID)
            HStack {
                Spacer()
                Button("List in Extracted Media") { model.scanWithSiteExtractor() }
                    .help("List everything without saving it, then pick what to save")
                Button("Download") {
                    guard let root = app.roots.first(where: { $0.id == downloads.rootID }) ?? app.defaultRoot else { return }
                    let dates = downloads.dateWindow.bounds(from: downloads.dateFrom, to: downloads.dateTo)
                    app.engines.startGalleryDownload(url: url, category: category, range: downloads.range.nonEmpty, from: dates.from,
                                                     to: dates.to, onlyNew: downloads.onlyNew, root: root, window: model)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
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
                                if let progress = job.progress { ProgressView(value: progress) } else { ProgressView().progressViewStyle(.linear) }
                            }
                        }
                        if job.state.canCancel {
                            Button { job.cancel() } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).help("Cancel")
                        } else if let url = job.destination {
                            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                                .buttonStyle(.borderless).help("Show in Finder")
                        }
                    }
                }
            }
        }
    }
}
