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
    private var app: AppModel { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let tag = draft.hashtag {
                Label("Posts tagged #\(tag), newest first, saved in \(SaveTarget.tagsFolder)/\(tag)", systemImage: "number")
                    .font(.callout)
            } else {
                HStack(alignment: .center) {
                    AccountCard(username: draft.username, showErrors: app.engines.signedIn)
                    Button("Download") { app.engines.startPull(draft, scanOnly: false, window: model) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canStart || model.saveFolder == nil)
                }
            }
            if !app.engines.signedIn {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill").foregroundStyle(.orange)
                    Text("Instagram needs you signed in to list an account's posts.").font(.callout)
                    Spacer(minLength: 4)
                    Button("Sign In") { model.browser.load(URL(string: "https://www.instagram.com/accounts/login/")!) }
                        .controlSize(.small)
                }
                .padding(8)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            if draft.hashtag == nil {
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
            Toggle("Only new posts since the last pull", isOn: $draft.incremental)
                .disabled(draft.hashtag == nil && draft.username.isEmpty)
            Toggle("Sort into folders by type (posts, reels, stories…)", isOn: Binding(
                get: { app.preferences.typeSubfolders }, set: { app.preferences.typeSubfolders = $0 }
            ))
            SaveFolderRow(model: model)
            HStack {
                Picker("Pace", selection: $draft.pacing) {
                    ForEach(PacingPreset.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .fixedSize()
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
                        .keyboardShortcut(.defaultAction)
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
    }

    private var canStart: Bool {
        if draft.hashtag != nil { return true }
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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) { chips }
        }
    }

    @ViewBuilder
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
