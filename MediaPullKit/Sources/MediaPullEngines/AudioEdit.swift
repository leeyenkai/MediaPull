import Foundation
import MediaPullCore

/// One audio export (R-4610, D-131): the parts kept, fades, volume, loudness, the format and the tags.
public struct AudioEditPlan: Sendable, Equatable {
    public var source: URL
    public var output: URL
    public var format: AudioOutput
    /// The parts kept, in seconds, merged and ordered.
    public var kept: [TimeRange]
    public var fadeIn: Double = 0
    public var fadeOut: Double = 0
    public var volume: Double = 1
    public var normalize = false
    public var tags = AudioTagEdit()

    public init(source: URL, output: URL, format: AudioOutput, kept: [TimeRange]) {
        self.source = source
        self.output = output
        self.format = format
        self.kept = kept
    }

    public init(source: URL, output: URL, recipe: EditRecipe, duration: Double) {
        let time = recipe.timeline ?? EditTimeline()
        self.init(source: source, output: output, format: recipe.export.audioFormat ?? .like(source.pathExtension),
                  kept: time.keptRanges(duration: duration))
        fadeIn = time.fadeIn
        fadeOut = time.fadeOut
        volume = min(max(time.volume, 0), 4)
        normalize = time.normalize
        tags = recipe.tags ?? AudioTagEdit()
    }

    /// How long the result is.
    public var resultDuration: Double { kept.reduce(0) { $0 + $1.end - $1.start } }

    /// Only cuts (and tags), into the same lossy format: the frames are copied, not encoded again. MP3 and AAC only; a
    /// lossless format is encoded again losslessly, which cuts to the sample.
    public var copiesStreams: Bool {
        fadeIn == 0 && fadeOut == 0 && volume == 1 && !normalize
            && (format == .mp3 && source.pathExtension.lowercased() == "mp3"
                || format == .aac && ["m4a", "aac"].contains(source.pathExtension.lowercased()))
    }
}

