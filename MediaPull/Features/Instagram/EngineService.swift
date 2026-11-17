import AppKit
import Foundation
import MediaPullBrowser
import MediaPullCore
import MediaPullEngines
import MediaPullLibrary
import MediaPullMedia
import MediaPullNet
import MediaPullStore
import Observation

/// What the Pull sheet is set up with.
/// A job's private copy of the browser's cookies for one site, written 0600 in a 0700 folder for the engine. When the job
/// ends, cookies the engine refreshed go back to the browser (R-1103) and the copy is deleted.
final class EngineCookies {
    let file: URL
    private let original: [CookieRecord]
    private var finished = false

    /// Throws when the copy cannot be written.
    init(_ cookies: [CookieRecord], job: String = UUID().uuidString) throws {
        file = CookieFile.privateLocation(job: job)
        original = cookies
        do {
            try CookieFile.write(cookies, to: file)
        } catch {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            throw error
        }
    }

    /// For sites where signing in is optional: nil when the browser has no cookies for the site.
    static func optional(_ cookies: [CookieRecord]) -> EngineCookies? {
        cookies.isEmpty ? nil : try? EngineCookies(cookies)
    }

    /// Hands refreshed cookies back and deletes the copy; only the first call does anything.
    func finish() async {
        guard !finished else { return }
        finished = true
        let updated = CookieFile.read(file)
        if !updated.isEmpty { await CookieBridge.update(updated, existing: original) }
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
}

struct PullDraft: Identifiable, Equatable {
    var id = UUID()
    var username: String
    var postURL: URL?
    /// A hashtag to pull instead of an account (without "#").
    var hashtag: String?
    var content: Set<InstagramContent>
    var dateWindow: InstagramDateWindow = .allTime
    var dateFrom = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    var dateTo = Date()
    var folderName: String
    var incremental = true
    var pacing: PacingPreset
    /// An existing folder of the account to update (D-78); nil lets the pull find one in the save folder.
    var accountFolder: URL?
    /// Walk every post and add what the folder lacks, including items deleted from it (D-79); otherwise only new items.
    var findMissing = false
    /// Continue an update that stopped part way, from where it stopped (R-1904).
    var continueFromCursor = false
    /// The content was chosen by the address (a story link pulls stories), so the account's remembered choices do not
    /// replace it.
    var contentFromAddress = false
}

/// The folder a download goes into, with the layout of the library folder holding it (D-70); any folder on the Mac works.
struct SaveDestination {
    var url: URL
    var layout: SaveLayout
}

struct VideoLookupError: Error, Equatable {
    var message: String
}

enum InstagramGateState: Equatable {
    case ready
    case blocked(kind: String, url: URL?, message: String)
    case cooldown(until: Date)
}

/// Instagram and site-extractor jobs through the bundled engines (SPEC sections 11 and 12).
@Observable
final class EngineService {
    @ObservationIgnored unowned let app: AppModel
    var signedIn = false
    var gate: InstagramGateState = .ready
    var accounts: [String: BridgeAccount] = [:]
    var lookupErrors: [String: String] = [:]
    @ObservationIgnored private var instagramQueue: [(job: Job, run: () async -> Void)] = []
    @ObservationIgnored private var instagramBusy = false

    init(app: AppModel) {
        self.app = app
    }

    var bridge: BridgeClient? { app.engineManager.map { BridgeClient(paths: $0.paths) } }

    func refreshSignIn() async {
        let cookies = await CookieBridge.allCookies()
        signedIn = CookieBridge.isSignedInToInstagram(cookies)
    }

    func handleCheckpoint(kind: String, url: URL?, message: String) {
        if kind == "rate_limit" || kind == "feedback" {
            // Cooldowns grow 10, 20, then 40 minutes for repeated limits within a day, across relaunches (R-1114).
            let now = Date()
            let recent = (UserDefaults.standard.array(forKey: Self.rateLimitKey) as? [Double] ?? [])
                .filter { now.timeIntervalSince1970 - $0 < 86400 } + [now.timeIntervalSince1970]
            UserDefaults.standard.set(recent, forKey: Self.rateLimitKey)
            let minutes = [10, 20, 40][min(recent.count, 3) - 1]
            gate = .cooldown(until: now.addingTimeInterval(TimeInterval(minutes * 60)))
        } else {
            gate = .blocked(kind: kind, url: url, message: message)
        }
        let target = url ?? (kind == "login" ? URL(string: "https://www.instagram.com/accounts/login/") : nil)
        if let target, let window = app.frontWindow {
            window.showBrowser = true
            window.browser.load(target)
        }
        // R-1905: the same setting as finished jobs.
        if app.preferences.notifyWhenDone {
            JobCenter.post(title: "Instagram needs your attention", body: gateMessage ?? "Open MediaPull to continue.")
        }
    }

    var gateMessage: String? {
        switch gate {
        case .ready: nil
        case let .blocked(kind, _, _):
            kind == "login" ? "Instagram signed you out. Sign in again in the browser pane, then choose Resume."
                : "Instagram wants to confirm it is you. Complete the check in the browser pane, then choose Resume."
        case let .cooldown(until):
            "Instagram is limiting requests. Pulls can continue after \(until.formatted(date: .omitted, time: .shortened))."
        }
    }

    static let rateLimitKey = "instagramRateLimits"

    /// Whether Resume may be chosen (R-1114): the cooldown is over, or, after a sign-in or a challenge, the browser holds a
    /// session again.
    var canResume: Bool {
        switch gate {
        case .ready: true
        case let .cooldown(until): until <= Date()
        case .blocked: signedIn
        }
    }

    /// Only the person resumes after a checkpoint, and only once the condition is cleared (R-1114).
    func resumeAfterCheckpoint() async {
        await refreshSignIn()
        guard canResume else { return }
        gate = .ready
        for job in app.jobs.jobs {
            if case .blocked = job.state, let resume = job.resume { resume() }
        }
    }

    var canRunInstagram: Bool {
        if case let .cooldown(until) = gate { return until < Date() }
        if case .blocked = gate { return false }
        return true
    }

    // MARK: Lookup

