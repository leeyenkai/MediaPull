import CoreServices
import Foundation

/// Watches folders and everything below them with FSEvents (R-1704), reporting changed folders in batches.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void
    private(set) var paths: [String] = []

    init(handler: @escaping ([String]) -> Void) {
        self.handler = handler
    }

    isolated deinit { stop() }

    /// Starts watching `paths`, replacing what was watched before. Events arrive on the main queue, at most once a second.
    func watch(_ paths: [String]) {
        let unique = Array(Set(paths)).sorted()
        guard unique != self.paths else { return }
        stop()
        self.paths = unique
        guard !unique.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
                                           copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let array = unsafeBitCast(eventPaths, to: NSArray.self)
            let changed = (0 ..< count).compactMap { array[$0] as? String }
            // The stream delivers on the main queue.
            MainActor.assumeIsolated {
                Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().handler(changed)
            }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(
            nil,
            callback,
            &context,
            unique as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(created, .main)
        FSEventStreamStart(created)
        stream = created
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        paths = []
    }
}
