import Foundation
import MediaPullCore
import MediaPullNet
import os

/// Where the bundled engine runtime lives, and MediaPull's own engine folders.
public struct EnginePaths: Sendable {
    public var python: URL
    public var bridgeDirectory: URL
    public var baselineSitePackages: URL
    public var helpers: URL
    public var support: URL

    public var bridge: URL { bridgeDirectory.appendingPathComponent("mediapull_bridge.py") }
    public var ffmpeg: URL { helpers.appendingPathComponent("ffmpeg") }
    public var ffprobe: URL { helpers.appendingPathComponent("ffprobe") }
    public var engineHome: URL { support.appendingPathComponent("EngineHome", isDirectory: true) }
    public var staging: URL { support.appendingPathComponent("Staging", isDirectory: true) }
    public var updates: URL { support.appendingPathComponent("Engines", isDirectory: true) }
    public var activeFile: URL { updates.appendingPathComponent("active.json") }

    public init(python: URL, bridgeDirectory: URL, baselineSitePackages: URL, helpers: URL, support: URL) {
        self.python = python
        self.bridgeDirectory = bridgeDirectory
        self.baselineSitePackages = baselineSitePackages
        self.helpers = helpers
        self.support = support
    }

    public static var defaultSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MediaPull", isDirectory: true)
    }

    /// The engines inside the app bundle, falling back to the development build cache.
    public static func locate(bundle: Bundle = .main) -> EnginePaths? {
        let fileManager = FileManager.default
        if let resources = bundle.resourceURL {
            let engines = resources.appendingPathComponent("Engines", isDirectory: true)
            let python = engines.appendingPathComponent("python/bin/python3")
            let helpers = bundle.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
            if fileManager.isExecutableFile(atPath: python.path) {
                return EnginePaths(
                    python: python, bridgeDirectory: engines.appendingPathComponent("bridge", isDirectory: true),
                    baselineSitePackages: engines.appendingPathComponent("site-packages", isDirectory: true), helpers: helpers,
                    support: defaultSupport
                )
            }
        }
        return developmentPaths()
    }

    public static func developmentPaths(repository: URL? = nil) -> EnginePaths? {
        let cache = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/MediaPullBuild/engines")
        let python = cache.appendingPathComponent("python/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return nil }
        var bridge = repository?.appendingPathComponent("Engines/bridge")
        if bridge == nil, let root = ProcessInfo.processInfo.environment["MEDIAPULL_REPO"] {
            bridge = URL(fileURLWithPath: root).appendingPathComponent("Engines/bridge")
        }
        if bridge == nil {
            var url = URL(fileURLWithPath: #filePath)
            for _ in 0 ..< 5 {
                url.deleteLastPathComponent()
            }
            bridge = url.appendingPathComponent("Engines/bridge")
        }
        guard let bridge else { return nil }
        return EnginePaths(
            python: python, bridgeDirectory: bridge, baselineSitePackages: cache.appendingPathComponent("site-packages"),
            helpers: cache.appendingPathComponent("ffmpeg"), support: defaultSupport
        )
    }

    /// Engine folders to put first on the Python path: updated engines, then the built-in ones.
    public func pythonPaths() -> [String] {
        var paths = [bridgeDirectory.path]
        if let data = try? Data(contentsOf: activeFile),
           let active = try? JSONDecoder().decode([String: ActiveEngine].self, from: data)
        {
            for (_, engine) in active.sorted(by: { $0.key < $1.key }) where FileManager.default.fileExists(atPath: engine.path) {
                paths.append(engine.path)
            }
        }
        paths.append(baselineSitePackages.path)
        return paths
    }

    public func prepareFolders() {
        for folder in [support, engineHome, staging, updates] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }
}

public struct ActiveEngine: Codable, Sendable {
    public var version: String
    public var path: String
    public var previousVersion: String?
    public var previousPath: String?
}

public enum BridgeError: LocalizedError {
    case enginesMissing
    case launchFailed(String)
    case crashed(Int32, String)

    public var errorDescription: String? {
        switch self {
        case .enginesMissing: "The download engines are not installed in this copy of MediaPull."
        case let .launchFailed(reason): "The download engine could not start: \(reason)"
        case let .crashed(code, tail): "The download engine stopped unexpectedly (\(code)).\(tail.isEmpty ? "" : " \(tail)")"
        }
    }
}

/// Runs one bridge process per job and streams its events (SPEC 13.3).
public final class BridgeClient: Sendable {
    /// Set once: a write to a pipe whose reader has gone then fails with EPIPE instead of ending the app.
    static let ignoreBrokenPipes: Void = { signal(SIGPIPE, SIG_IGN) }()
    public let paths: EnginePaths
    static let log = Logger(subsystem: "app.mediapull", category: "engine")

    public init(paths: EnginePaths) {
        self.paths = paths
    }

    public func run(_ request: BridgeRequest, workingDirectory: URL? = nil) -> AsyncThrowingStream<BridgeEvent, Error> {
        var request = request
        request.paths = paths.pythonPaths()
        let paths = paths
        return AsyncThrowingStream { continuation in
            #if !os(macOS)
            continuation.finish(throwing: BridgeError.enginesMissing)
            #else
            paths.prepareFolders()
            let process = Process()
            process.executableURL = paths.python
            process.arguments = ["-I", "-u", paths.bridge.path]
            let workDir = workingDirectory ?? paths.engineHome
            try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            process.currentDirectoryURL = workDir
            process.environment = [
                "HOME": paths.engineHome.path,
                "XDG_CONFIG_HOME": paths.engineHome.path,
                "XDG_CACHE_HOME": paths.engineHome.appendingPathComponent("cache").path,
                "PATH": paths.helpers.path,
                "TMPDIR": workDir.path + "/",
                "PYTHONDONTWRITEBYTECODE": "1",
                "PYTHONIOENCODING": "utf-8",
                "LANG": "en_US.UTF-8",
                "MEDIAPULL_HELPERS": paths.helpers.path,
            ]
            let input = Pipe()
            let output = Pipe()
            let errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            let stderrTail = OSAllocatedUnfairLock(initialState: "")
            errors.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let text = String(decoding: data, as: UTF8.self)
                stderrTail.withLock { tail in
                    tail = String((tail + text).suffix(4000))
                }
                for line in text.split(whereSeparator: \.isNewline) {
                    Self.log.debug("\(String(line), privacy: .private)")
                }
            }
            let sawDone = OSAllocatedUnfairLock(initialState: false)
            let (exitStream, exitContinuation) = AsyncStream.makeStream(of: Int32.self)
            process.terminationHandler = { finished in
                exitContinuation.yield(finished.terminationStatus)
                exitContinuation.finish()
            }
            do {
                try process.run()
            } catch {
                continuation.finish(throwing: BridgeError.launchFailed(error.localizedDescription))
                return
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            if let data = try? encoder.encode(request) {
                // A bridge that exits before reading must not take the app down with SIGPIPE or an exception.
                _ = BridgeClient.ignoreBrokenPipes
                try? input.fileHandleForWriting.write(contentsOf: data)
            }
            try? input.fileHandleForWriting.close()

            // The stream ends only after every line was read and the process has exited, so the
            // last events (a file, done) are never lost to a fast exit.
            let reader = Task.detached {
                do {
                    for try await line in output.fileHandleForReading.bytes.lines {
                        guard let event = BridgeEvent.decode(line) else {
                            // A line that cannot be read may have been a file or the job's result: never drop it silently.
                            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                                continuation.yield(.error(code: "bad_event", message: "The engine sent a message MediaPull could not read.",
                                                          key: nil, fatal: false))
                            }
                            continue
                        }
                        if case .done = event { sawDone.withLock { $0 = true } }
                        continuation.yield(event)
                    }
                } catch {}
                var status: Int32 = 0
                for await code in exitStream {
                    status = code
                }
                errors.fileHandleForReading.readabilityHandler = nil
                if sawDone.withLock({ $0 }) || status == 0 {
                    continuation.finish()
                } else {
                    let tail = stderrTail.withLock { $0 }
                    let lastLine = tail.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
                    continuation.finish(throwing: BridgeError.crashed(status, lastLine))
                }
            }
            continuation.onTermination = { termination in
                reader.cancel()
                guard case .cancelled = termination, process.isRunning else { return }
                let pid = process.processIdentifier
                process.interrupt()
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    if process.isRunning { process.terminate() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                        if process.isRunning { kill(pid, SIGKILL) }
                    }
                }
            }
            #endif
        }
    }

    /// Runs a request to completion and returns all events.
    public func collect(_ request: BridgeRequest, workingDirectory: URL? = nil) async throws -> [BridgeEvent] {
        var events: [BridgeEvent] = []
        for try await event in run(request, workingDirectory: workingDirectory) {
            events.append(event)
        }
        return events
    }
}

