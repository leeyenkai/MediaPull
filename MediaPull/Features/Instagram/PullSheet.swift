import MediaPullCore
import MediaPullEngines
import MediaPullLibrary
import MediaPullNet
import MediaPullStore
import SwiftUI

/// "Pull Account…" (SPEC R-1105).
struct PullSheet: View {
    @Bindable var model: WindowModel
    @State var draft: PullDraft
    @State private var usernameText = ""
    @State private var lookupTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    private var app: AppModel { .shared }

    init(model: WindowModel, draft: PullDraft) {
        self.model = model
        _draft = State(initialValue: draft)
        _usernameText = State(initialValue: draft.username)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pull an Instagram Account").font(.title2.weight(.semibold))
            HStack {
                TextField("Username, @handle or profile link", text: $usernameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { lookUp() }
                Button("Look Up") { lookUp() }
                    .disabled(cleanUsername.isEmpty)
            }
            AccountCard(username: draft.username)

            if !app.engines.signedIn {
                Banner(symbol: "key.fill", tint: .orange,
                       text: "You are not signed in to Instagram. Instagram shows only a few posts, and no stories or highlights, without a signed-in session.") {
                    Button("Sign In") {
                        model.browser.load(URL(string: "https://www.instagram.com/accounts/login/")!)
                        dismiss()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Form {
                Section("Content") {
                    ForEach(InstagramContent.allCases, id: \.self) { content in
                        Toggle(content.label, isOn: Binding(
                            get: { draft.content.contains(content) },
                            set: { on in if on { draft.content.insert(content) } else { draft.content.remove(content) } }
                        ))
                    }
                }
                Section("Dates") {
                    Toggle("Only since last pull", isOn: $draft.incremental)
                    HStack {
                        Toggle("From", isOn: $draft.useDateFrom)
                        DatePicker("", selection: $draft.dateFrom, displayedComponents: .date)
                            .labelsHidden()
                            .disabled(!draft.useDateFrom)
                        Toggle("To", isOn: $draft.useDateTo)
                        DatePicker("", selection: $draft.dateTo, displayedComponents: .date)
                            .labelsHidden()
                            .disabled(!draft.useDateTo)
                    }
                }
                Section("Save to") {
                    Picker("Library folder", selection: $draft.rootID) {
                        ForEach(app.roots) { root in
                            Text(root.name).tag(Optional(root.id))
                        }
                    }
                    TextField("Account folder", text: $draft.folderName)
                    Picker("SaveLayout", selection: $draft.layout) {
                        ForEach(SaveLayout.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Pace", selection: $draft.pacing) {
                        ForEach(PacingPreset.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 380)

            Text(estimate)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Scan Only") {
                    var scan = draft
                    scan.incremental = false
                    app.engines.startPull(scan, scanOnly: true, window: model)
                    dismiss()
                }
                .disabled(draft.username.isEmpty || draft.content.isEmpty)
                Button("Pull") {
                    app.engines.startPull(draft, scanOnly: false, window: model)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(draft.username.isEmpty || draft.content.isEmpty || draft.rootID == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task {
            if !draft.username.isEmpty {
                var copy = draft
                await app.engines.applyStoredOptions(to: &copy)
                draft = copy
                await app.engines.lookup(draft.username)
            }
        }
        .onDisappear { lookupTask?.cancel() }
    }

    private var cleanUsername: String {
        let text = usernameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name = AddressInput.parse(text.hasPrefix("@") || text.contains(".com") ? text : "@" + text).instagramUsername { return name }
        return ""
    }

    private func lookUp() {
        let name = cleanUsername
        guard !name.isEmpty else { return }
        draft.username = name
        if draft.folderName.isEmpty || draft.folderName != name { draft.folderName = name }
        lookupTask?.cancel()
        lookupTask = Task {
            var copy = draft
            await app.engines.applyStoredOptions(to: &copy)
            draft = copy
            await app.engines.lookup(name)
        }
    }

    private var estimate: String {
        guard let account = app.engines.accounts[draft.username], let posts = account.postCount, posts > 0 else {
            return "MediaPull waits between requests so the account is not flagged. Large accounts take a while."
        }
        let requests = Int((Double(posts) / 12).rounded(.up)) + 2
        let average = (draft.pacing.delay[0] + draft.pacing.delay[1]) / 2
        let minutes = max(1, Int((Double(requests) * average / 60).rounded(.up)))
        return "About \(posts) posts, roughly \(requests) requests. A full pull takes about \(minutes) minute\(minutes == 1 ? "" : "s"); later pulls only fetch new posts."
    }
}

struct AccountCard: View {
    var username: String
    @State private var avatar: CGImage?
    private var app: AppModel { .shared }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(.quaternary)
                if let avatar {
                    Image(decorative: avatar, scale: 1).resizable().clipShape(Circle())
                } else {
                    Image(systemName: "person.fill").foregroundStyle(.secondary)
                }
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                if let account = app.engines.accounts[username] {
                    Text(account.fullName?.nonEmpty ?? "@\(account.username)").font(.headline)
                    Text(line(account)).font(.caption).foregroundStyle(.secondary)
                } else if let error = app.engines.lookupErrors[username] {
                    Text(username.isEmpty ? "No account" : "@\(username)").font(.headline)
                    Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                } else if username.isEmpty {
                    Text("Enter an account").font(.headline)
                    Text("For example nasa or @natgeo").font(.caption).foregroundStyle(.secondary)
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
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
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