    func lookup(_ username: String) async {
        guard let bridge else {
            lookupErrors[username] = "The download engine is not available."
            return
        }
        // The name is looked up as it is typed; wait for a pause so only the finished name reaches Instagram.
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        lookupErrors[username] = nil
        guard canRunInstagram else {
            lookupErrors[username] = gateMessage ?? "Instagram is not available right now."
            return
        }
        if instagramBusy {
            // Wait for the running Instagram job, then look the account up.
            lookupErrors[username] = "Account details appear once the current Instagram job finishes."
            while instagramBusy, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
            }
            guard !Task.isCancelled else { return }
            lookupErrors[username] = nil
        }
        // A lookup is an Instagram request too: pulls wait for it, one at a time (R-1113).
        instagramBusy = true
        var request = BridgeRequest(op: "account")
        request.username = username
        let job = UUID().uuidString
        let cookies = try? EngineCookies(await app.cookies(forDomain: "instagram.com"), job: job)
        let staging = app.enginePaths?.staging.appendingPathComponent(job)
        defer {
            if let cookies { Task { await cookies.finish() } }
            if let staging { try? FileManager.default.removeItem(at: staging) }
            instagramBusy = false
            pumpInstagram()
        }
        request.cookies = cookies?.file.path
        request.userAgent = app.userAgent
        request.staging = staging?.path
        do {
            var found = false
            var problem: String?
            for try await event in bridge.run(request) {
                switch event {
                case let .account(account):
                    accounts[username] = account
                    found = true
                    await app.store?.updateAccount(username, userID: account.userID, fullName: account.fullName)
                case let .error(code, message, _, true):
                    problem = describe(code: code, message: message)
                case let .checkpoint(kind, url, message):
                    handleCheckpoint(kind: kind, url: url, message: message)
                    problem = gateMessage
                default:
                    break
                }
            }
            // A lookup stopped because the name changed or the pane closed says nothing about the account.
            if !found, !Task.isCancelled { lookupErrors[username] = problem ?? "The account could not be found." }
        } catch {
            if !Task.isCancelled { lookupErrors[username] = error.localizedDescription }
        }
        await cookies?.finish()
    }

    func describe(code: String, message: String) -> String {
        switch code {
        case "private": return "This account is private. Instagram only shows its posts to followers."
        case "not_found":
            return signedIn
                ? "No Instagram account has that name."
                : "Instagram did not answer. Sign in to Instagram in the browser pane to look up accounts."
        case "engine_outdated": return "Instagram may have changed. Check for engine updates in Settings."
        case "login_required": return "Sign in to Instagram in the browser pane first."
        default: return message
        }
    }

    /// Video files engines write; webm and mkv are converted when saved.
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv"]

    // MARK: Drafts

    func draft(username: String, postURL: URL? = nil) -> PullDraft {
        let prefs = app.preferences
        var draft = PullDraft(
            username: username,
            postURL: postURL,
            content: prefs.defaultContent,
            folderName: username,
            pacing: prefs.pacing
        )
        if postURL != nil { draft.content = [.posts] }
        return draft
    }

    func applyStoredOptions(to draft: inout PullDraft) async {
        guard let info = await app.store?.account(draft.username) else {
            draft.incremental = false
            return
        }
        if let options = info.options {
            if !draft.contentFromAddress { draft.content = options.content }
            draft.pacing = options.pacing
        }
        draft.incremental = info.lastPullAt != nil
    }

    // MARK: Pull

    @discardableResult
    func startPull(_ draft: PullDraft, scanOnly: Bool, window: WindowModel?) -> Job? {
        guard let bridge else { return nil }
        let isPost = draft.postURL != nil
        let subject = draft.hashtag.map { "#\($0)" } ?? (draft.username.isEmpty ? "your account" : "@\(draft.username)")
        let title = isPost ? "Instagram post" : (scanOnly ? "Scanning \(subject)" : "Pulling \(subject)")
        let job = Job(kind: scanOnly ? .scan : .pull, title: title)
        job.subtitle = draft.hashtag != nil ? "Posts with this hashtag"
            : InstagramContent.allCases.filter { draft.content.contains($0) }.map(\.label).joined(separator: ", ")
        app.jobs.add(job)
        // An update writes into the account's folder, so that folder's library decides the layout, not the window's (the
        // folder itself may be a library root).
        let root: SaveDestination? = if let folder = draft.accountFolder {
            SaveDestination(url: folder.deletingLastPathComponent(),
                            layout: app.root(containing: folder)?.layout ?? app.preferences.defaultLayout)
        } else {
            (window?.saveFolder ?? app.defaultRoot?.url).map(app.destination(for:))
        }
        if !scanOnly, root == nil {
            app.jobs.finish(job, .failed("Choose where to save first."))
            return job
        }
        if !scanOnly, let root {
            if let tag = draft.hashtag {
                job.destination = root.url.appendingPathComponent(SaveTarget.tagsFolder, isDirectory: true).appendingPathComponent(tag)
            } else if draft.postURL == nil, !draft.username.isEmpty {
                // The account's own folder, found when the pull starts (D-78).
                job.destination = draft.accountFolder
                    ?? root.url.appendingPathComponent(FileNaming.safeTopFolder(draft.folderName.nonEmpty ?? draft.username),
                                                       isDirectory: true)
            } else {
                job.destination = root.url
            }
        }
        job.resume = { [weak self, weak job, weak window] in
            guard let self, let job else { return }
            job.state = .queued
            job.failed = 0
            job.failures = []
            job.finishedAt = nil
            self.enqueueInstagram(job: job) { [weak self, weak job, weak window] in
                guard let job else { return }
                await self?.runPull(job: job, draft: draft, root: root, scanOnly: scanOnly, window: window, bridge: bridge, resuming: true)
            }
        }
        job.retry = job.resume
        enqueueInstagram(job: job) { [weak self, weak job, weak window] in
            guard let job else { return }
            await self?.runPull(job: job, draft: draft, root: root, scanOnly: scanOnly, window: window, bridge: bridge, resuming: false)
        }
        // A one-click update uses the remembered choices without changing them (D-80).
        if !scanOnly, draft.hashtag == nil, !draft.username.isEmpty, draft.accountFolder == nil {
            Task {
                await app.store?.updateAccount(draft.username, options: PullOptions(
                    content: draft.content,
                    rootID: root
                                                                                    .flatMap { app.root(containing: $0.url)?.id },
                    pacing: draft.pacing
                ))
            }
        }
        return job
    }

    /// One Instagram job at a time, across all windows (SPEC R-1113).
    private func enqueueInstagram(job: Job, _ run: @escaping () async -> Void) {
        instagramQueue.append((job, run))
        pumpInstagram()
    }

    /// Runs queued Instagram jobs one at a time. Each job's task is the running pull, so Cancel
    /// stops the engine immediately.
    private func pumpInstagram() {
        guard !instagramBusy else { return }
        while let next = instagramQueue.first, next.job.state.isFinished {
            instagramQueue.removeFirst()
        }
        guard !instagramQueue.isEmpty else { return }
        instagramBusy = true
        let next = instagramQueue.removeFirst()
        next.job.task = Task {
            await next.run()
            self.instagramBusy = false
            self.pumpInstagram()
        }
    }

