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
import os

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
    /// That folder's record, when it has one: a queued pull finds the folder by it wherever it went since (renamed or moved
    /// in MediaPull or the Finder), never by the path it had when queued (audit 5, C5-M4).
    var accountFolderID: UUID?
    /// Walk every post and add what the folder lacks, including items deleted from it (D-79); otherwise only new items.
    var findMissing = false
    /// Continue a walk that stopped part way, from that place (R-1904, D-87).
    var continueFrom: ResumePlace?
    /// The content was chosen by the address (a story link pulls stories), so the account's remembered choices do not
    /// replace it.
    var contentFromAddress = false
    /// A saved-posts link (all saved posts or one collection) pulled as it is (audit 4, C4-M3).
    var collectionURL: URL?
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
            // A self-test never writes the person's settings (audit 8, B8-m7).
            if !SelfTestRunner.isActive { UserDefaults.standard.set(recent, forKey: Self.rateLimitKey) }
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
                    // A look-up only shows who has the name now; it never stands in for the id a folder was made with
                    // (audit 5, A5-M1), so only the name is kept.
                    await app.store?.updateAccount(username, fullName: account.fullName)
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

    /// `saveFolder` overrides the window's (Download All keeps the folder chosen when it was clicked).
    @discardableResult
    func startPull(_ draft: PullDraft, scanOnly: Bool, window: WindowModel?, saveFolder: URL? = nil) -> Job? {
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
            (saveFolder ?? window?.saveFolder ?? app.defaultRoot?.url).map(app.destination(for:))
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
        // Resume continues whichever walk the job ran last: after Retry Failed, that is the full walk, not the original
        // update (audit 5, C5-M2).
        let running = PullRun(draft: draft)
        // The save folder is followed if it is renamed or moved before the job (or its Retry or Resume) runs (audit 6, C6-M3).
        running.root = root.map { FollowedFolder($0.url) }
        job.resume = { [weak self, weak job, weak window] in
            guard let self, let job else { return }
            job.state = .queued
            job.failed = 0
            job.failures = []
            job.finishedAt = nil
            let draft = running.draft
            self.enqueueInstagram(job: job) { [weak self, weak job, weak window] in
                guard let job else { return }
                await self?.runPull(job: job, draft: draft, root: root, scanOnly: scanOnly, window: window, bridge: bridge, resuming: true,
                                    run: running)
            }
        }
        // Retry Failed walks the whole listing again with no early stop, skipping what the folder has, so a file that failed
        // on any page is fetched again however deep it was (audit 4, A4-M4). As a full walk it covers every place left in
        // the folder, so those become its own (D-87).
        job.retry = { [weak self, weak job, weak window] in
            guard let self, let job else { return }
            job.state = .queued
            job.failed = 0
            job.failures = []
            job.finishedAt = nil
            job.lastCursor = nil
            job.placeID = UUID()
            var walk = running.draft
            walk.continueFrom = nil
            if walk.postURL == nil, walk.hashtag == nil { walk.incremental = false }
            running.draft = walk
            self.enqueueInstagram(job: job) { [weak self, weak job, weak window] in
                guard let job else { return }
                await self?.runPull(job: job, draft: walk, root: root, scanOnly: scanOnly, window: window, bridge: bridge, resuming: false,
                                    run: running)
            }
        }
        enqueueInstagram(job: job) { [weak self, weak job, weak window] in
            guard let job else { return }
            await self?.runPull(job: job, draft: draft, root: root, scanOnly: scanOnly, window: window, bridge: bridge, resuming: false,
                                run: running)
        }
        // A one-click update uses the remembered choices without changing them (D-80).
        // A story link or a single post chose its content from the address: that is not the account's choice either.
        if !scanOnly, draft.hashtag == nil, !draft.username.isEmpty, draft.accountFolder == nil, !draft.contentFromAddress,
           draft.postURL == nil
        {
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

    /// A turn with Instagram for a request outside a pull (a save re-fetching an expired link): it waits behind running
    /// pulls and is refused while Instagram holds a checkpoint or cooldown (R-1113, R-1114). The returned call ends it.
    func instagramTurn() async -> (@Sendable () -> Void)? {
        guard canRunInstagram else { return nil }
        let holder = Job(kind: .pull, title: "Refreshing an Instagram link")
        let end: (@Sendable () -> Void)? = await withCheckedContinuation { started in
            enqueueInstagram(job: holder) {
                await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
                    let once = OneShot(finished)
                    started.resume(returning: { once.fire() })
                }
            }
        }
        // The gate may have closed while it waited.
        guard canRunInstagram else {
            end?()
            return nil
        }
        return end
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
                         resuming: Bool, run: PullRun) async
    {
        if case .cancelled = job.state { return }
        // Nothing is ever saved into a save folder that went away, nor made again at its old path: one renamed or moved
        // since the job was queued is followed (audit 6, C6-M3).
        var root = root
        if !scanOnly, let chosen = root {
            // The save folder is followed; only when it is gone does an account folder known by its record decide where
            // the job saves (audit 7, A7-m1), so a form pull keeps saving around the folder it was given (audit 8, C8-m5).
            var followed = await run.root?.now()
            if followed == nil, let id = draft.accountFolderID, let folder = await app.accountFolders.currentFolder(of: id) {
                followed = folder.deletingLastPathComponent()
            }
            guard let followed else {
                app.jobs.finish(job, .failed(FollowedFolder.goneMessage(chosen.url)))
                return
            }
            if followed.standardizedFileURL.path != chosen.url.standardizedFileURL.path {
                // The folder's library decides the layout where it is now (D-70, audit 8, A8-m6).
                root = SaveDestination(url: followed, layout: app.root(containing: followed)?.layout ?? chosen.layout)
                // Activity shows where the job saves now (audit 7, A7-m6).
                job.destination = job.destination.map { LibraryModel.followed($0, from: chosen.url.path, to: followed.path) }
            }
        }
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
            if draft.content.contains(.saved) {
                urls.append(draft.collectionURL?.absoluteString ?? "https://www.instagram.com/\(isAccount ? account : "me")/saved/")
            }
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
        // Places (D-87): only a continuation starts from one; Resume of any job continues that job's own walk.
        let continuing = draft.continueFrom != nil
        var place: AccountPlace?
        if isAccount, draft.postURL == nil, !scanOnly, let root {
            guard let found = await resolvePlace(account: account, draft: draft, root: root) else {
                app.jobs.finish(job, .failed("The folder of @\(account) is no longer there. It may have been moved to the Trash."))
                await app.refreshAccountFolders()
                return
            }
            place = found
            job.destination = found.folder
            // Retry and Resume find this folder by its record, wherever it goes (audit 6, C6-M2).
            if let record = found.record { run.remember(record.id, folder: found.folder) }
        }
        // Hashtags, saved posts and the stories tray go beside the accounts, never inside an account's folder (D-52, audit 4,
        // C4-m10).
        var hashtagBase = root?.url
        let collectionPull = draft.hashtag != nil || (!isAccount && draft.postURL == nil)
        if collectionPull, !scanOnly, let base = root?.url {
            let libraryRoot = app.root(containing: base)?.url
            // Inside Hashtags or Saved posts themselves: beside that folder, never Saved posts/Saved posts (audit 5, C5-m4).
            let (detected, collection) = await Task.detached(priority: .userInitiated) {
                (AccountFolders.detect(base, stopAt: libraryRoot), AccountFolders.collectionFolder(containing: base, root: libraryRoot))
            }.value
            if let around = collection ?? detected?.folder ?? app.accountFolder(containing: base).map({ URL(fileURLWithPath: $0.path) }) {
                // Beside the account's folder, but never outside the library: a library folder that is an account's keeps
                // them inside it (D-52, audit 6, A6-m3).
                let isLibrary = libraryRoot.map { AccountFolderStore.key($0.path) == AccountFolderStore.key(around.path) } ?? false
                hashtagBase = isLibrary && collection == nil ? around : around.deletingLastPathComponent()
                if draft.hashtag != nil {
                    job.destination = hashtagBase?.appendingPathComponent(SaveTarget.tagsFolder, isDirectory: true)
                } else {
                    job.destination = hashtagBase
                }
            }
        }
        if draft.postURL == nil, !scanOnly, isAccount || draft.hashtag != nil {
            var known: Set<String> = []
            if let place {
                let findMissing = draft.findMissing || draft.continueFrom?.findMissing == true
                known = findMissing ? place.index.identities : place.index.identities.union(place.record?.keys ?? [])
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
            // An update ends early at the folder's known posts, and so does the continuation of an update's place; Find
            // Missing, full walks and places that run to the oldest post walk on.
            let earlyStop = draft.incremental && !draft.findMissing && !(draft.continueFrom?.untilEnd ?? false)
                && !(resuming && place == nil)
            request.stopAfterKnown = earlyStop ? app.preferences.stopAfterKnown : nil
        }
        // A continuation whose place is gone (continued or replaced meanwhile) has nothing left to do.
        // It starts where the place is now, which another walk may have moved on since this one was queued (audit 4, A4-m2).
        var current: ResumePlace?
        if let from = draft.continueFrom {
            guard let record = place?.record, let now = await app.accountFolders.place(from.id, in: record.id) else {
                job.notes.append("Nothing was left to continue.")
                app.jobs.finish(job, .completed)
                return
            }
            current = now
        }
        if draft.postURL == nil, !scanOnly {
            if resuming, let own = job.lastCursor {
                request.cursor = own
            } else if let from = current ?? draft.continueFrom {
                request.cursor = from.cursor
            } else if resuming, place == nil {
                request.cursor = stored?.resumeCursor
            }
        }
        // Places are kept for walks of the account's own posts listing with no date window (D-87).
        let walksPosts = isAccount && draft.postURL == nil && !scanOnly && place != nil && draft.content.contains(.posts)
            && draft.dateWindow == .allTime
        let fullWalk = !continuing && (!draft.incremental || draft.findMissing)
        var postsComplete = false

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
                target.accountFolderExisted = place.record != nil
                target.typeSubfolders = place.sortsByType
                return target
            }
            return SaveTarget(folder: collectionPull ? hashtagBase ?? root.url : root.url, layout: root.layout, autoSubfolders: true)
        }
        var unrecordedKeys = Set<String>()
        // A new folder gets its record as soon as it exists, so an interruption keeps its place and what it saved (R-1904).
        var accountUserID: String?
        func folderRecord() async -> AccountFolderRecord? {
            if let record = place?.record { return record }
            guard let folder = place?.folder, FileManager.default.fileExists(atPath: folder.path) else { return nil }
            var record = await app.accountFolders.record(account: account, folder: folder)
            if let accountUserID, record.userID == nil {
                await app.accountFolders.update(record.id, userID: accountUserID)
                record.userID = accountUserID
            }
            place?.record = record
            run.remember(record.id, folder: folder)
            return record
        }
        // Single posts, Reels, stories and highlights go into their account's folder (D-78): found once per account, and
        // remembered in that folder's record like a pull's (D-79).
        var postPlaces: [String: AccountPlace] = [:]
        // Accounts the engine looked up in this pull (tray owners included), by name.
        var seenIDs: [String: String] = [:]
        // Accounts whose folder this pull is making (none existed when their first item came).
        var madePostFolders = Set<String>()
        // Where a place's folder is now: followed when renamed or moved, nil when it went to the Trash or was deleted. A new
        // folder nobody has made yet is where it was planned (audit 5, A5-M3).
        func whereNow(_ found: AccountPlace) async -> URL? {
            if FileManager.default.fileExists(atPath: found.folder.path), !FileFlags.isInTrash(found.folder) { return found.folder }
            guard let record = found.record else { return found.folder }
            return await app.accountFolders.currentFolder(of: record.id)
        }
        func rememberPost(_ key: String, account user: String, owner: String?) async {
            guard let folder = postPlaces[user]?.folder, FileManager.default.fileExists(atPath: folder.path) else { return }
            var record = await app.accountFolders.record(account: user, folder: folder)
            // Only a folder this pull made learns its account's id from a post: an older folder learns it at its own
            // update, so a post of whoever has the name now never gives it that id (audit 7, A7-M2; D-92).
            if let owner, record.userID == nil, madePostFolders.contains(user) {
                await app.accountFolders.update(record.id, userID: owner)
                record.userID = owner
            }
            await app.accountFolders.addKeys([key], to: record.id)
            // The folder is followed from now on, even one this pull made (audit 6, A6-m2).
            postPlaces[user]?.record = record
        }
        func remember(_ key: String, subcategory: String) async {
            // Others' stories and saved posts belong to other folders, not to this account's record.
            guard !["stories-tray", "saved", "collection"].contains(subcategory) else { return }
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
        // The pull was stopped on purpose (its folder gone, the name now someone else's): no "pull again" advice.
        var refused = false
        var blocked = false
        var finishedCleanly = false
        var newest: Date?
        let sourceURL = draft.postURL ?? profileURL

        do {
            events: for try await event in bridge.run(request, workingDirectory: staging) {
                if Task.isCancelled || job.state == .cancelled { break }
                switch event {
                case let .account(info):
                    // A name another person has taken since this folder was made is not pulled into it (SPEC 23, audit 4,
                    // C4-M4). The folder knows its account's id; a folder from before that compares with the stored one.
                    // The bridge reports the account when it looks the name up, before any file (audit 5, A5-M1); other
                    // accounts a listing looks up are not this folder's.
                    let isThisAccount = info.username.lowercased() == account.lowercased()
                    if let id = info.userID?.nonEmpty { seenIDs[info.username.lowercased()] = id }
                    if isAccount, isThisAccount, place != nil, let id = info.userID?.nonEmpty {
                        if let folderRecord = place?.record {
                            let expected = await folderAccountID(folderRecord, account: account)
                            if let expected, expected != id {
                                let name = URL(fileURLWithPath: folderRecord.path).lastPathComponent
                                fatal = "@\(account) is now a different Instagram account, so nothing was saved into “\(name)”. "
                                    + "If the person changed their name, pull the new name."
                                refused = true
                                break events
                            }
                            await app.accountFolders.update(folderRecord.id, userID: id)
                        } else {
                            // A new folder gets its record with its first file; the id goes with it.
                            accountUserID = id
                        }
                    }
                    if isAccount, isThisAccount {
                        await app.store?.updateAccount(account, userID: info.userID, fullName: info.fullName)
                    }
                    // Only this account's card: tray owners looked up on the way are not it (audit 6, A6-m1).
                    if isThisAccount { accounts[account] = info }
                case let .item(item):
                    job.found += 1
                    if job.state != .running { job.state = .running }
                    window?.ingestEngine([item.ingestInput(sourceURL: sourceURL)])
                case let .file(file):
                    // The account's folder may be renamed, moved or trashed while the pull runs: it is followed, never made
                    // again at its old path (audit 4, A4-M5).
                    if let current = place, target?.accountFolder == current.folder,
                       !FileManager.default.fileExists(atPath: current.folder.path), let record = await folderRecord() {
                        guard let moved = await app.accountFolders.currentFolder(of: record.id) else {
                            fatal = "“\(current.folder.lastPathComponent)” was moved to the Trash or deleted while downloading, "
                                + "so the rest was not saved."
                            refused = true
                            break events
                        }
                        place?.folder = moved
                        target?.folder = moved.deletingLastPathComponent()
                        target?.accountFolder = moved
                        job.destination = moved
                    }
                    guard var target else { continue }
                    guard file.isInside(staging) else {
                        job.failed += 1
                        job.failures.append((file.key, "The engine reported a file outside its working folder. It was left alone."))
                        continue
                    }
                    if let saved = savedFromStaging[file.path.path], !FileManager.default.fileExists(atPath: file.path.path) {
                        job.duplicates += 1
                        let repeated = EngineContext.from(meta: file.meta, key: file.key, subcategory: file.subcategory,
                                                          sourceURL: sourceURL)
                        await remember(file.key, subcategory: repeated.subcategory)
                        window?.markSaved(file.key, url: saved)
                        continue
                    }
                    index += 1
                    let context = EngineContext.from(meta: file.meta, key: file.key, subcategory: file.subcategory, sourceURL: sourceURL)
                    // A single post or Reel goes into its account's folder when the save folder has (or is) one (D-78).
                    // So do others' stories from the tray, each into its owner's folder when there is one (A2-m3).
                    if draft.postURL != nil || context.subcategory == "stories-tray", let root, let user = context.username?.lowercased() {
                        var found: AccountPlace
                        if let known = postPlaces[user] {
                            guard let now = await whereNow(known) else {
                                job.failed += 1
                                job.failures.append((file.key, "“\(known.folder.lastPathComponent)” was moved to the Trash or deleted "
                                        + "while downloading, so this file was not saved."))
                                continue
                            }
                            found = known
                            found.folder = now
                            postPlaces[user] = found
                        } else if let resolved = await resolvePlace(account: user, draft: draft, root: root, name: user) {
                            found = resolved
                            postPlaces[user] = found
                            if resolved.record == nil { madePostFolders.insert(user) }
                        } else {
                            continue
                        }
                        // A post or story of whoever has the name now never goes into the folder of the account that had it
                        // (D-88, audit 6, A6-M2).
                        if let folderID = await folderAccountID(found.record, account: user), let owner = context.ownerID ?? seenIDs[user],
                           owner != folderID
                        {
                            // Not a failure to retry: it would be refused again (audit 7, A7-m4).
                            job.skipped += 1
                            let reason = "@\(user) is now a different Instagram account, so its item was not saved into "
                                + "“\(found.folder.lastPathComponent)”."
                            if job.notes.count < 30 { job.notes.append(reason) }
                            // Shown on the item too, as when saving listed items (audit 8, A8-m9).
                            window?.apply(.finished(itemID: file.key, outcome: .skipped(reason), note: nil))
                            continue
                        }
                        target.accountUsername = user
                        target.accountFolder = found.folder
                        target.accountFolderExisted = found.record != nil
                        target.typeSubfolders = found.sortsByType
                        // A single post's job is its account's; a tray story never changes the running pull's folder.
                        if found.record != nil, draft.postURL != nil { job.destination = found.folder }
                    }
                    // Saved posts go beside the account's folder, but never outside the library: a library folder that is
                    // the account's keeps them inside it (D-52, audit 7, A7-m2).
                    if ["saved", "collection"].contains(context.subcategory), let account = target.accountFolder,
                       app.roots.contains(where: { AccountFolderStore.key($0.url.path) == AccountFolderStore.key(account.path) })
                    {
                        target.folder = account
                        // Copies are looked for in Saved posts, not in the whole library (audit 8, A8-m8).
                        target.accountFolder = nil
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
                        // A new folder gets its record with its first file, so a rename from then on is followed.
                        if place != nil, place?.record == nil { _ = await folderRecord() }
                        await remember(file.key, subcategory: context.subcategory)
                        if draft.postURL != nil || context.subcategory == "stories-tray", let user = context.username?.lowercased() {
                            await rememberPost(file.key, account: user, owner: context.ownerID ?? seenIDs[user])
                        }
                        window?.markSaved(file.key, url: url)
                        await app.store?.recordArchive(key: file.key, account: account, path: url.path, sha256: "")
                        if let date = context.date, newest.map({ date > $0 }) ?? true { newest = date }
                    case let .duplicate(url):
                        job.duplicates += 1
                        savedFromStaging[file.path.path] = url
                        await remember(file.key, subcategory: context.subcategory)
                        if draft.postURL != nil || context.subcategory == "stories-tray", let user = context.username?.lowercased() {
                            await rememberPost(file.key, account: user, owner: context.ownerID ?? seenIDs[user])
                        }
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
                    let what = kind == "profile" ? "profile information" : "\(kind) list (\(count) accounts)"
                    // Written after the media, perhaps hours later: the folder is followed, never made again (audit 5, A5-M3).
                    var folder = root.url.appendingPathComponent(FileNaming.safeTopFolder(account), isDirectory: true)
                    if let current = place {
                        let record = current.record == nil ? await folderRecord() : current.record
                        var followed = current
                        followed.record = record
                        guard let now = await whereNow(followed) else {
                            job.failures.append((kind, "The \(what) was not saved: “\(current.folder.lastPathComponent)” was moved "
                                    + "to the Trash or deleted while downloading."))
                            job.failed += 1
                            continue
                        }
                        folder = now
                    }
                    switch fileAccountDocument(path, kind: kind, into: folder) {
                    case let .success(saved):
                        if job.notes.count < 30 { job.notes.append("Saved the \(what) as \(saved.lastPathComponent)") }
                    case let .failure(error):
                        // Never only dropped with the staging folder (audit 5, A5-m4).
                        job.failed += 1
                        job.failures.append((kind, "The \(what) could not be saved: \(error.localizedDescription)"))
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
                    // Where the posts listing has got to (R-1112). Written as the place this walk would leave if it stopped
                    // now, so a quit or crash keeps it (D-87); the end of the listing removes it again.
                    guard subcategory == "posts", !scanOnly, isAccount else { break }
                    job.lastCursor = value
                    guard walksPosts, !postsComplete, let record = await folderRecord() else { break }
                    if let from = draft.continueFrom {
                        await app.accountFolders.setPlace(ResumePlace(id: from.id, cursor: value, untilEnd: from.untilEnd,
                                                                      findMissing: from.findMissing), in: record.id)
                    } else if fullWalk {
                        await app.accountFolders.replacePlaces(with: [ResumePlace(id: job.placeID, cursor: value, untilEnd: true,
                                                                                  findMissing: draft.findMissing)], in: record.id)
                    } else {
                        await app.accountFolders.setPlace(ResumePlace(id: job.placeID, cursor: value, untilEnd: false), in: record.id)
                    }
                case let .listing(subcategory, complete, _):
                    // The posts listing ended: walked to its end, or to the folder's known posts. Nothing is missing from the
                    // part this walk covered, so its place goes (D-87).
                    guard subcategory == "posts", complete, walksPosts, let record = await folderRecord() else { break }
                    postsComplete = true
                    if let from = draft.continueFrom {
                        await app.accountFolders.removePlace(from.id, in: record.id)
                    } else if fullWalk {
                        await app.accountFolders.replacePlaces(with: [], in: record.id)
                    } else {
                        await app.accountFolders.removePlace(job.placeID, in: record.id)
                    }
                case let .checkpoint(kind, url, message):
                    blocked = true
                    handleCheckpoint(kind: kind, url: url, message: message)
                    job.checkpointURL = url
                case let .error(code, message, key, isFatal):
                    if isFatal {
                        fatal = describe(code: code, message: message)
                    } else if code == "download_failed" {
                        // A file that failed is a failure Retry Failed can fetch again, not a note (audit 4, A4-M3).
                        job.failed += 1
                        job.failures.append((key ?? "", "The file could not be downloaded."))
                    } else if job.notes.count < 30 {
                        job.notes.append(message)
                    }
                case let .policyViolation(method, host, _, reason):
                    fatal = "MediaPull blocked a \(method) request to \(host): \(reason)"
                case let .done(status, errors):
                    // "partial": the walk ran to its end and only single files failed; they are counted above.
                    finishedCleanly = status == "completed" || status == "partial"
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
            // Only a pull whose posts listing was walked counts as an update; any other leaves the date of the last one (a
            // stories link does not make the folder up to date).
            let complete = postsComplete && finishedCleanly && fatal == nil && !blocked && job.state != .cancelled
            await app.accountFolders.update(record.id, lastUpdate: complete ? Date() : nil, lastResult: job.summary)
            await app.refreshAccountFolders()
        }
        if Task.isCancelled || job.state == .cancelled {
            app.jobs.finish(job, .cancelled)
            return
        }
        if refused, let fatal {
            app.jobs.finish(job, .failed(fatal))
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
        // The newest posts are in: places left by earlier walks that stopped part way continue now, one job each, posts
        // only (R-1904, D-87). A full walk covered everything, and a continuation is one itself.
        if postsComplete, !continuing, !fullWalk, let place {
            await continuePlaces(of: place.folder, account: account, draft: draft, window: window)
        }
    }

    /// The account id a folder belongs to: its own. A folder that has none yet (one from before 1.8) learns it at its
    /// first update; the name-to-id table cannot stand in for it, since 1.7 replaced that id at every look-up (D-92, audit
    /// 8, A8-m5, C8-m4).
    func folderAccountID(_ record: AccountFolderRecord?, account _: String) async -> String? {
        record?.userID?.nonEmpty
    }

    /// Starts a continuation for each place where posts may still be missing in an account folder (D-87).
    func continuePlaces(of folder: URL, account: String, draft: PullDraft, window: WindowModel?) async {
        guard let record = await app.accountFolders.all().first(where: {
            AccountFolderStore.key($0.path) == AccountFolderStore.key(folder.path) && $0.account == account.lowercased()
        }) else { return }
        for place in record.places ?? [] {
            var next = draft
            next.accountFolder = folder
            next.accountFolderID = record.id
            next.continueFrom = place
            next.findMissing = false
            next.incremental = true
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

    /// `name` names a new folder: the pulled account's own choice by default; another account met in the pull (a tray
    /// story's owner, a post's) gets its own name (audit 3, A3-M1). Nil when the folder chosen for the pull is gone (moved
    /// to the Trash, deleted): it is never made again (audit 4, A4-M5).
    private func resolvePlace(account: String, draft: PullDraft, root: SaveDestination, name ownName: String? = nil) async
        -> AccountPlace? {
        let libraryRoot = app.root(containing: root.url)?.url
        let saveFolder = root.url
        let name = ownName ?? draft.folderName.nonEmpty ?? account
        // A folder chosen when the pull was queued is followed to where it is now (renamed or moved since).
        var chosen: URL?
        if ownName == nil, let id = draft.accountFolderID {
            guard let now = await app.accountFolders.currentFolder(of: id) else { return nil }
            chosen = now
        } else if ownName == nil, let picked = draft.accountFolder {
            guard let now = await app.accountFolders.currentFolder(for: picked) else { return nil }
            chosen = now
        } else {
            chosen = await recordedFolder(of: account, around: saveFolder)
        }
        let known = chosen
        // Reading the folder (names, and a sample of metadata files) happens off the main actor.
        let (folder, index, byType, existing) = await Task.detached(priority: .userInitiated) {
            () -> (URL, AccountFolders.Index, Bool?, Bool) in
            let resolved = known.map { (existing: Optional($0), parent: $0.deletingLastPathComponent()) }
                ?? AccountFolders.resolveTarget(account: account, saveFolder: saveFolder, root: libraryRoot)
            guard let existing = resolved.existing else {
                // A new folder never goes into one of that name that already holds something else (another account's).
                return (AccountFolders.newFolder(named: name, in: resolved.parent), AccountFolders.Index(), nil, false)
            }
            return (existing, AccountFolders.index(existing), AccountFolders.sortsByType(existing), true)
        }.value
        var record = existing ? await app.accountFolders.record(account: account, folder: folder) : nil
        if let new = record {
            await adoptEarlierMemory(of: new, account: account)
            record = await app.accountFolders.record(account: account, folder: folder)
        }
        return AccountPlace(folder: folder, index: index, record: record, sortsByType: byType)
    }

    /// The remembered folder of `account` that `saveFolder` is, is inside, or holds. Records count as well as what folders
    /// hold, since a Plain folder has no metadata files to read (audit 4, C4-M2).
    func recordedFolder(of account: String, around saveFolder: URL) async -> URL? {
        let mine = await app.accountFolders.all().filter { $0.account == account.lowercased() }
        let key = AccountFolderStore.key(saveFolder.path)
        let containing = mine.filter {
            let own = AccountFolderStore.key($0.path)
            return key == own || key.hasPrefix(own + "/")
        }.max { $0.path.count < $1.path.count }
        let inside = mine.filter { AccountFolderStore.key($0.path).hasPrefix(key + "/") }
            .max { ($0.lastUpdate ?? .distantPast, -$0.path.count) < ($1.lastUpdate ?? .distantPast, -$1.path.count) }
        return (containing ?? inside).map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }

    /// A folder whose record has never been updated takes over what earlier versions remembered of it: the items saved
    /// there, deleted since or not, and where an interrupted pull stopped (audit 3, C3-M1, C3-m14). Taken entries leave the
    /// shared table, so a second call finds nothing; scanned saves call it too (audit 4, C4-m1).
    func adoptEarlierMemory(of record: AccountFolderRecord, account: String) async {
        guard record.lastUpdate == nil, (record.places ?? []).isEmpty else { return }
        let keys = await app.store?.takeInstagramKeys(account: account, under: record.path) ?? []
        if !keys.isEmpty { await app.accountFolders.addKeys(keys, to: record.id) }
        if let cursor = await app.store?.account(account)?.resumeCursor, !cursor.isEmpty {
            await app.accountFolders.setPlace(ResumePlace(cursor: cursor, untilEnd: true), in: record.id)
            await app.store?.updateAccount(account, resumeCursor: .some(nil))
        }
    }

    /// Activity's Resume: continues each place where an update or Find Missing stopped part way, without walking from the
    /// top again (R-1904, D-87).
    func resumePlaces(account: String, folder: URL, window: WindowModel?) async {
        guard let folder = await app.accountFolders.currentFolder(for: folder) else { return }
        var draft = self.draft(username: account)
        await applyStoredOptions(to: &draft)
        draft.accountFolder = folder
        draft.folderName = folder.lastPathComponent
        await continuePlaces(of: folder, account: account, draft: draft, window: window)
    }

    /// Update an account's folder in one click (D-80): the account's remembered media choices and pace, no form. `findMissing`
    /// walks every post and adds what the folder lacks instead of stopping at what is already there.
    @discardableResult
    func startUpdate(account: String, folder: URL, findMissing: Bool, window: WindowModel?) async -> Job? {
        // The folder may have been renamed or moved in the Finder since the list was made: found again, never recreated.
        guard let folder = await app.accountFolders.currentFolder(for: folder) else {
            let job = Job(kind: .pull, title: "Updating @\(account)")
            app.jobs.add(job)
            app.jobs.finish(job, .failed("The folder of @\(account) is no longer there. It may have been moved to the Trash."))
            await app.refreshAccountFolders()
            return job
        }
        // One update of a folder at a time: a second click, or Update All twice, adds nothing (audit 3, C3-m10).
        let key = AccountFolderStore.key(folder.path)
        if let running = app.jobs.jobs.first(where: {
            $0.kind == .pull && $0.state.canCancel && $0.destination.map { AccountFolderStore.key($0.path) == key } == true
        }) {
            return running
        }
        var draft = self.draft(username: account)
        await applyStoredOptions(to: &draft)
        // One click takes the account's media only: never its details, follower lists or the person's own saved posts.
        draft.content = draft.content.filter(\.isProfileMedia)
        if draft.content.isEmpty { draft.content = app.preferences.defaultContent.filter(\.isProfileMedia) }
        draft.accountFolder = folder
        // The folder gets its record now if it has none (one found by its metadata), so the queued update finds it by that
        // wherever it goes before it starts (audit 6, C6-M2).
        draft.accountFolderID = await app.accountFolders.record(account: account, folder: folder).id
        draft.findMissing = findMissing
        draft.incremental = !findMissing
        draft.folderName = folder.lastPathComponent
        // An earlier update that stopped part way needs nothing more: this pass covers the top, and the rest continues from
        // where it stopped right after (runPull).
        return startPull(draft, scanOnly: false, window: window)
    }

    /// Moves a followers or following list, or the profile, into `<account>/Account details/` with the date in its name.
    private func fileAccountDocument(_ file: URL, kind: String, into accountFolder: URL) -> Result<URL, Error> {
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
            return .success(target)
        } catch {
            return .failure(error)
        }
    }

    // MARK: Videos (SPEC section 35)

    /// Lists the formats of the video on a page, without downloading it.
    func videoInfo(for url: URL) async -> Result<VideoInfo, VideoLookupError> {
        guard let bridge else { return .failure(VideoLookupError(message: "The download engine is not available.")) }
        // Instagram is only asked through its own options, one job at a time and never past a checkpoint (R-1113, R-1114).
        if url.host?.lowercased().hasSuffix("instagram.com") ?? false {
            return .failure(VideoLookupError(message: "Instagram videos are downloaded with the Instagram options: enter the post or "
                    + "Reel address in Downloads."))
        }
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
        // Retry saves where the folder is then (audit 7, A7-m3).
        let folder = FollowedFolder(root.url)
        let run = { [weak self, weak job] in
            guard let self, let job else { return }
            job.task = Task { [weak self, weak job] in
                guard let self, let job else { return }
                guard let now = await folder.now() else {
                    // The failures stay, so Retry Failed is still offered once the folder is back (audit 8, A8-m7).
                    job.notes.append(FollowedFolder.goneMessage(root.url))
                    self.app.jobs.finish(job, job.failed > 0 ? .completed : .failed(FollowedFolder.goneMessage(root.url)))
                    return
                }
                job.failed = 0
                job.failures = []
                // Where the folder is now, in its library's layout (A8-m6).
                let root = self.app.destination(for: now)
                if now.standardizedFileURL.path != folder.url.standardizedFileURL.path {
                    job.destination = job.destination.map { LibraryModel.followed($0, from: folder.url.path, to: now.path) }
                }
                await self.runVideo(job: job, url: url, info: info, format: format, height: height, extras: extras, root: root, site: site)
            }
        }
        run()
        job.retry = { [weak job] in
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
        let selector = format.selector(height: height, policy: app.preferences.video, av1Decodable: FFmpeg.canDecodeAV1)
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
        let converts = format.needsConversion(in: info.formats, height: height, policy: app.preferences.video,
                                              av1Decodable: FFmpeg.canDecodeAV1)
        job.currentItem = converts ? "Converting \(title) to HEVC" : "Saving \(title)"
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
        // The same video downloaded again already has its side files: they are not added a second time, numbered.
        let finalName = kind == "thumbnail" ? destination.deletingPathExtension().appendingPathExtension("jpg") : destination
        if FileManager.default.fileExists(atPath: finalName.path) { // lint:allow main-io one file's existence
            try? FileManager.default.removeItem(at: path) // lint:allow main-io silent-write a staged copy, cleaned with staging anyway
            return nil
        }
        // Thumbnails are saved as JPEG (R-3505), whatever the site served: WebP, PNG and the rest.
        if kind == "thumbnail", !["jpg", "jpeg"].contains(ext),
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

    /// Decoding and encoding stay off the main actor. Always JPEG, so the file is what its name says.
    @concurrent
    private nonisolated static func convertToJPEG(_ path: URL, output: URL) async -> Bool {
        (try? ImageConversion.convertStill(path, to: .jpeg, output: output)) != nil
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
            if case let .supports(site) = event {
                if let site, !site.baseCategory.isEmpty { siteBases[site.category] = site.baseCategory }
                return site
            }
        }
        return nil
    }

    /// The base family of sites seen this session (derpibooru is philomena's), so scans and re-fetches find the key
    /// saved for it (audit 3, A3-m7).
    var siteBases: [String: String] = [:]

    func siteKeys(for category: String) -> SiteKeys? {
        SiteKeys.forSite(category, baseCategory: siteBases[category] ?? "")
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
            if let keys = siteKeys(for: category) {
                let saved = SiteKeychain.keys(for: category, fields: keys.fields)
                if !saved.isEmpty { request.siteKeys = saved }
            }
            request.staging = staging?.path
            request.setPacing([1, 2])
            let siteName = self.app.sites.name(SiteInfoKey(category: category))
            let ownKey = siteKeys(for: category) != nil
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
        // Retry Failed downloads the address again, skipping what was saved (R-1903).
        let folder = FollowedFolder(root.url)
        job.retry = { [weak self, weak window, weak job] in
            // The new download takes over the failed files; this one no longer offers them (audit 6, A6-m4). It saves
            // where the folder is now, in its library's layout; when the folder is gone, its failures stay (audit 8, A8-m6,
            // A8-m7).
            Task { [weak self, weak window] in
                guard let self else { return }
                guard let now = await folder.now() else {
                    job?.notes.append(FollowedFolder.goneMessage(root.url))
                    return
                }
                job?.failed = 0
                job?.failures = []
                _ = self.startGalleryDownload(url: url, site: site, include: include, switches: switches, range: range, from: from,
                                              to: to, onlyNew: true, root: self.app.destination(for: now), window: window)
            }
        }
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
            // A file reported twice (gallery-dl finds it already there) was saved by the first report (A2-m1).
            var savedFromStaging: [String: URL] = [:]
            do {
                for try await event in bridge.run(request, workingDirectory: staging) {
                    if Task.isCancelled { break }
                    // Any event but a wait means the engine is working again, not pausing between requests.
                    if case .wait = event {} else if case .waiting = job.state { job.state = .running }
                    switch event {
                    case .item:
                        job.found += 1
                    case let .file(file) where file.isInside(staging):
                        if let saved = savedFromStaging[file.path.path], !FileManager.default.fileExists(atPath: file.path.path) {
                            job.duplicates += 1
                            await self.app.store?.recordArchive(key: file.key, account: account, path: saved.path, sha256: "")
                            continue
                        }
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
                            savedFromStaging[file.path.path] = saved
                            await self.app.store?.recordArchive(key: file.key, account: account, path: saved.path, sha256: "")
                        case let .duplicate(saved):
                            job.duplicates += 1
                            savedFromStaging[file.path.path] = saved
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
                    case let .error(code, message, key, isFatal):
                        if isFatal {
                            fatal = GalleryError.describe(self.describe(code: code, message: message), site: siteName, ownKey: ownKey)
                        } else if code == "download_failed" {
                            // A file that failed is a failure Retry Failed fetches again, as in Instagram pulls (audit 5,
                            // A5-m1), not a note.
                            job.failed += 1
                            job.failures.append((key ?? "", message))
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

/// Resumes a continuation once, however many times it is fired.
nonisolated final class OneShot: Sendable {
    private let state: OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>

    init(_ continuation: CheckedContinuation<Void, Never>) {
        state = OSAllocatedUnfairLock(initialState: continuation)
    }

    func fire() {
        state.withLock { continuation in
            continuation?.resume()
            continuation = nil
        }
    }
}

/// The draft a pull job runs now, shared by its Resume and Retry Failed, and how to find its folders again.
@MainActor
private final class PullRun {
    var draft: PullDraft
    var root: FollowedFolder?

    init(draft: PullDraft) { self.draft = draft }

    /// Once the account's folder has a record, Retry and Resume find it by that, not by a path (audit 6, C6-M2, C6-M3).
    func remember(_ id: UUID, folder: URL) {
        guard draft.postURL == nil, draft.hashtag == nil else { return }
        draft.accountFolderID = id
        draft.accountFolder = folder
    }
}
