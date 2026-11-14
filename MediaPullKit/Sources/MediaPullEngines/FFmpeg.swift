import Foundation
import MediaPullCore
import VideoToolbox

public struct VideoStreamInfo: Sendable, Equatable {
    public var videoCodec: String?
    public var audioCodec: String?
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    public var container: String?

    public init() {}

    public var needsReencodeForCompatibility: Bool {
        guard let codec = videoCodec?.lowercased() else { return false }
        return !["h264", "hevc", "h265", "avc1", "hvc1", "mpeg4", "prores"].contains(codec)
    }

    public var audioNeedsConversion: Bool {
        guard let codec = audioCodec?.lowercased() else { return false }
        return !["aac", "mp3", "alac", "ac3", "eac3"].contains(codec)
    }
}

public enum FFmpegError: LocalizedError {
    case missing
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .missing: "ffmpeg is not available in this copy of MediaPull."
        case let .failed(message): "Video conversion failed: \(message)"
        }
    }
}

/// Runs the bundled ffmpeg and ffprobe for single local operations (no network: SPEC R-507).
public struct FFmpeg: Sendable {
    public let ffmpeg: URL
    public let ffprobe: URL

    public init(paths: EnginePaths) {
        ffmpeg = paths.ffmpeg
        ffprobe = paths.ffprobe
    }

    public init(ffmpeg: URL, ffprobe: URL) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
    }

    public var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: ffmpeg.path) && FileManager.default.isExecutableFile(atPath: ffprobe.path)
    }

    /// Whether this Mac can decode AV1 (needed to re-encode AV1-only streams).
    public static var canDecodeAV1: Bool {
        VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    }

    public func probe(_ url: URL) async throws -> VideoStreamInfo {
        let output = try await Self.run(ffprobe, [
            "-v", "error", "-print_format", "json", "-show_streams", "-show_format", url.path,
        ])
        guard let data = output.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw FFmpegError.failed("ffprobe output could not be read") }
        var info = VideoStreamInfo()
        for stream in (json["streams"] as? [[String: Any]]) ?? [] {
            let type = stream["codec_type"] as? String
            if type == "video", info.videoCodec == nil, (stream["disposition"] as? [String: Any])?["attached_pic"] as? Int != 1 {
                info.videoCodec = stream["codec_name"] as? String
                info.width = stream["width"] as? Int
                info.height = stream["height"] as? Int
            } else if type == "audio", info.audioCodec == nil {
                info.audioCodec = stream["codec_name"] as? String
            }
        }
        if let format = json["format"] as? [String: Any] {
            info.duration = (format["duration"] as? String).flatMap(Double.init)
            info.container = format["format_name"] as? String
        }
        return info
    }

    /// Copies streams into an MP4 container without re-encoding.
    public func remuxToMP4(_ input: URL, output: URL, convertAudio: Bool) async throws {
        var args = ["-hide_banner", "-nostdin", "-y", "-i", input.path, "-map", "0:v:0?", "-map", "0:a:0?", "-c:v", "copy"]
        args += convertAudio ? ["-c:a", "aac_at", "-b:a", "256k"] : ["-c:a", "copy"]
        args += ["-movflags", "+faststart", "-f", "mp4", output.path]
        _ = try await Self.run(ffmpeg, args)
    }

    /// Re-encodes video to HEVC with the hardware encoder at high constant quality, tagged hvc1 so
    /// QuickTime and Photos play it (SPEC R-1607).
    public func transcodeToHEVC(_ input: URL, output: URL, convertAudio: Bool) async throws {
        var args = [
            "-hide_banner", "-nostdin", "-y", "-i", input.path, "-map", "0:v:0", "-map", "0:a:0?",
            "-c:v", "hevc_videotoolbox", "-q:v", "72", "-tag:v", "hvc1", "-pix_fmt", "yuv420p",
        ]
        args += convertAudio ? ["-c:a", "aac_at", "-b:a", "256k"] : ["-c:a", "copy"]
        args += ["-movflags", "+faststart", "-f", "mp4", output.path]
        _ = try await Self.run(ffmpeg, args)
    }

    /// Builds a GIF from a concat list of PNG frames with an optimized palette (SPEC R-1603).
    public func gif(fromConcatList list: URL, output: URL) async throws {
        _ = try await Self.run(ffmpeg, [
            "-hide_banner", "-nostdin", "-y", "-f", "concat", "-safe", "0", "-i", list.path,
            "-filter_complex", "split[a][b];[a]palettegen=stats_mode=diff:max_colors=256[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle",
            "-loop", "0", output.path,
        ])
    }

    /// Builds an MP4 (H.264, high quality) from a concat list of PNG frames.
    public func mp4(fromConcatList list: URL, output: URL) async throws {
        _ = try await Self.run(ffmpeg, [
            "-hide_banner", "-nostdin", "-y", "-f", "concat", "-safe", "0", "-i", list.path,
            "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2,format=yuv420p", "-c:v", "h264_videotoolbox", "-q:v", "80",
            "-movflags", "+faststart", output.path,
        ])
    }

    struct Output {
        var stdout: String
        var stderr: String
    }

    static func run(_ executable: URL, _ arguments: [String]) async throws -> Output {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw FFmpegError.missing }
        #if os(macOS)
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            box.set(process)
            process.executableURL = executable
            process.arguments = arguments
            process.environment = ["PATH": executable.deletingLastPathComponent().path]
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            let buffers = OutputBuffers()
            out.fileHandleForReading.readabilityHandler = { handle in buffers.appendOut(handle.availableData) }
            err.fileHandleForReading.readabilityHandler = { handle in buffers.appendErr(handle.availableData) }
            process.terminationHandler = { finished in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                buffers.appendOut(out.fileHandleForReading.readDataToEndOfFile())
                buffers.appendErr(err.fileHandleForReading.readDataToEndOfFile())
                let result = buffers.result()
                if box.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if finished.terminationStatus == 0 {
                    continuation.resume(returning: result)
                } else {
                    let last = result.stderr.split(whereSeparator: \.isNewline).suffix(2).joined(separator: " ")
                    continuation.resume(throwing: FFmpegError.failed(last.isEmpty ? "exit \(finished.terminationStatus)" : last))
                }
            }
            do {
                try process.run()
                if box.isCancelled { process.terminate() }
            } catch {
                continuation.resume(throwing: FFmpegError.failed(error.localizedDescription))
            }
            }
        } onCancel: {
            box.cancel()
        }
        #else
        throw FFmpegError.missing
        #endif
    }
}

final class OutputBuffers: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func appendOut(_ data: Data) {
        lock.withLock { out.append(data) }
    }

    func appendErr(_ data: Data) {
        lock.withLock {
            err.append(data)
            if err.count > 64 * 1024 { err.removeFirst(err.count - 64 * 1024) }
        }
    }

    func result() -> FFmpeg.Output {
        lock.withLock { FFmpeg.Output(stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self)) }
    }
}

#if os(macOS)
/// Lets a cancelled task stop the ffmpeg process it started.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func set(_ process: Process) {
        lock.withLock { self.process = process }
    }

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        let running = lock.withLock { () -> Process? in
            cancelled = true
            return process
        }
        if let running, running.isRunning { running.terminate() }
    }
}
#endif