    private func runPull(job: Job, draft: PullDraft, root: SaveDestination?, scanOnly: Bool, window: WindowModel?, bridge: BridgeClient,
                         resuming: Bool) async
    {
        if case .cancelled = job.state { return }
        guard canRunInstagram else {
            job.state = .blocked(gateMessage ?? "Instagram is not available right now.")
            return
        }
        job.state = .running
        let work = UUID().uuidString
        guard let staging = app.enginePaths?.staging.appendingPathComponent(work, isDirectory: true) else {
            app.jobs.finish(job, .failed("The download engine is not available."))
            return
        }
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let cookies: EngineCookies
        do {
            cookies = try EngineCookies(await app.cookies(forDomain: "instagram.com"), job: work)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            app.jobs.finish(job, .failed("The sign-in cookies could not be prepared: \(error.localizedDescription)"))
            return
        }
        defer {
            try? FileManager.default.removeItem(at: staging)
            Task { await cookies.finish() }
        }

        // Archive bookkeeping key: the account, the hashtag, or the signed-in person's own items.
        let account = draft.hashtag.map { "#\($0.lowercased())" } ?? (draft.username.isEmpty ? "_self" : draft.username.lowercased())
        let isAccount = draft.hashtag == nil && !draft.username.isEmpty
        let stored = await app.store?.account(account)
        var request = BridgeRequest(op: scanOnly ? "scan" : "pull")
        let profileURL = URL(string: "https://www.instagram.com/\(account)/")!
        if let postURL = draft.postURL {
            request.url = postURL.absoluteString
        } else if let tag = draft.hashtag {
            request.url = "https://www.instagram.com/explore/tags/\(tag)/"
        } else {
            // The profile lists the account's media; details and the person's own items are pages of their own.
            var urls: [String] = []
            let media = InstagramContent.allCases.filter { draft.content.contains($0) && $0.isProfileMedia }
            if isAccount, !media.isEmpty {
                urls.append(profileURL.absoluteString)
                request.include = media.map(\.engineName)
            }
            if isAccount {
                for detail in [InstagramContent.profileInfo, .followers, .following] where draft.content.contains(detail) {
                    urls.append(profileURL.absoluteString + detail.engineName + "/")
                }
            }
            if draft.content.contains(.saved) { urls.append("https://www.instagram.com/\(isAccount ? account : "me")/saved/") }
            if draft.content.contains(.storiesTray) { urls.append("https://www.instagram.com/stories/me/") }
            request.urls = urls
            request.url = urls.first ?? profileURL.absoluteString
        }
        request.cookies = cookies.file.path
        request.userAgent = app.userAgent
        request.staging = staging.path
        request.setPacing(draft.pacing.delay)
        let selector = app.preferences.video.selector(av1Decodable: FFmpeg.canDecodeAV1)
        request.video = BridgeRequest.Video(format: selector.format, formatSort: selector.sort)
        let dates = draft.dateWindow.bounds(from: draft.dateFrom, to: draft.dateTo)
        if let from = dates.from { request.dateFrom = ISO8601DateFormatter().string(from: from) }
        if let to = dates.to { request.dateTo = ISO8601DateFormatter().string(from: to) }
        // An account is pulled into its own folder (D-78): an existing one, found by what it holds whatever it is called,
        // or a new one. What that folder already holds is what the engine skips (D-79); another folder of the same account
        // never counts, so a new folder gets a complete copy.
        // Only the continuation of an update that stopped part way starts from the folder's stored place; Resume of any job
        // continues that job's own pass (R-1112, D-80).
        let continuing = draft.continueFromCursor
        var place: AccountPlace?
        if isAccount, draft.postURL == nil, !scanOnly, let root {
            place = await resolvePlace(account: account, draft: draft, root: root)
            job.destination = place?.folder
        }
        // Hashtags go beside the accounts, never inside an account's folder (D-52).
        var hashtagBase = root?.url
        if draft.hashtag != nil, !scanOnly, let base = root?.url {
            let libraryRoot = app.root(containing: base)?.url
            let match = await Task.detached(priority: .userInitiated) { AccountFolders.detect(base, stopAt: libraryRoot) }.value
            if let match {
                hashtagBase = match.folder.deletingLastPathComponent()
                job.destination = hashtagBase?.appendingPathComponent(SaveTarget.tagsFolder, isDirectory: true)
            }
        }
        if draft.postURL == nil, !scanOnly, isAccount || draft.hashtag != nil {
            var known: Set<String> = []
            if let place {
                known = draft.findMissing ? place.index.identities : place.index.identities.union(place.record?.keys ?? [])
            } else if draft.hashtag != nil, draft.incremental || resuming {
                known = await app.store?.knownKeys(account: account) ?? []
            }
            let knownFile = staging.appendingPathComponent("known.json")
            do {
                try JSONEncoder().encode(Array(known)).write(to: knownFile)
                request.knownIDs = knownFile.path
            } catch {
                // Saved items are still recognised by their contents; the pull only cannot skip downloading them.
                job.notes.append("Saved posts could not be listed for the engine (\(error.localizedDescription)), "
                    + "so every post is checked.")
            }
            // Only an update of new posts ends early; finding missing items and continuing where a pull stopped walk on.
            let earlyStop = draft.incremental && !draft.findMissing && !continuing && !(resuming && place == nil)
            request.stopAfterKnown = earlyStop ? app.preferences.stopAfterKnown : nil
        }
        let storedCursor = place?.record?.cursor ?? (place == nil ? stored?.resumeCursor : nil)
        if draft.postURL == nil, !scanOnly {
            if resuming, let own = job.lastCursor {
                request.cursor = own
            } else if continuing || (resuming && place == nil) {
                request.cursor = storedCursor
            }
        }
        // Find Missing walks everything from the top, so its place replaces an older one (an interruption continues it).
        let keepsCursor = continuing || storedCursor == nil || draft.findMissing

        // The folder decides the layout, not the draft (D-70).
        var target: SaveTarget? = root.map { root in
            if let tag = draft.hashtag {
                return SaveTarget(folder: hashtagBase ?? root.url, layout: root.layout, autoSubfolders: true,
                                  collectionPath: [SaveTarget.tagsFolder, tag])
            }
            if let place {
                // The metadata names the account; the folder can be called anything (D-78).
                var target = SaveTarget(folder: place.folder.deletingLastPathComponent(), layout: root.layout, autoSubfolders: true,
                                        accountUsername: account)
                target.accountFolder = place.folder
                target.typeSubfolders = place.sortsByType
                return target
            }
            return SaveTarget(folder: root.url, layout: root.layout, autoSubfolders: true)
        }
        var savedKeys = Set<String>()
        var unrecordedKeys = Set<String>()
        // A new folder gets its record as soon as it exists, so an interruption keeps its place and what it saved (R-1904).
        func folderRecord() async -> AccountFolderRecord? {
            if let record = place?.record { return record }
            guard let folder = place?.folder, FileManager.default.fileExists(atPath: folder.path) else { return nil }
            let record = await app.accountFolders.record(account: account, folder: folder)
            place?.record = record
            return record
        }
        func remember(_ key: String) async {
            savedKeys.insert(key)
            unrecordedKeys.insert(key)
            guard unrecordedKeys.count >= 20, let record = await folderRecord() else { return }
            await app.accountFolders.addKeys(unrecordedKeys, to: record.id)
            unrecordedKeys = []
        }
        // A file reported twice (the same media in two listings) is saved once; the second report is that same file.
        var savedFromStaging: [String: URL] = [:]
        let settings = app.saveSettings
        let pipeline = app.pipeline()
        var index = 0
        var fatal: String?
        var blocked = false
        var finishedCleanly = false
        var newest: Date?
        let sourceURL = draft.postURL ?? profileURL

        do {
            for try await event in bridge.run(request, workingDirectory: staging) {
                if Task.isCancelled || job.state == .cancelled { break }
                switch event {
                case let .account(info):
                    if isAccount { await app.store?.updateAccount(account, userID: info.userID, fullName: info.fullName) }
                    accounts[account] = info
                case let .item(item):
                    job.found += 1
                    if job.state != .running { job.state = .running }
                    window?.ingestEngine([item.ingestInput(sourceURL: sourceURL)])
                case let .file(file):
                    guard var target else { continue }
                    guard file.isInside(staging) else {
                        job.failed += 1
                        job.failures.append((file.key, "The engine reported a file outside its working folder. It was left alone."))
                        continue
                    }
                    if let saved = savedFromStaging[file.path.path], !FileManager.default.fileExists(atPath: file.path.path) {
                        job.duplicates += 1
                        await remember(file.key)
                        window?.markSaved(file.key, url: saved)
                        continue
                    }
                    index += 1
                    let context = EngineContext.from(meta: file.meta, key: file.key, subcategory: file.subcategory, sourceURL: sourceURL)
                    // A single post or Reel goes into its account's folder when the save folder has (or is) one (D-78).
                    if draft.postURL != nil, target.accountFolder == nil, let root, let user = context.username?.lowercased() {
                        let found = await resolvePlace(account: user, draft: draft, root: root)
                        target.accountUsername = user
                        target.accountFolder = found.folder
                        target.typeSubfolders = found.sortsByType
                        if found.record != nil { job.destination = found.folder }
                    }
                    let isVideo = Self.videoExtensions.contains(file.path.pathExtension.lowercased())
                    let input = EngineItemInput(
                        context: context,
                        kind: isVideo ? .video : .image,
                        engineURL: context.postURL?.absoluteString ?? file.path.absoluteString,
                        thumbURL: nil,
                        width: file.meta["width"]?.int,
                        height: file.meta["height"]?.int,
                        isDash: false,
                        fallbackURL: nil
                    )
                    let item = input.makeItem(discoveryIndex: index)
                    job.currentItem = context.postShortcode ?? file.path.lastPathComponent
                    let (outcome, note) = await pipeline.saveStaged(file.path, item: item, target: target, settings: settings, index: index)
                    try? FileManager.default.removeItem(at: file.path)
                    switch outcome {
                    case let .saved(url):
                        job.saved += 1
                        savedFromStaging[file.path.path] = url
                        await remember(file.key)
                        window?.markSaved(file.key, url: url)
                        await app.store?.recordArchive(key: file.key, account: account, path: url.path, sha256: "")
                        if let date = context.date, newest.map({ date > $0 }) ?? true { newest = date }
                    case let .duplicate(url):
                        job.duplicates += 1
                        savedFromStaging[file.path.path] = url
                        await remember(file.key)
                        window?.markSaved(file.key, url: url)
                        await app.store?.recordArchive(key: file.key, account: account, path: url.path, sha256: "")
                    case let .skipped(reason):
                        job.skipped += 1
                        job.failures.append((file.key, reason))
                    case let .failed(reason):
                        job.failed += 1
                        job.failures.append((file.key, reason))
                    }
                    if let note, job.notes.count < 30 { job.notes.append(note) }
                case let .document(kind, path, count):
                    guard !scanOnly, let root, isAccount,
                          path.standardizedFileURL.path.hasPrefix(staging.standardizedFileURL.path + "/")
                    else {
                        continue
                    }
                    let folder = place?.folder ?? root.url.appendingPathComponent(FileNaming.safeTopFolder(account), isDirectory: true)
                    if let saved = fileAccountDocument(path, kind: kind, into: folder) {
                        let what = kind == "profile" ? "profile information" : "\(kind) list (\(count) accounts)"
                        if job.notes.count < 30 { job.notes.append("Saved the \(what) as \(saved.lastPathComponent)") }
                    }
                case .skip:
                    job.skipped += 1
                case let .wait(seconds, reason):
                    job.state = .waiting(until: Date().addingTimeInterval(seconds), reason: reason)
                case let .progress(received, total, _):
                    if let received, let total, total > 0 {
                        job.fraction = nil; job.currentItem = "\(Format.bytes(received)) of \(Format.bytes(total))"
                    }
                case let .cursor(subcategory, value):
                    // Where the posts listing has got to, so an interruption can continue from there (R-1112). A pass from
                    // the top while an earlier place is kept never replaces it: that place is continued afterwards.
                    guard subcategory == "posts", !scanOnly, isAccount else { break }
                    job.lastCursor = value
                    guard keepsCursor else { break }
                    if let record = await folderRecord() {
                        await app.accountFolders.update(record.id, cursor: .some(value))
                    } else {
                        await app.store?.updateAccount(account, resumeCursor: .some(value))
                    }
                case let .checkpoint(kind, url, message):
                    blocked = true
                    handleCheckpoint(kind: kind, url: url, message: message)
                    job.checkpointURL = url
                case let .error(code, message, _, isFatal):
                    if isFatal { fatal = describe(code: code, message: message) } else if job.notes.count < 30 { job.notes.append(message) }
                case let .policyViolation(method, host, _, reason):
                    fatal = "MediaPull blocked a \(method) request to \(host): \(reason)"
                case let .done(status, errors):
                    finishedCleanly = status == "completed"
                    if status == "failed", fatal == nil {
                        fatal = errors.last.map { describe(code: "", message: $0) } ?? "The download engine stopped."
                    }
                default:
                    break
                }
            }
        } catch {
            fatal = error.localizedDescription
        }

        await cookies.finish()
        await refreshSignIn()
        app.libraryRevision += 1
        // What this pull saved into the folder is remembered there, so an item deleted on purpose stays deleted on the
        // next Update (D-79). A new folder gets its record once it exists.
        if let record = await folderRecord() {
            await app.accountFolders.addKeys(unrecordedKeys, to: record.id)
            if finishedCleanly, keepsCursor {
                await app.accountFolders.update(record.id, cursor: .some(nil))
            }
            // Only a pull that reached the end counts as an update; any other leaves the date of the last one.
            let complete = finishedCleanly && fatal == nil && !blocked && job.state != .cancelled
            await app.accountFolders.update(record.id, lastUpdate: complete ? Date() : nil, lastResult: job.summary)
            await app.refreshAccountFolders()
        }
        if Task.isCancelled || job.state == .cancelled {
            app.jobs.finish(job, .cancelled)
            return
        }
        if blocked {
            job.state = .blocked(gateMessage ?? "Instagram needs your attention.")
            return
        }
        if let fatal, job.saved + job.duplicates + job.found == 0 {
            app.jobs.finish(job, .failed(fatal))
            await app.store?.updateAccount(account, lastResult: fatal)
            return
        }
        // Only a pull that reached the end may forget its place: an incremental pull stops at the
        // first run of known posts, so a gap left by a failed page would never be filled.
        if let fatal, !finishedCleanly || job.failed > 0 {
            if !scanOnly, draft.postURL == nil, isAccount {
                await app.store?.updateAccount(account, newestSavedDate: newest, lastResult: fatal)
            }
            app.jobs.finish(job, .failed("Stopped part way: \(fatal) Pull again to continue from where it stopped."))
            return
        }
        if let fatal { job.notes.append(fatal) }
        if !scanOnly, draft.postURL == nil, isAccount {
            if finishedCleanly {
                await app.store?.updateAccount(account, newestSavedDate: newest, resumeCursor: place == nil ? .some(nil) : nil,
                                               lastResult: job.summary, pulledNow: true)
            } else {
                await app.store?.updateAccount(account, newestSavedDate: newest, lastResult: job.summary)
            }
        }
        app.jobs.finish(job, .completed)
        // An earlier update of this folder stopped part way: new posts are in now, so the rest continues from where it
        // stopped (R-1904), as its own job.
        // The stored place is in the posts listing, so only posts continue. Find Missing already walked everything.
        if finishedCleanly, !continuing, !draft.findMissing, storedCursor != nil, draft.content.contains(.posts), let place {
            var next = draft
            next.accountFolder = place.folder
            next.continueFromCursor = true
            next.content = [.posts]
            startPull(next, scanOnly: false, window: window)
        }
    }

