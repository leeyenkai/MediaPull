import AppKit
import Foundation
import MediaPullNet

/// Export Diagnostics (R-511, D-77): one plain-text file the person saves where they choose and can read before sharing.
/// It holds versions, settings, the state of analysis, recent jobs and the network activity log; never cookies, keys,
/// passwords, media or file contents.
extension AppModel {
    func diagnosticsReport() async -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var lines = [
            "MediaPull diagnostics, \(Date().formatted(.iso8601))",
            "Version \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?")), macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "",
            "Engines: Python \(engineVersions?.python ?? "?"), gallery-dl \(engineVersions?.galleryDL ?? "?"), "
                + "yt-dlp \(engineVersions?.ytDLP ?? "?"), ffmpeg \(engineVersions?.ffmpeg ?? "?")",
        ]
        if !engineProblems.isEmpty { lines.append("Engine problems: " + engineProblems.joined(separator: "; ")) }
        if let message = engineMessage { lines.append("Message: \(message)") }
        lines += ["", "Library folders: \(roots.count) (\(missingRoots.count) not found); layouts: "
            + roots.map(\.layout.rawValue).joined(separator: ", ")]
        lines.append("Analysis: \(preferences.analysisEnabled ? "on" : "off"), \(analysis.analysedCount) files analysed, "
            + "faces \(preferences.facesEnabled ? "on" : "off")" + (analysis.storeProblem.map { "; \($0)" } ?? ""))
        lines.append("Instagram: \(engines.signedIn ? "signed in" : "signed out"); pacing \(preferences.pacing.rawValue)")
        lines += ["", "Recent jobs:"]
        for job in jobs.jobs.prefix(50) {
            lines.append("  \(job.startedAt.formatted(.iso8601))  \(job.kind.rawValue)  \(job.title)  \(job.state.label)"
                + (job.summary.isEmpty ? "" : "  (\(job.summary))"))
            for failure in job.failures.prefix(5) {
                lines.append("      \(failure.message)")
            }
        }
        lines += ["", "Network activity (MediaPull's own requests, newest last; all GET or HEAD):"]
        for entry in await gate.entries().suffix(300) {
            lines.append("  \(entry.time.formatted(.iso8601))  \(entry.method)  \(entry.host)\(entry.path)  "
                + "\(entry.purpose.rawValue)  \(entry.status.map(String.init) ?? "-")")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MediaPull Diagnostics \(Date().formatted(.iso8601.year().month().day())).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let text = await diagnosticsReport()
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                engineMessage = "The diagnostics file could not be saved: \(error.localizedDescription)"
            }
        }
    }
}
