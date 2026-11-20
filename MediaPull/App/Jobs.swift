import Foundation
import MediaPullLibrary
import MediaPullStore
import Observation
import UserNotifications

enum JobKind: String {
    case save = "Save"
    case pull = "Pull"
    case scan = "Scan"
    case stream = "Stream"
    case convert = "Convert"
    case engineUpdate = "Engine update"
    case analyse = "Analyse"
    case organise = "Organise"
    case importing = "Import"
}

enum JobState: Equatable {
    case queued
    case running
    case waiting(until: Date, reason: String)
    case paused
    case blocked(String)
    case completed
    case failed(String)
    case cancelled

    var isActive: Bool {
        switch self {
        case .queued, .running, .waiting: true
        default: false
        }
    }

    /// Jobs a person can still stop: running, waiting, paused or blocked.
    var canCancel: Bool {
        switch self {
        case .queued, .running, .waiting, .paused, .blocked: true
        default: false
        }
    }

    var isFinished: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        default: false
        }
    }

    var label: String {
        switch self {
        case .queued: "Waiting to start"
        case .running: "Running"
        case let .waiting(until, reason):
            // Any site can ask for this, not only Instagram.
            reason == "rate_limit" ? "The site asked to slow down, waiting until \(until.formatted(date: .omitted, time: .shortened))"
                : "Pausing between requests"
        case .paused: "Paused"
        case let .blocked(message): message
        case .completed: "Done"
        case let .failed(message): message
        case .cancelled: "Cancelled"
        }
    }
}

/// One unit of background work shown in the Activity panel (SPEC section 19).
@Observable
final class Job: Identifiable {
    let id = UUID()
    let kind: JobKind
    var title: String
    var subtitle: String = ""
    var state: JobState = .queued
    var total = 0
    var found = 0
    var saved = 0
    var duplicates = 0
    var skipped = 0
    var failed = 0
    var currentItem: String?
    var fraction: Double?
    var destination: URL?
    /// Each note once: a Retry that meets the same thing says it once (audit 16, C16-m3).
    var notes: [String] = [] {
        didSet {
            var seen = Set<String>()
            if notes.contains(where: { !seen.insert($0).inserted }) {
                var once = Set<String>()
                notes = notes.filter { once.insert($0).inserted }
            }
        }
    }

    var failures: [(id: String, message: String)] = []
    var checkpointURL: URL?
    let startedAt = Date()
    var finishedAt: Date?
    var task: Task<Void, Never>? {
        didSet {
            // Known when the work itself has ended, whatever the job's state says (Quit waits on file changes, B17-M1).
            taskEnded = false
            guard let task else { return }
            Task { [weak self] in
                await task.value
                if self?.task == task { self?.taskEnded = true }
            }
        }
    }

    var taskEnded = false
    var retry: (() -> Void)?
    /// Set while a Retry Failed is starting (its folder is being found), so a second click starts nothing more (A9-m2).
    var retryStarting = false
    /// The latest time the job was put in the Instagram queue; older queue entries of it do nothing.
    @ObservationIgnored var queueToken: UUID?
    /// A pull that walks the whole account (Find Missing, Retry Failed), told apart from an Update of the same folder.
    var walksAll = false
    /// A one-click Update or Find Missing of a folder (not a form pull or a continuation).
    var isUpdate = false
    /// Where an Instagram listing had got to in this job, so Resume continues this job's own pass (R-1112).
    var lastCursor: String?
    /// The id of the place this job's walk leaves in its account folder if it stops part way (D-87); the same across Resume.
    var placeID = UUID()
    var resume: (() -> Void)?

    init(kind: JobKind, title: String) {
        self.kind = kind
        self.title = title
    }

    var done: Int { saved + duplicates + skipped + failed }

    var progress: Double? {
        if let fraction { return fraction }
        guard total > 0 else { return nil }
        return min(1, Double(done) / Double(total))
    }

    /// Replaces the save counts in the summary, for jobs that do not save (analysing, organising).
    var summaryOverride: String?
    /// Called by the Activity panel's Pause and Resume for jobs that can pause.
    var pauseToggle: (() -> Void)?

    var summary: String {
        if let summaryOverride { return summaryOverride }
        var parts: [String] = []
        if found > 0 { parts.append("\(found) found") }
        if saved > 0 { parts.append("\(saved) saved") }
        if duplicates > 0 { parts.append("\(duplicates) already saved") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if failed > 0 { parts.append("\(failed) failed") }
        if parts.isEmpty, total > 0 { parts.append("\(total) items") }
        return parts.joined(separator: ", ")
    }

    func cancel() {
        // A Retry cancelled before it ran leaves Retry Failed usable again (audit 10, A10-m1, C10-m2).
        retryStarting = false
        task?.cancel()
        if !state.isFinished { state = .cancelled; finishedAt = Date() }
    }
}

@Observable
final class JobCenter {
    var jobs: [Job] = []
    var store: AppStore?
    var notify: () -> Bool = { true }

    var activeCount: Int { jobs.filter { $0.state.isActive }.count }
    var hasBlocked: Bool {
        jobs.contains { if case .blocked = $0.state { return true } else { return false } }
    }

    func add(_ job: Job) {
        jobs.insert(job, at: 0)
        if jobs.count > 200 {
            // Never a file change whose work still runs, so Quit waits for it (audit 19, B19-m5).
            jobs.removeAll {
                $0.state.isFinished && $0.finishedAt.map { Date().timeIntervalSince($0) > 3600 } ?? false
                    && !($0.kind == .organise && $0.task != nil && !$0.taskEnded)
            }
        }
    }

    func finish(_ job: Job, _ state: JobState, notify notifies: Bool = true) {
        // A job the person cancelled stays cancelled, even when its task then ends with an error.
        if job.state != .cancelled, !job.state.isFinished || state != .cancelled { job.state = state }
        let state = job.state
        job.finishedAt = Date()
        job.fraction = nil
        job.currentItem = nil
        let record = JobRecordInfo(id: job.id, kind: job.kind.rawValue, title: job.title, status: state.label, summary: job.summary,
                                   startedAt: job.startedAt, finishedAt: Date())
        if let store { Task { await store.recordJob(record) } }
        if notifies, notify(), Date().timeIntervalSince(job.startedAt) > 60 {
            Self.post(title: "\(job.kind.rawValue) finished: \(job.title)", body: job.summary.isEmpty ? state.label : job.summary)
        }
    }

    func clearFinished() {
        // A file change whose work still runs (a take-back after Cancel) stays listed, so Quit waits for it (audit 18,
        // B18-m1).
        jobs.removeAll { $0.state.isFinished && !($0.kind == .organise && $0.task != nil && !$0.taskEnded) }
    }

    nonisolated static func post(title: String, body: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