    /// Where an account pull goes and what is already there (D-78, D-79).
    struct AccountPlace {
        var folder: URL
        var index: AccountFolders.Index
        var record: AccountFolderRecord?
        var sortsByType: Bool?
    }

    private func resolvePlace(account: String, draft: PullDraft, root: SaveDestination) async -> AccountPlace {
        let libraryRoot = app.root(containing: root.url)?.url
        let chosen = draft.accountFolder
        let saveFolder = root.url
        let name = draft.folderName.nonEmpty ?? account
        // Reading the folder (names, and a sample of metadata files) happens off the main actor.
        let (folder, index, byType, existing) = await Task.detached(priority: .userInitiated) {
            () -> (URL, AccountFolders.Index, Bool?, Bool) in
            let resolved = chosen.map { (existing: Optional($0), parent: $0.deletingLastPathComponent()) }
                ?? AccountFolders.resolveTarget(account: account, saveFolder: saveFolder, root: libraryRoot)
            guard let existing = resolved.existing else {
                return (resolved.parent.appendingPathComponent(FileNaming.safeTopFolder(name), isDirectory: true),
                        AccountFolders.Index(), nil, false)
            }
            return (existing, AccountFolders.index(existing), AccountFolders.sortsByType(existing), true)
        }.value
        let record = existing ? await app.accountFolders.record(account: account, folder: folder) : nil
        return AccountPlace(folder: folder, index: index, record: record, sortsByType: byType)
    }

