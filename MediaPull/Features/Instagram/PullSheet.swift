import MediaPullCore
import MediaPullEngines
import MediaPullLibrary
import MediaPullNet
import MediaPullStore
import SwiftUI

/// Instagram options in the Downloads pane (SPEC R-1105): what to pull from an account or hashtag, dates and folder.
struct InstagramForm: View {
    @Bindable var model: WindowModel
    @Binding var draft: PullDraft
    /// Where an account pull goes: into the folder that already holds the account, or a new one (D-78).
    @State private var placeNote: String?
    private var app: AppModel { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let tag = draft.hashtag {
                Label("Posts tagged #\(tag), newest first, saved in \(SaveTarget.tagsFolder)/\(tag)", systemImage: "number")
                    .font(.callout)
            } else if let url = draft.postURL {
                let what = url.path.contains("/highlights/") ? "highlight's" : url.path.hasPrefix("/stories/") ? "story's" : "post's"
                Label("This \(what) photos and videos, at the highest quality", systemImage: "photo.on.rectangle")
                    .font(.callout)
            } else {
                HStack(alignment: .center) {
                    AccountCard(username: draft.username, showErrors: app.engines.signedIn)
                    Button("Download") { app.engines.startPull(draft, scanOnly: false, window: model) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canStart || model.saveFolder == nil)
                }
            }
            if !app.engines.signedIn {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Instagram needs you signed in to list an account's posts.").font(.callout)
                        Text(InstagramNotice.terms).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Button("Sign In") { model.browser.load(URL(string: "https://www.instagram.com/accounts/login/")!) }
                        .controlSize(.small)
                }
                .padding(8)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            if draft.hashtag == nil, draft.postURL == nil {
                ForEach(InstagramContent.Group.allCases, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(group.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            if group == .media {
                                Button("Use Defaults") {
                                    draft.content = draft.content.filter { $0.group != .media }.union(InstagramContent.defaults)
                                }
                                .buttonStyle(.link)
                                .font(.caption)
                            }
                        }
                        FlowToggles(items: InstagramContent.allCases.filter { $0.group == group }, isOn: { draft.content.contains($0) },
                                    label: \.label, help: { $0.detail }) { content, on in
                            if on { draft.content.insert(content) } else { draft.content.remove(content) }
                        }
                        .disabled(group == .yours && !app.engines.signedIn || group != .yours && draft.username.isEmpty)
                    }
                }
            }
            if draft.postURL == nil { postedOptions }
            Toggle("Sort into folders by type (posts, reels, stories…)", isOn: Binding(
                get: { app.preferences.typeSubfolders }, set: { app.preferences.typeSubfolders = $0 }
            ))
            SaveFolderRow(model: model)
            if let placeNote, draft.hashtag == nil, draft.postURL == nil, !draft.username.isEmpty {
                Text(placeNote).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Picker("Pace", selection: $draft.pacing) {
                    ForEach(PacingPreset.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .fixedSize()
                if draft.hashtag == nil, draft.postURL == nil, let posts = app.engines.accounts[draft.username]?.postCount {
                    Text(estimateText(posts: posts))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("An update stops at the posts the folder already has, so it usually takes a minute or two.")
                }
                Spacer()
                Button("List in Extracted Media") {
                    var scan = draft
                    scan.incremental = false
                    app.engines.startPull(scan, scanOnly: true, window: model)
                }
                .disabled(!canStart)
                .help("List the media without saving it, then pick what to save")
                if draft.hashtag != nil || draft.username.isEmpty {
                    Button("Download") { app.engines.startPull(draft, scanOnly: false, window: model) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canStart || model.saveFolder == nil)
                }
            }
        }
        .task(id: draft.username) {
            guard !draft.username.isEmpty else { return }
            var copy = draft
            await app.engines.applyStoredOptions(to: &copy)
            if copy.username == draft.username { draft = copy }
            await app.engines.lookup(draft.username)
        }
        .task(id: "\(draft.username)|\(draft.folderName)|\(model.saveFolder?.path ?? "")") { await findPlace() }
    }

