import SwiftUI

/// The Activity window (SPEC section 19).
struct ActivityView: View {
    private var app: AppModel { .shared }

    var body: some View {
        VStack(spacing: 0) {
            if let message = app.engines.gateMessage {
                Banner(symbol: "exclamationmark.shield.fill", tint: .orange, text: message) {
                    Button("Resume") { Task { await app.engines.resumeAfterCheckpoint() } }
                }
            }
            // R-1306: updates are only announced; installing stays the person's choice (D-20).
            let updates = app.engineUpdates.filter { $0.blockedReason == nil }
            if !updates.isEmpty {
                Banner(symbol: "arrow.down.app", tint: .accentColor,
                       text: "Engine update available: " + updates.map { "\($0.name) \($0.available)" }.joined(separator: ", ")) {
                    SettingsLink { Text("Show") }
                }
            }
            if app.jobs.jobs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("No activity yet").font(.headline)
                    Text("Saves, Instagram pulls and conversions appear here.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(app.jobs.jobs) { job in
                    JobRow(job: job)
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Text(app.jobs.activeCount == 0 ? "Nothing running" : "\(app.jobs.activeCount) running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear Finished") { app.jobs.clearFinished() }
                    .disabled(!app.jobs.jobs.contains { $0.state.isFinished })
            }
            .padding(8)
        }
        .frame(minWidth: 460, minHeight: 320)
    }
}

struct JobRow: View {
    @Bindable var job: Job
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: symbol).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.title).font(.body.weight(.medium)).lineLimit(1)
                    if !job.subtitle.isEmpty {
                        Text(job.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                actions
            }
            if job.state.isActive {
                if let progress = job.progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            HStack(spacing: 6) {
                if case let .waiting(until, _) = job.state {
                    // R-1902: waiting shows a countdown, updated each second.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let left = max(0, Int(until.timeIntervalSince(context.date).rounded(.up)))
                        Text("\(job.state.label) · \(left / 60):\(String(format: "%02d", left % 60)) left").foregroundStyle(stateColor)
                    }
                } else {
                    Text(job.state.label).foregroundStyle(stateColor)
                }
                if !job.summary.isEmpty { Text("·"); Text(job.summary) }
                if let item = job.currentItem, job.state.isActive { Text("·"); Text(item).lineLimit(1).truncationMode(.middle) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !job.failures.isEmpty || !job.notes.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(job.failures.prefix(40).enumerated()), id: \.offset) { _, failure in
                            Text(failure.message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        }
                        ForEach(Array(Set(job.notes)).sorted().prefix(20), id: \.self) { note in
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } label: {
                    Text("Details").font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if let url = job.destination, job.saved + job.duplicates > 0 {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }.accessibilityLabel("Show in Finder")
                    .help("Show in Finder")
            }
            if case .blocked = job.state, let resume = job.resume {
                Button("Resume") { resume() }
            }
            if let toggle = job.pauseToggle, job.state.isActive || job.state == .paused {
                Button { toggle() } label: { Image(systemName: job.state == .paused ? "play.circle" : "pause.circle") }.accessibilityLabel(job.state == .paused ? "Resume" : "Pause")
                    .help(job.state == .paused ? "Resume" : "Pause")
            }
            if job.state.canCancel {
                Button { job.cancel() } label: { Image(systemName: "xmark.circle") }.accessibilityLabel("Cancel Job")
                    .help("Cancel")
            } else if job.failed > 0, let retry = job.retry {
                Button("Retry Failed") { retry() }
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private var symbol: String {
        switch job.kind {
        case .save: "square.and.arrow.down"
        case .pull: "person.crop.rectangle.stack"
        case .scan: "magnifyingglass"
        case .stream: "film"
        case .convert: "arrow.triangle.2.circlepath"
        case .engineUpdate: "arrow.down.app"
        case .analyse: "sparkle.magnifyingglass"
        case .organise: "folder.badge.gearshape"
        }
    }

    private var tint: Color {
        switch job.state {
        case .failed: .red
        case .blocked: .orange
        case .completed: .green
        default: .accentColor
        }
    }

    private var stateColor: Color {
        switch job.state {
        case .failed: .red
        case .blocked: .orange
        default: .secondary
        }
    }
}
