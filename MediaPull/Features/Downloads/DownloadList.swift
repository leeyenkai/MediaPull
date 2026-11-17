import MediaPullCore
import MediaPullEngines
import SwiftUI

/// One address of several typed or pasted at once (R-1111d).
struct BatchEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case checking
        case instagram(PullDraft)
        case video(URL)
        case gallery(URL, SiteInfo)
        case unrecognised
    }

    enum Progress: Equatable {
        case waiting, running, done, failed(String), skipped
    }

    let id = UUID()
    var text: String
    var kind: Kind = .checking
    var progress: Progress = .waiting

    var label: String {
        switch kind {
        case .checking: "Checking…"
        case let .instagram(draft):
            draft.hashtag.map { "Instagram #\($0)" } ?? (draft.postURL != nil ? "Instagram post" : "Instagram @\(draft.username)")
        case .video: "Video"
        case let .gallery(_, site):
            "Gallery on \(AppModel.shared.sites.name(SiteInfoKey(category: site.category, baseCategory: site.baseCategory)))"
        case .unrecognised: "Not recognised: skipped"
        }
    }

    var canRun: Bool {
        switch kind {
        case .instagram, .video, .gallery: true
        case .checking, .unrecognised: false
        }
    }
}

extension DownloadsModel {
    /// Two or more addresses separated by spaces or new lines (at most 200), each one a web address, @account or #hashtag;
    /// nil for anything else, which is read as one address.
    static func addresses(in text: String) -> [String]? {
        AddressInput.several(in: text)
    }

    /// Lists the addresses and works out what each one is, asking the engine only about pages that need it.
    func useList(_ all: [String]) {
        let parts = Array(all.prefix(200))
        batchNotice = all.count > 200 ? "Only the first 200 of \(all.count) addresses are listed." : nil
        batch = parts.map { BatchEntry(text: $0) }
        target = .list
        let text = address
        checkTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            for (index, part) in parts.enumerated() {
                guard let self, !Task.isCancelled, self.address == text else { return }
                let kind = await self.kind(of: part)
                guard !Task.isCancelled, self.address == text, self.batch.indices.contains(index) else { return }
                self.batch[index].kind = kind
            }
        }
    }

    private func kind(of text: String) async -> BatchEntry.Kind {
        switch immediateTarget(text, typed: false) {
        case let .instagram(draft):
            return .instagram(draft)
        case let .video(url):
            return .video(url)
        case let .unknown(url):
            if let site = await app.engines.siteInfo(for: url) { return .gallery(url, site) }
            return .unrecognised
        default:
            return .unrecognised
        }
    }

    /// Download All: one address after another, each with its kind's remembered options, into the window's save folder.
    func runAll(window: WindowModel) {
        guard !batchRunning, let root = window.saveFolder.map(app.destination(for:)) else { return }
        batchRunning = true
        batchStopping = false
        // The list belongs to its window: closing the window ends it after the download running now.
        Task { [weak self, weak window] in
            guard let self else { return }
            defer {
                self.batchRunning = false
                self.batchStopping = false
            }
            for index in self.batch.indices {
                guard !self.batchStopping, let window else { return }
                let entry = self.batch[index]
                guard entry.canRun, entry.progress == .waiting else {
                    if !entry.canRun { self.batch[index].progress = .skipped }
                    continue
                }
                self.batch[index].progress = .running
                let job = await self.start(entry, root: root, window: window)
                if let job {
                    while !job.state.isFinished {
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                }
                guard self.batch.indices.contains(index), self.batch[index].id == entry.id else { return }
                switch job?.state {
                case .completed: self.batch[index].progress = .done
                case let .failed(reason): self.batch[index].progress = .failed(reason)
                case .none: self.batch[index].progress = .failed("It could not be started.")
                default: self.batch[index].progress = .failed("Stopped.")
                }
            }
        }
    }

    /// The download running now finishes; no further one starts.
    func stopAll() {
        batchStopping = true
    }

    private func start(_ entry: BatchEntry, root: SaveDestination, window: WindowModel) async -> Job? {
        switch entry.kind {
        case var .instagram(draft):
            if draft.postURL == nil, draft.hashtag == nil { await app.engines.applyStoredOptions(to: &draft) }
            return app.engines.startPull(draft, scanOnly: false, window: window)
        case let .gallery(url, site):
            let options = rememberedOptions(site)
            let choices = SiteCatalogue.visibleChoices(site.choices).filter { options.include.contains($0) }
            return app.engines.startGalleryDownload(url: url, site: site, include: choices, switches: options.switches, range: nil,
                                                    from: nil, to: nil, onlyNew: true, root: root, window: window)
        case let .video(url):
            guard case let .success(info) = await app.engines.videoInfo(for: url) else { return nil }
            var extras = BridgeRequest.Extras()
            extras.playlist = VideoForm.looksLikeList(url)
            return app.engines.saveVideo(info, pageURL: url, format: .bestMP4, height: nil, extras: extras, root: root, window: window)
        case .checking, .unrecognised:
            return nil
        }
    }
}

/// The list of several addresses, with one Download All button (R-1111d).
struct DownloadList: View {
    @Bindable var model: WindowModel
    @Bindable var downloads: DownloadsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(downloads.batch) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    symbol(entry)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.text).lineLimit(1).truncationMode(.middle)
                        Text(status(entry)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }
            let runnable = downloads.batch.filter(\.canRun).count
            HStack {
                Text("Each one uses the options last chosen for its kind of download, one after another.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if downloads.batchRunning {
                    Button(downloads.batchStopping ? "Stopping After This One" : "Stop After This One") { downloads.stopAll() }
                        .disabled(downloads.batchStopping)
                } else {
                    Button("Download All (\(runnable))") { downloads.runAll(window: model) }
                        .buttonStyle(.borderedProminent)
                        .disabled(runnable == 0 || model.saveFolder == nil || downloads.batch.contains { $0.kind == .checking })
                }
            }
            .controlSize(.small)
            if let notice = downloads.batchNotice {
                Text(notice).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            SaveFolderRow(model: model)
        }
    }

    private func status(_ entry: BatchEntry) -> String {
        switch entry.progress {
        case .waiting: entry.label
        case .running: entry.label + ": downloading (details in Activity)"
        case .done: entry.label + ": done"
        case let .failed(reason): entry.label + ": " + reason
        case .skipped: entry.label
        }
    }

    @ViewBuilder
    private func symbol(_ entry: BatchEntry) -> some View {
        switch entry.progress {
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .waiting, .skipped:
            Image(systemName: entry.canRun ? "circle" : "minus.circle").foregroundStyle(.secondary)
        }
    }
}