    /// Update an account's folder in one click (D-80): the account's remembered media choices and pace, no form. `findMissing`
    /// walks every post and adds what the folder lacks instead of stopping at what is already there.
    @discardableResult
    func startUpdate(account: String, folder: URL, findMissing: Bool, window: WindowModel?) async -> Job? {
        var draft = self.draft(username: account)
        await applyStoredOptions(to: &draft)
        // One click takes the account's media only: never its details, follower lists or the person's own saved posts.
        draft.content = draft.content.filter(\.isProfileMedia)
        if draft.content.isEmpty { draft.content = app.preferences.defaultContent.filter(\.isProfileMedia) }
        draft.accountFolder = folder
        draft.findMissing = findMissing
        draft.incremental = !findMissing
        draft.folderName = folder.lastPathComponent
        // An earlier update that stopped part way needs nothing more: this pass covers the top, and the rest continues from
        // where it stopped right after (runPull).
        return startPull(draft, scanOnly: false, window: window)
    }

    /// Moves a followers or following list, or the profile, into `<account>/Account details/` with the date in its name.
    private func fileAccountDocument(_ file: URL, kind: String, into accountFolder: URL) -> URL? {
        let directory = accountFolder.appendingPathComponent(SaveTarget.accountDetailsFolder, isDirectory: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        let name = FileNaming.fileName(stem: "\(formatter.string(from: Date()))_\(kind)", ext: file.pathExtension)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = LibraryModel.uniqueURL(directory.appendingPathComponent(name))
            try FileManager.default.moveItem(at: file, to: target) // lint:allow main-io a small list or profile file
            return target
        } catch {
            return nil
        }
    }

    // MARK: Videos (SPEC section 35)

    /// Lists the formats of the video on a page, without downloading it.
    func videoInfo(for url: URL) async -> Result<VideoInfo, VideoLookupError> {
        guard let bridge else { return .failure(VideoLookupError(message: "The download engine is not available.")) }
        var request = BridgeRequest(op: "video_info")
        request.url = url.absoluteString
        request.userAgent = app.userAgent
        // Members-only and age-checked videos list their formats only with the browser's sign-in for that site.
        let cookies = EngineCookies.optional(await app.cookies(forDomain: PublicSuffix.shared.registrableDomain(url.host ?? "")))
        defer { if let cookies { Task { await cookies.finish() } } }
        request.cookies = cookies?.file.path
        var message = "No downloadable video was found on this page."
        do {
            for try await event in bridge.run(request) {
                switch event {
                case let .videoInfo(info): return .success(info)
                case let .error(_, text, _, _): message = text
                case let .policyViolation(method, host, _, reason): message = "MediaPull blocked a \(method) request to \(host): \(reason)"
                default: break
                }
            }
        } catch {
            message = error.localizedDescription
        }
        return .failure(VideoLookupError(message: message))
    }

    /// Downloads a video (or a playlist or channel, with `extras.playlist`) in the chosen format and resolution
    /// into `<root>/<site>/<uploader>/`, with any subtitles, thumbnail and description beside each video (R-3503, R-3505).
    @discardableResult
    func saveVideo(_ info: VideoInfo, pageURL: URL? = nil, format: VideoDownloadFormat, height: Int?,
                   extras: BridgeRequest.Extras = .init(), root: SaveDestination, window _: WindowModel?) -> Job
    {
        let job = Job(kind: .stream, title: extras.playlist ? "Playlist: \(info.title)" : info.title)
        job.subtitle = format.label + (format.isAudioOnly ? "" : ", " + (height.map { "\($0)p" } ?? "best resolution"))
        let site = info.webpageURL.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? info.extractor
        let channel = info.uploader?.nonEmpty ?? "Videos"
        job.destination = root.url.appendingPathComponent(FileNaming.safeTopFolder(site), isDirectory: true)
            .appendingPathComponent(FileNaming.sanitize(channel, maxBytes: 80), isDirectory: true)
        app.jobs.add(job)
        let url = pageURL ?? info.webpageURL
        let run = { [weak self, weak job] in
            guard let self, let job else { return }
            job.task = Task { [weak self, weak job] in
                guard let self, let job else { return }
                await self.runVideo(job: job, url: url, info: info, format: format, height: height, extras: extras, root: root, site: site)
            }
        }
        run()
        job.retry = { [weak job] in
            job?.failed = 0
            job?.failures = []
            job?.finishedAt = nil
            run()
        }
        return job
    }