public enum AudioEdit {
    /// The concat list that cuts by stream copy: each part of the source with its in and out points.
    public static func concatList(_ plan: AudioEditPlan) -> String {
        var lines = ["ffconcat version 1.0"]
        let path = plan.source.path.replacingOccurrences(of: "'", with: "'\\''")
        for part in plan.kept {
            lines += ["file '\(path)'", String(format: "inpoint %.6f", part.start), String(format: "outpoint %.6f", part.end)]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The filter graph: the parts trimmed and joined, then fades, volume and loudness.
    public static func filterGraph(_ plan: AudioEditPlan) -> String {
        var chains: [String] = []
        var labels: [String] = []
        for (index, part) in plan.kept.enumerated() {
            chains.append(String(format: "[0:a:0]atrim=start=%.6f:end=%.6f,asetpts=PTS-STARTPTS[p%d]", part.start, part.end, index))
            labels.append("[p\(index)]")
        }
        var current: String
        if labels.count == 1 {
            current = labels[0]
        } else {
            chains.append(labels.joined() + "concat=n=\(labels.count):v=0:a=1[joined]")
            current = "[joined]"
        }
        var effects: [String] = []
        let total = plan.resultDuration
        if plan.fadeIn > 0 { effects.append(String(format: "afade=t=in:st=0:d=%.3f", min(plan.fadeIn, total))) }
        if plan.fadeOut > 0 {
            let length = min(plan.fadeOut, total)
            effects.append(String(format: "afade=t=out:st=%.3f:d=%.3f", max(0, total - length), length))
        }
        if plan.volume != 1 { effects.append(String(format: "volume=%.3f", plan.volume)) }
        // Loudness normalisation works at 192 kHz; the result is brought back to 44.1 kHz, which every format takes.
        if plan.normalize { effects.append("loudnorm=I=-16:TP=-1.5:LRA=11,aresample=44100") }
        // Frames no longer than an encoder takes (loudness normalisation hands on one long frame; FLAC takes 65,535 samples).
        effects.append("asetnsamples=n=4096:p=0")
        chains.append(current + effects.joined(separator: ",") + "[out]")
        current = "[out]"
        return chains.joined(separator: ";")
    }

    /// ffmpeg's arguments for `plan`; `list` is the concat list's file when the streams are copied.
    public static func arguments(_ plan: AudioEditPlan, list: URL?) -> [String] {
        var args = ["-hide_banner", "-nostdin", "-v", "error", "-y"]
        let copying = plan.copiesStreams && list != nil
        if copying, let list {
            args += ["-f", "concat", "-safe", "0", "-i", list.path, "-i", plan.source.path]
        } else {
            args += ["-i", plan.source.path]
        }
        // The original's tags and pictures come from the source file: input 1 when copying, else input 0.
        let original = copying ? 1 : 0
        var inputs = copying ? 2 : 1
        let artwork = plan.format.holdsArtwork ? plan.tags.artworkPath : nil
        if let artwork {
            args += ["-i", artwork]
            inputs += 1
        }
        if copying {
            args += ["-map", "0:a:0"]
        } else {
            args += ["-filter_complex", filterGraph(plan), "-map", "[out]"]
        }
        if plan.format.holdsArtwork, !plan.tags.removeArtwork {
            if artwork != nil {
                args += ["-map", "\(inputs - 1):v:0", "-c:v", "copy", "-disposition:v:0", "attached_pic"]
            } else {
                args += ["-map", "\(original):v?", "-c:v", "copy"]
            }
        }
        args += ["-map_metadata", "\(original)"]
        for (key, value) in plan.tags.metadata {
            args += ["-metadata", "\(key)=\(value)"]
        }
        if copying {
            args += ["-c:a", "copy"]
        } else {
            switch plan.format {
            case .mp3: args += ["-c:a", "libmp3lame", "-q:a", "2"]
            case .aac: args += ["-c:a", "aac_at", "-b:a", "256k"]
            case .alac: args += ["-c:a", "alac"]
            case .flac: args += ["-c:a", "flac"]
            case .wav: args += ["-c:a", "pcm_s16le"]
            case .aiff: args += ["-c:a", "pcm_s16be"]
            }
        }
        switch plan.format {
        case .mp3: args += ["-id3v2_version", "3", "-write_id3v1", "1", "-f", "mp3"]
        case .aac, .alac: args += ["-f", "ipod"]
        case .flac: args += ["-f", "flac"]
        case .wav: args += ["-f", "wav"]
        case .aiff: args += ["-f", "aiff"]
        }
        args.append(plan.output.path)
        return args
    }

    /// The highest level in each of `buckets` equal slices of `samples`, 0 to 1.
    public static func peaks(_ samples: [Float], buckets: Int) -> [Float] {
        guard buckets > 0, !samples.isEmpty else { return [] }
        let size = max(1, samples.count / buckets)
        var out: [Float] = []
        out.reserveCapacity(buckets)
        var start = 0
        while start < samples.count, out.count < buckets {
            let end = min(samples.count, start + size)
            var peak: Float = 0
            for value in samples[start ..< end] {
                peak = max(peak, abs(value))
            }
            out.append(min(peak, 1))
            start = end
        }
        return out
    }
}

public extension FFmpeg {
    /// The audio's waveform as `buckets` peaks (R-4610): decoded to 2 kHz mono floats in a temporary file.
    func waveform(_ url: URL, buckets: Int) async throws -> [Float] {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("MediaPull-wave-\(UUID().uuidString).f32")
        defer { try? FileManager.default.removeItem(at: raw) }
        _ = try await Self.run(ffmpeg, ["-hide_banner", "-nostdin", "-v", "error", "-y", "-i", url.path, "-map", "0:a:0", "-ac", "1",
                                        "-ar", "2000", "-f", "f32le", raw.path])
        let data = try Data(contentsOf: raw)
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return AudioEdit.peaks(samples, buckets: buckets)
    }

    /// Writes `plan` (R-4610); the output is removed when it fails or is cancelled.
    func editAudio(_ plan: AudioEditPlan) async throws {
        var list: URL?
        if plan.copiesStreams {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("MediaPull-cut-\(UUID().uuidString).ffconcat")
            try AudioEdit.concatList(plan).write(to: file, atomically: true, encoding: .utf8)
            list = file
        }
        defer { if let list { try? FileManager.default.removeItem(at: list) } }
        do {
            _ = try await Self.run(ffmpeg, AudioEdit.arguments(plan, list: list))
        } catch {
            try? FileManager.default.removeItem(at: plan.output)
            throw error
        }
    }
}