/// Writes and reads Netscape-format cookie files for the engines (SPEC R-1103, R-512).
public enum CookieFile {
    public static func write(_ cookies: [CookieRecord], to url: URL) throws {
        var lines = ["# Netscape HTTP Cookie File", "# Written by MediaPull for one job; deleted when the job ends.", ""]
        for cookie in cookies {
            let domain = cookie.domain
            let includeSubdomains = domain.hasPrefix(".") ? "TRUE" : "FALSE"
            let expires = cookie.expires.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
            let prefix = cookie.isHTTPOnly ? "#HttpOnly_" : ""
            let fields = [
                prefix + domain, includeSubdomains, cookie.path.isEmpty ? "/" : cookie.path, cookie.isSecure ? "TRUE" : "FALSE",
                expires, cookie.name, cookie.value,
            ]
            lines.append(fields.joined(separator: "\t"))
        }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // The folder is 0700, so the file is private even before its own permissions are set.
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func read(_ url: URL) -> [CookieRecord] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var cookies: [CookieRecord] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = String(raw)
            var httpOnly = false
            if line.hasPrefix("#HttpOnly_") {
                httpOnly = true
                line.removeFirst("#HttpOnly_".count)
            } else if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7 else { continue }
            let expires = Double(fields[4]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            cookies.append(CookieRecord(
                name: fields[5], value: fields[6...].joined(separator: "\t"), domain: fields[0], path: fields[2],
                isSecure: fields[3] == "TRUE", isHTTPOnly: httpOnly, expires: expires
            ))
        }
        return cookies
    }

    /// A fresh private folder for one job's cookie file.
    public static func privateLocation(job: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaPull-cookies", isDirectory: true)
            .appendingPathComponent(job, isDirectory: true)
            .appendingPathComponent("cookies.txt")
    }

    public static func cleanUpAll() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MediaPull-cookies", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
    }
}