    private func runVideo(job: Job, url: URL, info: VideoInfo, format: VideoDownloadFormat, height: Int?, extras: BridgeRequest.Extras,
                          root: SaveDestination, site: String) async
    {
        guard let bridge, let stagingRoot = app.enginePaths?.staging else {
            app.jobs.finish(job, .failed("The download engine is not available."))
            return
        }
        job.state = .running
        let staging = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var request = BridgeRequest(op: "stream")
        request.url = url.absoluteString
        request.staging = staging.path
        request.userAgent = app.userAgent
        request.key = "video:\(info.extractor)"
        let selector = format.selector(height: height)
        request.video = BridgeRequest.Video(format: selector.format, formatSort: selector.sort, merge: selector.merge)
        request.extras = extras
        // Members-only and age-checked videos use the browser's sign-in for that site.
        let cookies = EngineCookies.optional(await app.cookies(forDomain: PublicSuffix.shared.registrableDomain(url.host ?? "")))
        defer { if let cookies { Task { await cookies.finish() } } }
        request.cookies = cookies?.file.path

        var saved: [String: URL] = [:]
        var waiting: [String: [(URL, String)]] = [:]
        var failure: String?
        var index = 0
        do {
            for try await event in bridge.run(request, workingDirectory: staging) {
                if Task.isCancelled { break }
                switch event {
                case let .progress(received, total, _):
                    if let received, let total, total > 0 {
                        job.fraction = extras.playlist ? nil : Double(received) / Double(total)
                        job.currentItem = "\(Format.bytes(received)) of \(Format.bytes(total))"
                    }
                case let .file(found) where found.isInside(staging):
                    index += 1
                    job.found += 1
                    if let url = await saveVideoFile(found, index: index, info: info, format: format, height: height, root: root,
                                                     site: site, job: job)
                    {
                        saved[found.key] = url
                        for (path, kind) in waiting.removeValue(forKey: found.key) ?? [] {
                            if let problem = await placeAttachment(path, kind: kind, beside: url) { job.notes.append(problem) }
                        }
                    }
                case .file:
                    // A path outside the staging folder comes from site metadata and is never trusted, as for pulls.
                    failure = "The engine reported a file outside its working folder. It was left alone."
                case let .attachment(key, path, kind) where path.standardizedFileURL.path.hasPrefix(staging.standardizedFileURL.path + "/"):
                    if let beside = saved[key] {
                        if let problem = await placeAttachment(path, kind: kind, beside: beside) { job.notes.append(problem) }
                    } else {
                        waiting[key, default: []].append((path, kind))
                    }
                case let .error(_, message, _, fatal):
                    if fatal || failure == nil { failure = message }
                case let .policyViolation(method, host, _, reason):
                    failure = "MediaPull blocked a \(method) request to \(host): \(reason)"
                default:
                    break
                }
            }
        } catch {
            failure = error.localizedDescription
        }
        app.libraryRevision += 1
        if Task.isCancelled || job.state == .cancelled {
            app.jobs.finish(job, .cancelled)
            return
        }
        if job.saved + job.duplicates == 0 {
            app.jobs.finish(job, .failed(failure ?? "The video could not be downloaded."))
        } else {
            if let failure, job.failed > 0 || extras.playlist { job.notes.append(failure) }
            app.jobs.finish(job, .completed)
        }
    }

    /// Saves one downloaded video through the save pipeline, named after its title, in `<site>/<uploader>/`.
    private func saveVideoFile(_ file: BridgeFile, index: Int, info: VideoInfo, format: VideoDownloadFormat, height: Int?,
                               root: SaveDestination, site: String, job: Job) async -> URL?
    {
        let meta = file.meta
        let title = meta["title"]?.string ?? info.title
        let uploader = meta["uploader"]?.string ?? info.uploader
        let page = meta["webpage_url"]?.string.flatMap(URL.init(string:)) ?? info.webpageURL
        job.fraction = nil
        job.currentItem = format.needsConversion(in: info.formats, height: height) ? "Converting \(title) to HEVC" : "Saving \(title)"
        var context = EngineContext(key: file.key, category: info.extractor.nonEmpty ?? site,
                                    subcategory: format.isAudioOnly ? "audio" : "video")
        context.username = uploader
        context.postID = meta["id"]?.string ?? info.id
        context.shortcode = context.postID
        context.date = VideoInfo.date(uploadDate: meta["upload_date"]?.string, timestamp: meta["timestamp"]?.double) ?? info.uploadDate
        context.title = title
        context.description = title
        context.postURL = page
        context.sourceURL = page
        let input = EngineItemInput(context: context, kind: format.isAudioOnly ? .audio : .video, engineURL: page.absoluteString,
                                    thumbURL: info.thumbnail, width: meta["width"]?.int, height: meta["height"]?.int,
                                    isDash: false, fallbackURL: nil)
        let item = input.makeItem(discoveryIndex: index)
        let channel = FileNaming.sanitize(uploader?.nonEmpty ?? "Videos", maxBytes: 80)
        let target = SaveTarget(folder: root.url, layout: root.layout, autoSubfolders: true, collectionPath: [site, channel])
        var settings = app.saveSettings
        settings.conversion.keepDownloadedMedia = format.keepsDownloadedFile
        let (outcome, note) = await app.pipeline().saveStaged(file.path, item: item, target: target, settings: settings, index: index,
                                                              nameOverride: title)
        if let note, job.notes.count < 30 { job.notes.append(note) }
        switch outcome {
        case let .saved(url):
            job.saved += 1
            job.destination = url
            return url
        case let .duplicate(url):
            job.duplicates += 1
            return url
        case let .skipped(reason):
            job.skipped += 1
            job.failures.append((file.key, reason))
        case let .failed(reason):
            job.failed += 1
            job.failures.append((file.key, reason))
        }
        return nil
    }

