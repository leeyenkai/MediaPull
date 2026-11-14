import AppKit
import Foundation
import MediaPullBrowser
import MediaPullCore
import MediaPullEngines
import MediaPullLibrary
import MediaPullNet
import MediaPullStore
import Observation

/// What the Pull sheet is set up with.
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
    var rootID: UUID?
    var folderName: String
    var layout: SaveLayout
    var incremental = true
    var pacing: PacingPreset
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
    @ObservationIgnored private var cooldownLevel = 0
    @ObservationIgnored private var instagramQueue: [(job: Job, run: () async -> Void)] = []
    @ObservationIgnored private var instagramBusy = false

    init(app: AppModel) {
        self.app = app
    }

    var bridge: BridgeClient? { app.engineManager.map { BridgeClient(paths: $0.paths) } }

    func refreshSignIn() async {
        let cookies = await CookieBridge.allCookies(app.cookieStore)
        signedIn = CookieBridge.isSignedInToInstagram(cookies)
    }

    func handleCheckpoint(kind: String, url: URL?, message: String) {
        if kind == "rate_limit" || kind == "feedback" {
            cooldownLevel = min(cooldownLevel + 1, 3)
            let minutes = [10, 10, 20, 40][cooldownLevel]
            gate = .cooldown(until: Date().addingTimeInterval(TimeInterval(minutes * 60)))
        } else {
            gate = .blocked(kind: kind, url: url, message: message)
        }
        let target = url ?? (kind == "login" ? URL(string: "https://www.instagram.com/accounts/login/") : nil)
        if let target, let window = app.frontWindow {
            window.showBrowser = true
            window.browser.load(target)
        }
        JobCenter.post(title: "Instagram needs your attention", body: gateMessage ?? "Open MediaPull to continue.")
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

    /// Only the person resumes after a checkpoint, and only once the condition is cleared (R-1114).
    func resumeAfterCheckpoint() async {
        await refreshSignIn()
        switch gate {
        case let .cooldown(until) where until > Date():
            return
        case let .blocked(kind, _, _) where kind == "login" && !signedIn:
            return
        default:
            break
        }
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
        guard let bridge else { return }
        lookupErrors[username] = nil
        guard canRunInstagram else {
            lookupErrors[username] = gateMessage ?? "Instagram is not available right now."
            return
        }
        guard !instagramBusy else {
            lookupErrors[username] = "Account details appear once the current Instagram job finishes."
            return
        }
        var request = BridgeRequest(op: "account")
        request.username = username
        let job = UUID().uuidString
        let cookieFile = CookieFile.privateLocation(job: job)
        defer { try? FileManager.default.removeItem(at: cookieFile.deletingLastPathComponent()) }
        try? CookieFile.write(await app.cookies(forDomain: "instagram.com"), to: cookieFile)
        request.cookies = cookieFile.path
        request.staging = app.enginePaths?.staging.appendingPathComponent(job).path
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
            if !found { lookupErrors[username] = problem ?? "The account could not be found." }
        } catch {
            lookupErrors[username] = error.localizedDescription
        }
    }

    func describe(code: String, message: String) -> String {
        switch code {
        case "private": return "This account is private. Instagram only shows its posts to followers."
        case "not_found":
            return signedIn ? "No Instagram account has that name." : "Instagram did not answer. Sign in to Instagram in the browser pane to look up accounts."
        case "engine_outdated": return "Instagram may have changed. Check for engine updates in Settings."
        case "login_required": return "Sign in to Instagram in the browser pane first."
        default: return message
        }
    }

    // MARK: Drafts

    func draft(username: String, postURL: URL? = nil) -> PullDraft {
        let prefs = app.preferences
        var draft = PullDraft(username: username, postURL: postURL, content: prefs.defaultContent, rootID: app.defaultRoot?.id,
                              folderName: username, layout: app.defaultRoot?.layout ?? prefs.defaultLayout, pacing: prefs.pacing)
        if postURL != nil { draft.content = [.posts] }
        return draft
    }

    func applyStoredOptions(to draft: inout PullDraft) async {
        guard let info = await app.store?.account(draft.username) else {
            draft.incremental = false
            return
        }
        if let options = info.options {
            draft.content = options.content
            draft.layout = options.layout
            draft.pacing = options.pacing
            if let root = options.rootID, app.roots.contains(where: { $0.id == root }) { draft.rootID = root }
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
        let root = app.roots.first { $0.id == draft.rootID } ?? app.defaultRoot
        if !scanOnly, root == nil {
            app.jobs.finish(job, .failed("Choose a library folder first."))
            return job
        }
        if !scanOnly, let root {
            if let tag = draft.hashtag {
                job.destination = root.url.appendingPathComponent(SaveTarget.tagsFolder, isDirectory: true).appendingPathComponent(tag)
            } else if draft.postURL == nil, !draft.username.isEmpty {
                job.destination = root.url.appendingPathComponent(FileNaming.safeTopFolder(draft.folderName.nonEmpty ?? draft.username),
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
        if !scanOnly, draft.hashtag == nil, !draft.username.isEmpty {
            Task {
                await app.store?.updateAccount(draft.username, options: PullOptions(content: draft.content, layout: draft.layout,
                                                                                    rootID: root?.id, pacing: draft.pacing))
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

    private func runPull(job: Job, draft: PullDraft, root: LibraryRootInfo?, scanOnly: Bool, window: WindowModel?, bridge: BridgeClient,
                         resuming: Bool) async
    {
        if case .cancelled = job.state { return }
        guard canRunInstagram else {
            job.state = .blocked(gateMessage ?? "Instagram is not available right now.")
            return
        }
        job.state = .running
        let work = UUID().uuidString
        guard let staging = app.enginePaths?.staging.appendingPathComponent(work, isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let cookieFile = CookieFile.privateLocation(job: work)
        let originalCookies = await app.cookies(forDomain: "instagram.com")
        defer {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: cookieFile.deletingLastPathComponent())
        }
        do {
            try CookieFile.write(originalCookies, to: cookieFile)
        } catch {
            app.jobs.finish(job, .failed("The sign-in cookies could not be prepared: \(error.localizedDescription)"))
            return
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
        request.cookies = cookieFile.path
        request.staging = staging.path
        request.setPacing(draft.pacing.delay)
        let selector = app.preferences.video.selector(av1Decodable: FFmpeg.canDecodeAV1)
        request.video = BridgeRequest.Video(format: selector.format, formatSort: selector.sort)
        let dates = draft.dateWindow.bounds(from: draft.dateFrom, to: draft.dateTo)
        if let from = dates.from { request.dateFrom = ISO8601DateFormatter().string(from: from) }
        if let to = dates.to { request.dateTo = ISO8601DateFormatter().string(from: to) }
        if (draft.incremental || resuming), draft.postURL == nil, !scanOnly, isAccount || draft.hashtag != nil {
            let known = await app.store?.knownKeys(account: account) ?? []
            let knownFile = staging.appendingPathComponent("known.json")
            if let data = try? JSONEncoder().encode(Array(known)) { try? data.write(to: knownFile) }
            request.knownIDs = knownFile.path
            // A resumed pull continues from where it stopped and must not end early on known posts.
            request.stopAfterKnown = resuming ? nil : app.preferences.stopAfterKnown
        }
        if resuming, let cursor = stored?.resumeCursor, draft.postURL == nil, !scanOnly { request.cursor = cursor }

        let target: SaveTarget? = root.map { root in
            if let tag = draft.hashtag {
                return SaveTarget(folder: root.url, layout: draft.layout, autoSubfolders: true, collectionPath: [SaveTarget.tagsFolder, tag])
            }
            return draft.postURL == nil && isAccount
                ? SaveTarget(folder: root.url, layout: draft.layout, autoSubfolders: true, accountUsername: draft.folderName.nonEmpty ?? account)
                : SaveTarget(folder: root.url, layout: draft.layout, autoSubfolders: true)
        }
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
                    guard let target else { continue }
                    guard file.isInside(staging) else {
                        job.failed += 1
                        job.failures.append((file.key, "The engine reported a file outside its working folder. It was left alone."))
                        continue
                    }
                    index += 1
                    let context = EngineContext.from(meta: file.meta, key: file.key, subcategory: file.subcategory, sourceURL: sourceURL)
                    let isVideo = ["mp4", "mov", "m4v", "webm", "mkv"].contains(file.path.pathExtension.lowercased())
                    let input = EngineItemInput(context: context, kind: isVideo ? .video : .image,
                                                engineURL: context.postURL?.absoluteString ?? file.path.absoluteString, thumbURL: nil,
                                                width: file.meta["width"]?.int, height: file.meta["height"]?.int, isDash: false, fallbackURL: nil)
                    let item = input.makeItem(discoveryIndex: index)
                    job.currentItem = context.postShortcode ?? file.path.lastPathComponent
                    let (outcome, note) = await pipeline.saveStaged(file.path, item: item, target: target, settings: settings, index: index)
                    try? FileManager.default.removeItem(at: file.path)
                    switch outcome {
                    case let .saved(url):
                        job.saved += 1
                        window?.markSaved(file.key, url: url)
                        await app.store?.recordArchive(key: file.key, account: account, path: url.path, sha256: "")
                        if let date = context.date, newest.map({ date > $0 }) ?? true { newest = date }
                    case let .duplicate(url):
                        job.duplicates += 1
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
                    guard !scanOnly, let root, isAccount, path.standardizedFileURL.path.hasPrefix(staging.standardizedFileURL.path + "/") else {
                        continue
                    }
                    if let saved = fileAccountDocument(path, kind: kind, root: root, folder: draft.folderName.nonEmpty ?? account) {
                        let what = kind == "profile" ? "profile information" : "\(kind) list (\(count) accounts)"
                        if job.notes.count < 30 { job.notes.append("Saved the \(what) as \(saved.lastPathComponent)") }
                    }
                case .skip:
                    job.skipped += 1
                case let .wait(seconds, reason):
                    job.state = .waiting(until: Date().addingTimeInterval(seconds), reason: reason)
                case let .progress(received, total, _):
                    if let received, let total, total > 0 { job.fraction = nil; job.currentItem = "\(Format.bytes(received)) of \(Format.bytes(total))" }
                case let .cursor(subcategory, value):
                    if subcategory == "posts", !scanOnly, isAccount { await app.store?.updateAccount(account, resumeCursor: .some(value)) }
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
                    if status == "failed", fatal == nil { fatal = errors.last.map { describe(code: "", message: $0) } ?? "The download engine stopped." }
                default:
                    break
                }
            }
        } catch {
            fatal = error.localizedDescription
        }

        let updated = CookieFile.read(cookieFile)
        if !updated.isEmpty { await CookieBridge.update(updated, in: app.cookieStore, existing: originalCookies) }
        await refreshSignIn()
        app.libraryRevision += 1
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
                await app.store?.updateAccount(account, newestSavedDate: newest, resumeCursor: .some(nil), lastResult: job.summary, pulledNow: true)
            } else {
                await app.store?.updateAccount(account, newestSavedDate: newest, lastResult: job.summary)
            }
        }
        cooldownLevel = max(0, cooldownLevel - 1)
        app.jobs.finish(job, .completed)
    }

    /// Moves a followers or following list, or the profile, into `<account>/Account details/` with the date in its name.
    private func fileAccountDocument(_ file: URL, kind: String, root: LibraryRootInfo, folder: String) -> URL? {
        let directory = root.url.appendingPathComponent(FileNaming.safeTopFolder(folder), isDirectory: true)
            .appendingPathComponent(SaveTarget.accountDetailsFolder, isDirectory: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        let name = FileNaming.fileName(stem: "\(formatter.string(from: Date()))_\(kind)", ext: file.pathExtension)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = LibraryModel.uniqueURL(directory.appendingPathComponent(name))
            try FileManager.default.moveItem(at: file, to: target)
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

    /// Downloads a video in the chosen format and resolution into `<root>/<site>/<uploader>/`.
    @discardableResult
    func saveVideo(_ info: VideoInfo, format: VideoDownloadFormat, height: Int?, root: LibraryRootInfo, window: WindowModel?) -> Job {
        let job = Job(kind: .stream, title: info.title)
        job.subtitle = format.label + (format.isAudioOnly ? "" : ", " + (height.map { "\($0)p" } ?? "best resolution"))
        let site = info.webpageURL.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? info.extractor
        let channel = info.uploader?.nonEmpty ?? "Videos"
        job.destination = root.url.appendingPathComponent(FileNaming.safeTopFolder(site), isDirectory: true)
            .appendingPathComponent(FileNaming.sanitize(channel, maxBytes: 80), isDirectory: true)
        app.jobs.add(job)
        job.task = Task { [weak self, weak job] in
            guard let self, let job else { return }
            await self.runVideo(job: job, info: info, format: format, height: height, root: root, site: site, channel: channel, window: window)
        }
        job.retry = { [weak self, weak job, weak window] in
            guard let self, let job else { return }
            job.failed = 0
            job.failures = []
            job.finishedAt = nil
            job.task = Task { [weak self, weak job] in
                guard let self, let job else { return }
                await self.runVideo(job: job, info: info, format: format, height: height, root: root, site: site, channel: channel,
                                    window: window)
            }
        }
        return job
    }

    private func runVideo(job: Job, info: VideoInfo, format: VideoDownloadFormat, height: Int?, root: LibraryRootInfo, site: String,
                          channel: String, window: WindowModel?) async
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
        request.url = info.webpageURL.absoluteString
        request.staging = staging.path
        request.userAgent = app.userAgent
        request.key = "video:\(info.extractor):\(info.id ?? info.webpageURL.absoluteString)"
        let selector = format.selector(height: height)
        request.video = BridgeRequest.Video(format: selector.format, formatSort: selector.sort, merge: selector.merge)

        var file: BridgeFile?
        var failure: String?
        do {
            for try await event in bridge.run(request, workingDirectory: staging) {
                if Task.isCancelled { break }
                switch event {
                case let .progress(received, total, _):
                    if let received, let total, total > 0 {
                        job.fraction = Double(received) / Double(total)
                        job.currentItem = "\(Format.bytes(received)) of \(Format.bytes(total))"
                    }
                case let .file(found) where found.isInside(staging):
                    file = found
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
        if Task.isCancelled || job.state == .cancelled {
            app.jobs.finish(job, .cancelled)
            return
        }
        guard let file else {
            app.jobs.finish(job, .failed(failure ?? "The video could not be downloaded."))
            return
        }
        job.fraction = nil
        job.currentItem = format.needsConversion(in: info.formats, height: height) ? "Converting to HEVC" : "Saving"
        var context = EngineContext(key: request.key ?? "video", category: info.extractor.nonEmpty ?? site,
                                    subcategory: format.isAudioOnly ? "audio" : "video")
        context.username = info.uploader
        context.postID = info.id
        context.shortcode = info.id
        context.date = info.uploadDate
        context.title = info.title
        context.description = info.title
        context.postURL = info.webpageURL
        context.sourceURL = info.webpageURL
        let input = EngineItemInput(context: context, kind: format.isAudioOnly ? .audio : .video, engineURL: info.webpageURL.absoluteString,
                                    thumbURL: info.thumbnail, width: file.meta["width"]?.int, height: file.meta["height"]?.int,
                                    isDash: false, fallbackURL: nil)
        let item = input.makeItem(discoveryIndex: 0)
        let target = SaveTarget(folder: root.url, layout: root.layout, autoSubfolders: true,
                                collectionPath: [site, FileNaming.sanitize(channel, maxBytes: 80)])
        var settings = app.saveSettings
        settings.conversion.keepDownloadedMedia = format.keepsDownloadedFile
        let (outcome, note) = await app.pipeline().saveStaged(file.path, item: item, target: target, settings: settings, index: 1,
                                                              nameOverride: info.title)
        if let note { job.notes.append(note) }
        switch outcome {
        case let .saved(url):
            job.saved = 1
            job.destination = url
        case let .duplicate(url):
            job.duplicates = 1
            job.destination = url
        case let .skipped(reason):
            job.skipped = 1
            app.jobs.finish(job, .failed(reason))
            return
        case let .failed(reason):
            job.failed = 1
            app.jobs.finish(job, .failed(reason))
            return
        }
        app.libraryRevision += 1
        app.jobs.finish(job, .completed)
    }

    // MARK: Site extractor

    func supportedCategory(for url: URL) async -> String? {
        guard let bridge else { return nil }
        var request = BridgeRequest(op: "supports")
        request.url = url.absoluteString
        guard let events = try? await bridge.collect(request) else { return nil }
        for event in events {
            if case let .supports(supported, category, _) = event, supported { return category }
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
            let cookieFile = CookieFile.privateLocation(job: work)
            defer {
                if let staging { try? FileManager.default.removeItem(at: staging) }
                try? FileManager.default.removeItem(at: cookieFile.deletingLastPathComponent())
            }
            let domain = PublicSuffix.shared.registrableDomain(url.host ?? "")
            try? CookieFile.write(await self.app.cookies(forDomain: domain), to: cookieFile)
            var request = BridgeRequest(op: "scan")
            request.url = url.absoluteString
            request.cookies = cookieFile.path
            request.staging = staging?.path
            request.setPacing([1, 2])
            var fatal: String?
            var batch: [EngineItemInput] = []
            do {
                for try await event in bridge.run(request, workingDirectory: staging) {
                    if Task.isCancelled { break }
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
                        if isFatal { fatal = self.describe(code: code, message: message) }
                    case let .done(status, errors):
                        if status == "failed", fatal == nil, job.found == 0 { fatal = errors.last ?? "The site extractor found nothing." }
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
            } else if let fatal, job.found == 0 {
                self.app.jobs.finish(job, .failed(fatal))
            } else {
                self.app.jobs.finish(job, .completed)
            }
        }
        return job
    }
}
