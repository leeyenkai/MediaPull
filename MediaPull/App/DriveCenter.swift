import AppKit
import MediaPullCore
import MediaPullEngines
import MediaPullLibrary

/// Drives plugged into the Mac (section 43): listed as they come and go, ejected on request, camera cards offered to
/// Devices. Shared by every window.
@Observable
final class DriveCenter {
    private(set) var drives: [DriveInfo] = []
    /// Every mounted volume's folder, so a pane can tell that the drive its folder was on went away.
    private(set) var mounted: Set<String> = []
    @ObservationIgnored let volumes = VolumeTable(url: SelfTestRunner.isActive ? nil
        : EnginePaths.defaultSupport.appendingPathComponent("volumes.json"))
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    private var app: AppModel { .shared }

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    isolated deinit {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// Reads the mounted drives off the main actor; watching and analysis follow the change.
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let (found, all) = await Task.detached(priority: .userInitiated) { () -> ([DriveInfo], Set<String>) in
                let all = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
                return (Volumes.drives(), Set(all.map(\.standardizedFileURL.path)))
            }.value
            guard let self, !Task.isCancelled else { return }
            self.volumes.note(found)
            let changed = found != self.drives
            self.drives = found
            self.mounted = all
            if changed {
                self.app.deviceCenter.drivesChanged(found)
                self.app.analysis.updateWatch()
            }
        }
    }

    /// Whether `url` is on a drive that is no longer mounted (R-4301).
    func isOnMissingDrive(_ url: URL) -> Bool {
        guard let mount = Volumes.mountPoint(of: url.standardizedFileURL.path) else { return false }
        return !mounted.contains(mount)
    }

    /// The drive holding `url`, if it is one of the listed drives.
    func drive(containing url: URL) -> DriveInfo? {
        let path = url.standardizedFileURL.path
        return drives.first { path == $0.url.path || path.hasPrefix($0.url.path + "/") }
    }

    /// Stops watching the drive, then ejects it; a drive another app holds stays, and the person is told (R-4302).
    func eject(_ drive: DriveInfo) {
        app.analysis.updateWatch(excluding: drive.url)
        Task { [weak self] in
            do {
                try await FileManager.default.unmountVolume(at: drive.url, options: [.allPartitionsAndEjectDisk])
            } catch {
                let holder = ((error as NSError).userInfo[NSFileManagerUnmountDissentingProcessIdentifierErrorKey] as? NSNumber)
                    .flatMap { NSRunningApplication(processIdentifier: $0.int32Value)?.localizedName }
                let text = holder.map { "“\(drive.name)” could not be ejected: \($0) is using it." }
                    ?? "“\(drive.name)” could not be ejected: \(error.localizedDescription)"
                // Said where the person asked for it: Organise.
                for window in self?.app.windows ?? [] {
                    window.organise.message = text
                }
                self?.app.analysis.updateWatch()
            }
            self?.refresh()
        }
    }
}