    /// Puts a subtitle, thumbnail or description file beside the saved video, named after it.
    /// Returns what went wrong, so the job can say which file beside the video is missing.
    private func placeAttachment(_ path: URL, kind: String, beside video: URL) async -> String? {
        let stem = video.deletingPathExtension()
        let ext = path.pathExtension.lowercased()
        let name = if kind.hasPrefix("subtitles.") {
            "\(stem.lastPathComponent).\(kind.dropFirst("subtitles.".count)).\(ext)"
        } else if kind == "description" {
            "\(stem.lastPathComponent).description.txt"
        } else {
            "\(stem.lastPathComponent).\(ext)"
        }
        let destination = video.deletingLastPathComponent().appendingPathComponent(name)
        // A WebP thumbnail is saved as JPEG, in keeping with the normal formats (R-1502).
        if kind == "thumbnail", !["jpg", "jpeg", "png"].contains(ext),
           await Self.convertToJPEG(path, output: LibraryModel.uniqueURL(destination.deletingPathExtension().appendingPathExtension("jpg")))
        {
            return nil
        }
        do {
            try FileManager.default.moveItem(at: path, to: LibraryModel.uniqueURL(destination)) // lint:allow main-io a small side file
            return nil
        } catch {
            return "\(name) could not be saved beside the video: \(error.localizedDescription)"
        }
    }

    /// Decoding and encoding stay off the main actor.
    @concurrent
    private nonisolated static func convertToJPEG(_ path: URL, output: URL) async -> Bool {
        guard let analysis = ImageConversion.analyze(path) else { return false }
        return (try? ImageConversion.convertStill(path, to: ImageConversion.stillTarget(for: analysis), output: output)) != nil
    }

    // MARK: Site extractor

    func supportedCategory(for url: URL) async -> String? {
        await siteInfo(for: url)?.category
    }

    /// The site gallery-dl recognises at an address and what it offers there; read locally, without a network request.
    func siteInfo(for url: URL) async -> SiteInfo? {
        guard let bridge else { return nil }
        var request = BridgeRequest(op: "supports")
        request.url = url.absoluteString
        guard let events = try? await bridge.collect(request) else { return nil }
        for event in events {
            if case let .supports(site) = event { return site }
        }
        return nil
    }

    @discardableResult
    func startSiteScan(url: URL, category: String, window: WindowModel) -> Job? {
        guard let bridge else { return nil }
        let job = Job(kind: .scan, title: "Scanning \(url.host ?? category)")
        job.subtitle = "Site extractor: \(category)"
        app.jobs.add(job)
        window.engineScan = job
        job.task = Task { [weak self, weak window] in
            guard let self else { return }
            job.state = .running
            let work = UUID().uuidString
            let staging = self.app.enginePaths?.staging.appendingPathComponent(work, isDirectory: true)
            let domain = PublicSuffix.shared.registrableDomain(url.host ?? "")
            let cookies = EngineCookies.optional(await self.app.cookies(forDomain: domain))
            defer {
                if let staging { try? FileManager.default.removeItem(at: staging) }
                if let cookies { Task { await cookies.finish() } }
            }
            var request = BridgeRequest(op: "scan")
            request.url = url.absoluteString
            request.cookies = cookies?.file.path
            request.userAgent = self.app.userAgent
            request.category = category
            if let keys = SiteKeys.forSite(category) {
                let saved = SiteKeychain.keys(for: category, fields: keys.fields)
                if !saved.isEmpty { request.siteKeys = saved }
            }
            request.staging = staging?.path
            request.setPacing([1, 2])
            let siteName = self.app.sites.name(SiteInfoKey(category: category))
            let ownKey = SiteKeys.forSite(category) != nil
            var fatal: String?
            var blocked = false
            var batch: [EngineItemInput] = []
            do {
                for try await event in bridge.run(request, workingDirectory: staging) {
                    if Task.isCancelled { break }
                    // Any event but a wait means the engine is working again, not pausing between requests.
                    if case .wait = event {} else if case .waiting = job.state { job.state = .running }
                    switch event {
                    case let .item(item):
                        job.found += 1
                        batch.append(item.ingestInput(sourceURL: url))
                        if batch.count >= 25 {
                            window?.ingestEngine(batch)
                            batch.removeAll()
                        }
                    case let .wait(seconds, reason):
                        job.state = .waiting(until: Date().addingTimeInterval(seconds), reason: reason)
                    case let .error(code, message, _, isFatal):
                        guard isFatal else { continue }
                        fatal = GalleryError.describe(self.describe(code: code, message: message), site: siteName, ownKey: ownKey)
                    case let .checkpoint(_, _, message):
                        blocked = true
                        fatal = GalleryError.describe(message, site: siteName, ownKey: ownKey)
                    case let .policyViolation(method, host, _, reason):
                        blocked = true
                        fatal = "MediaPull blocked a \(method) request to \(host): \(reason)"
                    case let .done(status, errors):
                        // A site that stops the scan part way is a failure, even with some items listed.
                        if status == "blocked" { blocked = true }
                        if status == "failed" || blocked, fatal == nil, job.found == 0 || blocked {
                            fatal = errors.last.map { GalleryError.describe($0, site: siteName, ownKey: ownKey) }
                                ?? (blocked ? "\(siteName) stopped the scan." : "The site extractor found nothing.")
                        }
                    default:
                        if job.state != .running { job.state = .running }
                    }
                }
            } catch {
                fatal = error.localizedDescription
            }
            if !batch.isEmpty { window?.ingestEngine(batch) }
            if Task.isCancelled {
                self.app.jobs.finish(job, .cancelled)
            } else if let fatal, job.found == 0 || blocked {
                self.app.jobs.finish(job, .failed(fatal))
            } else {
                self.app.jobs.finish(job, .completed)
            }
        }
        return job
    }

    // MARK: Any gallery-dl site (SPEC section 12)

