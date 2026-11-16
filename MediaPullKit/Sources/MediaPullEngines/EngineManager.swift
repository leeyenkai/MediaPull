import Foundation
import MediaPullCore
import MediaPullNet

public struct EngineVersions: Sendable, Equatable {
    public var python: String?
    public var galleryDL: String?
    public var ytDLP: String?
    public var ffmpeg: String?
}

public struct EngineUpdate: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var current: String
    public var available: String
    public var wheelURL: URL
    public var sha256: String
    public var blockedReason: String?
}

public enum EngineUpdateError: LocalizedError {
    case hashMismatch
    case installFailed(String)
    case selfTestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .hashMismatch: "The downloaded update did not match its published checksum and was discarded."
        case let .installFailed(message): "The update could not be installed: \(message)"
        case let .selfTestFailed(message): "The updated engine failed its self-test, so the previous version stays active: \(message)"
        }
    }
}

/// Engine versions, self-tests and updates from PyPI (SPEC 13.6).
public actor EngineManager {
    public nonisolated let paths: EnginePaths
    private let client: BridgeClient
    private let gate: NetworkGate
    public static let updatable = ["gallery-dl", "yt-dlp"]
    /// Pure-Python dependencies bundled with the app, with their versions.
    static let bundledDependencies: [String: String] = [
        "requests": "2.34.2", "urllib3": "2.8.0", "idna": "3.20", "charset-normalizer": "3.5.2", "certifi": "2026.10.23",
    ]

    public init(paths: EnginePaths, gate: NetworkGate = .shared) {
        self.paths = paths
        client = BridgeClient(paths: paths)
        self.gate = gate
    }

    public var bridge: BridgeClient { client }

    public func versions() async throws -> EngineVersions {
        let events = try await client.collect(BridgeRequest(op: "hello"))
        for event in events {
            if case let .hello(info) = event {
                return EngineVersions(python: info["python"], galleryDL: info["gallery_dl"], ytDLP: info["yt_dlp"], ffmpeg: info["ffmpeg"])
            }
        }
        throw BridgeError.launchFailed("No version information")
    }

    /// Runs the bridge self-test and returns problems, empty when all is well.
    public func selfTest() async -> [String] {
        do {
            let events = try await client.collect(BridgeRequest(op: "selftest"))
            return events.compactMap { event in
                if case let .error(_, message, _, true) = event { return message }
                return nil
            }
        } catch {
            return [error.localizedDescription]
        }
    }

    // MARK: Updates

    public func checkForUpdates() async throws -> [EngineUpdate] {
        let current = try await versions()
        var updates: [EngineUpdate] = []
        for name in Self.updatable {
            let installed = (name == "gallery-dl" ? current.galleryDL : current.ytDLP) ?? "0"
            guard let url = URL(string: "https://pypi.org/pypi/\(name)/json") else { continue }
            let (data, response) = try await gate.data(.get(url, purpose: .engineUpdate,
                                                            context: RequestContext(accept: "application/json")))
            guard response.statusCode == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let info = json["info"] as? [String: Any], let latest = info["version"] as? String,
                  let files = json["urls"] as? [[String: Any]]
            else { continue }
            guard Self.compare(latest, installed) == .orderedDescending else { continue }
            guard let wheel = files.first(where: { ($0["filename"] as? String)?.hasSuffix("py3-none-any.whl") ?? false }),
                  let wheelURL = (wheel["url"] as? String).flatMap(URL.init(string:)),
                  let sha = (wheel["digests"] as? [String: Any])?["sha256"] as? String
            else { continue }
            let requires = (info["requires_dist"] as? [String]) ?? []
            updates.append(EngineUpdate(
                name: name, current: installed, available: latest, wheelURL: wheelURL, sha256: sha,
                blockedReason: Self.unmetDependency(requires)
            ))
        }
        return updates
    }

    public func install(_ update: EngineUpdate) async throws {
        paths.prepareFolders()
        let key = update.name.replacingOccurrences(of: "-", with: "_")
        let download = paths.updates.appendingPathComponent("downloads/\(update.wheelURL.lastPathComponent)")
        _ = try await gate.download(.get(update.wheelURL, purpose: .engineUpdate), to: download)
        defer { try? FileManager.default.removeItem(at: download) }
        guard try FileHasher.sha256(of: download) == update.sha256.lowercased() else { throw EngineUpdateError.hashMismatch }
        // The version comes from the package index and names a folder that is replaced, so it must be a plain version string.
        guard !update.available.isEmpty, update.available.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".+-_".contains($0)) }),
              !update.available.hasPrefix(".")
        else { throw EngineUpdateError.installFailed("the update has an unexpected version number") }
        let target = paths.updates.appendingPathComponent("\(key)/\(update.available)", isDirectory: true)
        try? FileManager.default.removeItem(at: target)
        var request = BridgeRequest(op: "install_wheel")
        request.wheel = download.path
        request.target = target.path
        let events = try await client.collect(request)
        if let message = Self.fatalMessage(events) {
            try? FileManager.default.removeItem(at: target)
            throw EngineUpdateError.installFailed(message)
        }
        var active = readActive()
        let previous = active[key]
        active[key] = ActiveEngine(version: update.available, path: target.path, previousVersion: previous?.version,
                                   previousPath: previous?.path)
        try writeActive(active)
        let problems = await selfTest()
        if !problems.isEmpty {
            active[key] = previous
            try writeActive(active)
            try? FileManager.default.removeItem(at: target)
            throw EngineUpdateError.selfTestFailed(problems.joined(separator: "; "))
        }
        cleanOldVersions(key: key, keep: [active[key]?.path, active[key]?.previousPath].compactMap(\.self))
    }

    public func usePreviousVersions() throws {
        var active = readActive()
        for (key, engine) in active {
            if let previousPath = engine.previousPath, let previousVersion = engine.previousVersion {
                active[key] = ActiveEngine(version: previousVersion, path: previousPath)
            } else {
                active[key] = nil
            }
        }
        try writeActive(active)
    }

    public func resetToBuiltIn() throws {
        try? FileManager.default.removeItem(at: paths.activeFile)
        for key in ["gallery_dl", "yt_dlp"] {
            try? FileManager.default.removeItem(at: paths.updates.appendingPathComponent(key))
        }
    }

    public func hasUpdatesInstalled() -> Bool {
        !readActive().isEmpty
    }

    private func readActive() -> [String: ActiveEngine] {
        guard let data = try? Data(contentsOf: paths.activeFile) else { return [:] }
        return (try? JSONDecoder().decode([String: ActiveEngine].self, from: data)) ?? [:]
    }

    private func writeActive(_ active: [String: ActiveEngine]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(active).write(to: paths.activeFile, options: .atomic)
    }

    private func cleanOldVersions(key: String, keep: [String]) {
        let folder = paths.updates.appendingPathComponent(key)
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where !keep.contains(entry.path) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    static func fatalMessage(_ events: [BridgeEvent]) -> String? {
        for event in events {
            if case let .error(_, message, _, true) = event { return message }
        }
        return nil
    }

    /// Version comparison for dotted numeric versions ("1.32.19", "2026.10.26").
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let left = a.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let right = b.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        for index in 0 ..< max(left.count, right.count) {
            let x = index < left.count ? left[index] : 0
            let y = index < right.count ? right[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// The first required (non-extra) dependency the bundled runtime cannot satisfy.
    static func unmetDependency(_ requirements: [String]) -> String? {
        for requirement in requirements where !requirement.contains("extra ==") {
            let spec = requirement.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let name = String(spec.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." })
                .lowercased().replacingOccurrences(of: "_", with: "-")
            guard !name.isEmpty else { continue }
            guard let bundled = bundledDependencies[name] else {
                return "Needs \(name), which this version of MediaPull does not include. Update MediaPull instead."
            }
            for clause in spec.dropFirst(name.count).split(separator: ",") {
                let text = clause.trimmingCharacters(in: .whitespaces)
                if text.hasPrefix(">=") {
                    let minimum = String(text.dropFirst(2))
                    if compare(bundled, minimum) == .orderedAscending {
                        return "Needs \(name) \(minimum) or later. Update MediaPull instead."
                    }
                }
            }
        }
        return nil
    }
}