    private func findPlace() async {
        guard !draft.username.isEmpty, let saveFolder = model.saveFolder else {
            placeNote = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        let account = draft.username
        let name = FileNaming.safeTopFolder(draft.folderName.isEmpty ? account : draft.folderName)
        let root = app.root(containing: saveFolder)?.url
        let note = await Task.detached(priority: .utility) { () -> String in
            let target = AccountFolders.resolveTarget(account: account, saveFolder: saveFolder, root: root)
            guard let existing = target.existing else {
                // The name the pull will really use: numbered when a folder of that name holds something else.
                let folder = AccountFolders.newFolder(named: name, in: target.parent)
                return "Saves into a new folder “\(folder.lastPathComponent)” in “\(target.parent.lastPathComponent)”."
            }
            // Named only: reading every file just to count them would repeat what the pull itself does (audit 2, C2-m11).
            return "Adds only what “\(existing.lastPathComponent)” doesn't have yet."
        }.value
        guard !Task.isCancelled else { return }
        placeNote = note
    }

    @ViewBuilder
    private var postedOptions: some View {
        LabeledContent("Posted") {
            Picker("Posted", selection: $draft.dateWindow) {
                ForEach(InstagramDateWindow.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        if draft.dateWindow == .custom {
            HStack {
                DatePicker("From", selection: $draft.dateFrom, in: ...Date(), displayedComponents: .date)
                DatePicker("To", selection: $draft.dateTo, in: ...Date(), displayedComponents: .date)
            }
        }
        Toggle("Only new posts (stop at the posts the folder already has)", isOn: $draft.incremental)
            .disabled(draft.hashtag == nil && draft.username.isEmpty)
        Text(InstagramNotice.quality).font(.caption).foregroundStyle(.secondary)
    }

    private func estimateText(posts: Int) -> String {
        let estimate = draft.pacing.estimate(posts: posts)
        let time = Duration.seconds(max(estimate.seconds, 60))
            .formatted(.units(allowed: [.hours, .minutes], width: .wide, maximumUnitCount: 2))
        return "Whole account: about \(estimate.requests) requests, \(time)"
    }

    private var canStart: Bool {
        if draft.hashtag != nil || draft.postURL != nil { return true }
        let chosen = draft.content.filter { $0.group == .yours ? app.engines.signedIn : !draft.username.isEmpty }
        return !chosen.isEmpty
    }
}

/// Toggles that wrap onto as many lines as the pane needs.
struct FlowToggles<Item: Hashable>: View {
    let items: [Item]
    let isOn: (Item) -> Bool
    let label: KeyPath<Item, String>
    var help: (Item) -> String? = { _ in nil }
    let set: (Item, Bool) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6, alignment: .leading)],
                      alignment: .leading, spacing: 6) { chips }
        }
    }

    private var chips: some View {
        ForEach(items, id: \.self) { item in
            // The same chips as the Extracted filters: filled when on.
            ChipToggle(title: item[keyPath: label], isOn: Binding(get: { isOn(item) }, set: { set(item, $0) }))
                .help(help(item) ?? "")
        }
    }
}

/// Where downloads go: the window's save folder (D-70), changed here or in the Library pane.
struct SaveFolderRow: View {
    @Bindable var model: WindowModel

    var body: some View {
        LabeledContent("Save into") {
            HStack(spacing: 0) {
                SaveFolderMenu(model: model)
                Spacer(minLength: 0)
            }
        }
    }
}

struct AccountCard: View {
    var username: String
    /// Hidden while signed out: the sign-in notice below says why the lookup failed.
    var showErrors = true
    @State private var avatar: CGImage?
    private var app: AppModel { .shared }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(.quaternary)
                if let avatar {
                    Image(decorative: avatar, scale: 1).resizable().clipShape(Circle())
                } else {
                    Image(systemName: "person.fill").foregroundStyle(.secondary)
                }
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                if let account = app.engines.accounts[username] {
                    Text(account.fullName?.nonEmpty ?? "@\(account.username)").font(.headline)
                    Text(line(account)).font(.caption).foregroundStyle(.secondary)
                } else if let error = app.engines.lookupErrors[username] {
                    Text(username.isEmpty ? "No account" : "@\(username)").font(.headline)
                    if showErrors {
                        Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                } else if username.isEmpty {
                    Text("Your saved posts and followed stories").font(.headline)
                } else {
                    Text("@\(username)").font(.headline)
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Looking up the account…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
        .task(id: app.engines.accounts[username]?.avatarURL) {
            guard let url = app.engines.accounts[username]?.avatarURL else { return }
            avatar = await app.thumbnails.thumbnail(for: url, maxPixel: 120, context: .init())?.image
        }
    }

    private func line(_ account: BridgeAccount) -> String {
        var parts = ["@\(account.username)"]
        if let posts = account.postCount { parts.append("\(posts) posts") }
        if account.isPrivate { parts.append(account.followedByViewer == true ? "private, you follow" : "private") }
        return parts.joined(separator: " · ")
    }
}

/// Plain words about Instagram that appear where they matter (R-201, R-1109).
enum InstagramNotice {
    static let terms = "Automated collection from Instagram may breach Instagram's terms. Any rate limit, check or restriction "
        + "Instagram applies falls on the signed-in account. You are responsible for respecting the rights of the people whose "
        + "media you save."

    static let quality = "Instagram's largest version is usually 1080 or 1440 pixels wide; it is not the original upload."
}