    /// Downloads everything gallery-dl finds at `url` into `<root>/<site>/<user or gallery>/`, through the save pipeline.
    /// `range` limits which items ("1-50"); `onlyNew` skips what an earlier download of the same address saved.
    @discardableResult
    func startGalleryDownload(url: URL, site: SiteInfo, include: [String], switches: [String: Bool], range: String?, from: Date?, to: Date?,
                              onlyNew: Bool, root: SaveDestination, window: WindowModel?) -> Job?
    {
        let category = site.category
        let siteName = app.sites.name(SiteInfoKey(category: site.category, baseCategory: site.baseCategory))
        let ownKey = SiteKeys.forSite(site.category, baseCategory: site.baseCategory) != nil
        guard let bridge else { return nil }
        let job = Job(kind: .pull, title: "Downloading from \(siteName)")
        job.subtitle = [category, range.map { "items \($0)" }].compactMap { $0 }.joined(separator: ", ")
        job.destination = root.url.appendingPathComponent(FileNaming.safeTopFolder(category), isDirectory: true)
        app.jobs.add(job)
        let account = "gallery:\(category):\(url.absoluteString.lowercased())"
        job.task = Task { [weak self, weak window] in
            guard let self else { return }
            job.state = .running
            let work = UUID().uuidString
            guard let staging = self.app.enginePaths?.staging.appendingPathComponent(work, isDirectory: true) else {
                self.app.jobs.finish(job, .failed("The download engine is not available."))
                return
            }
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let domain = PublicSuffix.shared.registrableDomain(url.host ?? "")
            let cookies = EngineCookies.optional(await self.app.cookies(forDomain: domain))
            defer {
                try? FileManager.default.removeItem(at: staging)
                if let cookies { Task { await cookies.finish() } }
            }
            var request = BridgeRequest(op: "pull")
            request.url = url.absoluteString
            request.cookies = cookies?.file.path
            request.staging = staging.path
            request.range = range?.nonEmpty
            request.category = category
            if !include.isEmpty { request.include = include }
            if !switches.isEmpty { request.siteOptions = switches }
            if let keys = SiteKeys.forSite(site.category, baseCategory: site.baseCategory) {
                let saved = SiteKeychain.keys(for: site.category, fields: keys.fields)
                if !saved.isEmpty { request.siteKeys = saved }
            }
            request.userAgent = self.app.userAgent
            request.setPacing([1, 3])
            let selector = self.app.preferences.video.selector(av1Decodable: FFmpeg.canDecodeAV1)
            request.video = BridgeRequest.Video(format: selector.format, formatSort: selector.sort)
            if let from { request.dateFrom = ISO8601DateFormatter().string(from: from) }
            if let to { request.dateTo = ISO8601DateFormatter().string(from: to) }
            if onlyNew {
                let known = await self.app.store?.knownKeys(account: account) ?? []
                let knownFile = staging.appendingPathComponent("known.json")
                do {
                    try JSONEncoder().encode(Array(known)).write(to: knownFile)
                    request.knownIDs = knownFile.path
                } catch {
                    job.notes.append("Saved items could not be listed for the engine (\(error.localizedDescription)), "
                        + "so every item is checked.")
                }
            }
            let settings = self.app.saveSettings
            let pipeline = self.app.pipeline()
            var index = 0
            var fatal: String?
            var blocked: String?
            do {
                for try await event in bridge.run(request, workingDirectory: staging) {
                    if Task.isCancelled { break }
                    // Any event but a wait means the engine is working again, not pausing between requests.
                    if case .wait = event {} else if case .waiting = job.state { job.state = .running }
                    switch event {
                    case .item:
                        job.found += 1
                    case let .file(file) where file.isInside(staging):
                        index += 1
                        let ext = file.path.pathExtension.lowercased()
                        if MediaFormat.fromExtension(ext) == nil, !Self.videoExtensions.contains(ext) {
                            // Archives, documents and other attachments: MediaPull keeps images and videos only.
                            job.skipped += 1
                            if job.notes.count < 30 { job.notes.append("Skipped \(file.path.lastPathComponent): not an image or video") }
                            try? FileManager.default.removeItem(at: file.path)
                            continue
                        }
                        let context = EngineContext.from(meta: file.meta, key: file.key, subcategory: file.subcategory, sourceURL: url)
                        let isVideo = Self.videoExtensions.contains(file.path.pathExtension.lowercased())
                        let input = EngineItemInput(
                            context: context,
                            kind: isVideo ? .video : .image,
                            engineURL: context.postURL?.absoluteString ?? file.path.absoluteString,
                            thumbURL: nil,
                            width: file.meta["width"]?.int,
                            height: file.meta["height"]?.int,
                            isDash: false,
                            fallbackURL: nil
                        )
                        let subject = context.username?.nonEmpty ?? context.title?.nonEmpty ?? url.lastPathComponent.nonEmpty ?? "Gallery"
                        var path = [context.category.nonEmpty ?? category, FileNaming.sanitize(subject, maxBytes: 80)]
                        // Several parts of a profile at once: each in its own folder, like Instagram's posts and reels (D-54).
                        if include.count > 1, self.app.preferences.typeSubfolders, let part = file.subcategory, include.contains(part) {
                            path.append(SiteCatalogue.choiceLabel(part))
                        }
                        let target = SaveTarget(folder: root.url, layout: root.layout, autoSubfolders: true, collectionPath: path)
                        job.currentItem = file.path.lastPathComponent
                        let (outcome, note) = await pipeline.saveStaged(file.path, item: input.makeItem(discoveryIndex: index),
                                                                        target: target, settings: settings, index: index)
                        try? FileManager.default.removeItem(at: file.path)
                        switch outcome {
                        case let .saved(saved):
                            job.saved += 1
                            await self.app.store?.recordArchive(key: file.key, account: account, path: saved.path, sha256: "")
                        case let .duplicate(saved):
                            job.duplicates += 1
                            await self.app.store?.recordArchive(key: file.key, account: account, path: saved.path, sha256: "")
                        case let .skipped(reason):
                            job.skipped += 1
                            job.failures.append((file.key, reason))
                        case let .failed(reason):
                            job.failed += 1
                            job.failures.append((file.key, reason))
                        }
                        if let note, job.notes.count < 30 { job.notes.append(note) }
                    case let .file(file):
                        job.failed += 1
                        job.failures.append((file.key, "The engine reported a file outside its working folder. It was left alone."))
                    case .skip:
                        job.skipped += 1
                    case let .wait(seconds, reason):
                        job.state = .waiting(until: Date().addingTimeInterval(seconds), reason: reason)
                    case let .progress(received, total, _):
                        if let received, let total, total > 0 { job.currentItem = "\(Format.bytes(received)) of \(Format.bytes(total))" }
                    case let .error(code, message, _, isFatal):
                        if isFatal {
                            fatal = GalleryError.describe(self.describe(code: code, message: message), site: siteName, ownKey: ownKey)
                        } else if job.notes.count < 30 { job.notes.append(message) }
                    case let .checkpoint(_, _, message):
                        // A site's limit stops the job: say so instead of finishing with nothing saved.
                        fatal = GalleryError.describe(message, site: siteName, ownKey: ownKey)
                    case let .policyViolation(method, host, _, reason):
                        blocked = "MediaPull blocked a \(method) request to \(host): \(reason)"
                    case let .done(status, errors):
                        // gallery-dl can finish "completed" with an error and nothing found, such as a sign-in it needed.
                        if fatal == nil, status == "failed" || status == "blocked" || job.found == 0, let last = errors.last {
                            fatal = GalleryError.describe(last, site: siteName, ownKey: ownKey)
                        } else if status == "failed" || status == "blocked", fatal == nil {
                            fatal = "The download stopped."
                        }
                    default:
                        if job.state != .running { job.state = .running }
                    }
                }
            } catch {
                fatal = error.localizedDescription
            }
            // A blocked request explains a failure better than the error the site then returns.
            if let blocked { fatal = blocked }
            self.app.libraryRevision += 1
            if Task.isCancelled {
                self.app.jobs.finish(job, .cancelled)
            } else if let fatal, job.saved + job.duplicates == 0 {
                self.app.jobs.finish(job, .failed(fatal))
            } else {
                if let fatal { job.notes.append(fatal) }
                self.app.jobs.finish(job, .completed)
            }
            _ = window
        }
        return job
    }
}
