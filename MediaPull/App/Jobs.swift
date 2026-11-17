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
    var notes: [String] = []
    var failures: [(id: String, message: String)] = []
    var checkpointURL: URL?
    let startedAt = Date()
    var finishedAt: Date?
    var task: Task<Void, Never>?
    var retry: (() -> Void)?
    /// Where an Instagram listing had got to in this job, so Resume continues this job's own pass (R-1112).
    var lastCursor: String?
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
            jobs.removeAll { $0.state.isFinished && $0.finishedAt.map { Date().timeIntervalSince($0) > 3600 } ?? false }
        }
    }

    func finish(_ job: Job, _ state: JobState) {
        // A job the person cancelled stays cancelled, even when its task then ends with an error.
        if job.state != .cancelled, !job.state.isFinished || state != .cancelled { job.state = state }
        let state = job.state
        job.finishedAt = Date()
        job.fraction = nil
        job.currentItem = nil
        let record = JobRecordInfo(id: job.id, kind: job.kind.rawValue, title: job.title, status: state.label, summary: job.summary,
                                   startedAt: job.startedAt, finishedAt: Date())
        if let store { Task { await store.recordJob(record) } }
        if notify(), Date().timeIntervalSince(job.startedAt) > 60 {
            Self.post(title: "\(job.kind.rawValue) finished: \(job.title)", body: job.summary.isEmpty ? state.label : job.summary)
        }
    }

    func clearFinished() {
        jobs.removeAll { $0.state.isFinished }
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
