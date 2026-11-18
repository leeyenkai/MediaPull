import Foundation

/// Where the build scripts put the engines: `MEDIAPULL_ENGINE_CACHE`, as every script reads it, else the default cache
/// (audit 15, C15-m6).
enum TestEngines {
    static var cache: URL {
        if let custom = ProcessInfo.processInfo.environment["MEDIAPULL_ENGINE_CACHE"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/MediaPullBuild", isDirectory: true)
    }

    static var ffmpegFolder: URL { cache.appendingPathComponent("engines/ffmpeg", isDirectory: true) }
}
