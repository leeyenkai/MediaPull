import Foundation
import MediaPullCore

/// What an audio source holds (ffprobe), so an export keeps its depth and its true length.
public struct AudioSourceFormat: Sendable, Equatable {
    public var duration: Double
    public var sampleRate: Int?
    public var bits: Int?
    public var codec: String?
    /// The codecs of the file's covers, in order.
    public var artworkCodecs: [String]

    public init(duration: Double, sampleRate: Int? = nil, bits: Int? = nil, codec: String? = nil, artworkCodecs: [String] = []) {
        self.duration = duration
        self.sampleRate = sampleRate
        self.bits = bits
        self.codec = codec
        self.artworkCodecs = artworkCodecs
    }
}

extension AudioOutput {
    /// Whether a cover of `codec` can be kept as it is: ID3 (MP3, AIFF) holds any picture; M4A and FLAC hold JPEG and PNG.
    func holdsCover(_ codec: String) -> Bool {
        switch self {
        case .mp3, .aiff: true
        default: ["mjpeg", "png"].contains(codec)
        }
    }
}

/// One audio export (R-4610, D-131): the parts kept, fades, volume, loudness, the format and the tags.
public struct AudioEditPlan: Sendable, Equatable {
    public var source: URL
    public var output: URL
    public var format: AudioOutput
    /// The parts kept, in seconds, merged and ordered; empty keeps the whole file, to its true end.
    public var kept: [TimeRange]
    /// The source's length by ffprobe (for fades out), and its codec and depth.
    public var sourceFormat: AudioSourceFormat?
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

    public init(source: URL, output: URL, recipe: EditRecipe, format sourceFormat: AudioSourceFormat) {
        let time = recipe.timeline ?? EditTimeline()
        let duration = sourceFormat.duration
        // Nothing cut: the whole file, never trimmed to a length that may be off. A part that reaches the end runs to the
        // true end (the last part's end is left open below).
        let kept = time.kept.isEmpty ? [] : time.keptRanges(duration: duration)
        self.init(source: source, output: output,
                  format: recipe.export.audioFormat ?? .like(source.pathExtension, codec: sourceFormat.codec), kept: kept)
        self.sourceFormat = sourceFormat
        fadeIn = time.fadeIn
        fadeOut = time.fadeOut
        volume = min(max(time.volume, 0), 4)
        normalize = time.normalize
        tags = recipe.tags ?? AudioTagEdit()
    }

    /// How long the result is.
    public var resultDuration: Double {
        kept.isEmpty ? (sourceFormat?.duration ?? 0) : kept.reduce(0) { $0 + $1.end - $1.start }
    }

    /// Whether a part is the last and ends at the file's measured end, so it is cut without an end and runs to the true
    /// end. Cuts use the measured length, so a part ending even 40 ms before it is cut there (audit 2026-11-21-8, C8-4).
    func reachesEnd(_ part: TimeRange) -> Bool {
        guard let total = sourceFormat?.duration, total > 0, part == kept.last else { return false }
        return part.end >= total - 0.002
    }

    var codec: String { sourceFormat?.codec?.lowercased() ?? "" }

    /// A floating-point PCM source.
    public var isFloat: Bool { codec.hasPrefix("pcm_f") }

    /// Only cuts (and tags), into the same lossy format: the frames are copied, not encoded again. MP3 and AAC only; a
    /// lossless format is encoded again losslessly, which cuts to the sample.
    public var copiesStreams: Bool {
        let ext = source.pathExtension.lowercased()
        // By codec where it is known: an M4A may hold Apple Lossless, which is not AAC.
        let isAAC = sourceFormat?.codec.map { $0.lowercased() == "aac" } ?? ["m4a", "aac"].contains(ext)
        let isMP3 = sourceFormat?.codec.map { $0.lowercased() == "mp3" } ?? (ext == "mp3")
        return fadeIn == 0 && fadeOut == 0 && volume == 1 && !normalize
            && (format == .mp3 && isMP3 || format == .aac && isAAC && ["m4a", "aac"].contains(ext))
    }
}

public enum AudioEdit {
    /// The sample rates the Mac's AAC encoder takes; a source above them is resampled (96 kHz to 48 kHz).
    public static let aacRates = "aformat=sample_rates=48000|44100|32000|24000|22050|16000"

    /// The rate an AAC export is written at: the source's when AAC takes it, else the next one up (at most 48 kHz).
    static func aacRate(for rate: Int) -> Int? {
        let rates = [16000, 22050, 24000, 32000, 44100, 48000]
        if rates.contains(rate) { return rate }
        return rates.first { $0 >= rate } ?? 48000
    }

    /// The concat list that cuts by stream copy: each part of the source with its in and out points.
    public static func concatList(_ plan: AudioEditPlan) -> String {
        var lines = ["ffconcat version 1.0"]
        let path = plan.source.path.replacingOccurrences(of: "'", with: "'\\''")
        for part in plan.kept {
            lines += ["file '\(path)'", String(format: "inpoint %.6f", part.start)]
            if !plan.reachesEnd(part) { lines.append(String(format: "outpoint %.6f", part.end)) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The filter graph: the parts trimmed and joined, then fades, volume and loudness.
    public static func filterGraph(_ plan: AudioEditPlan) -> String {
        var chains: [String] = []
        var labels: [String] = []
        for (index, part) in plan.kept.enumerated() {
            let end = plan.reachesEnd(part) ? "" : String(format: ":end=%.6f", part.end)
            chains.append(String(format: "[0:a:0]atrim=start=%.6f", part.start) + end + ",asetpts=PTS-STARTPTS[p\(index)]")
            labels.append("[p\(index)]")
        }
        var current: String
        if labels.isEmpty {
            current = "[0:a:0]"
        } else if labels.count == 1 {
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
        // A source above 48 kHz is resampled by name first: ffmpeg cannot choose a rate for AAC after a volume change
        // (audit 2026-11-21-9, C9-3).
        if plan.format == .aac {
            // Named for any rate AAC does not take, and never after loudness, which already gives 44.1 kHz (C10-2, C10-3).
            if !plan.normalize, let rate = plan.sourceFormat?.sampleRate, let wanted = aacRate(for: rate), wanted != rate {
                effects.append("aresample=\(wanted)")
            }
            effects.append(aacRates)
        }
        // Frames no longer than an encoder takes (loudness normalisation hands on one long frame; FLAC takes 65,535 samples).
        effects.append("asetnsamples=n=4096:p=0")
        chains.append(current + effects.joined(separator: ",") + "[out]")
        current = "[out]"
        return chains.joined(separator: ";")
    }

    /// ffmpeg's arguments for `plan`; `list` is the concat list's file when the streams are copied.
    public static func arguments(_ plan: AudioEditPlan, list: URL?) -> [String] {
        var args = ["-hide_banner", "-nostdin", "-v", "error", "-y"]
        let copying = plan.copiesStreams
        // Nothing cut: the file itself, its frames as they are (no concat list, which shifts them by a few milliseconds).
        let whole = plan.kept.isEmpty
        if copying, !whole, let list {
            args += ["-f", "concat", "-safe", "0", "-i", list.path, "-i", plan.source.path]
        } else {
            args += ["-i", plan.source.path]
        }
        // The original's tags and pictures come from the source file: input 1 when cutting by copy, else input 0.
        let original = copying && !whole && list != nil ? 1 : 0
        // Inputs so far: the concat list and the source when cutting by copy, else the source alone.
        var inputs = copying && !whole && list != nil ? 2 : 1
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
                // Cover art only: a picture track that is not one (chapter pictures in a podcast) cannot go into the
                // output (audit 2026-11-21-4, C4-3).
                // Each cover kept as it is where the output holds it; one it cannot (BMP or GIF in M4A or FLAC) is turned
                // into PNG, without loss (audit 2026-11-21-5, C5-1; round 6, C6-3).
                args += ["-map", "\(original):v:disp:attached_pic?", "-c:v", "copy"]
                for (index, codec) in (plan.sourceFormat?.artworkCodecs ?? []).enumerated() where !plan.format.holdsCover(codec) {
                    args += ["-c:v:\(index)", "png", "-disposition:v:\(index)", "attached_pic"]
                }
            }
        }
        args += ["-map_metadata", "\(original)"]
        // Ogg and Opus keep their tags on the stream, not the file.
        if ["ogg", "oga", "opus"].contains(plan.source.pathExtension.lowercased()) {
            args += ["-map_metadata:g", "\(original):s:a:0"]
        }
        // Chapters keep their times only when nothing is cut.
        if !whole { args += ["-map_chapters", "-1"] }
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
            // The source's depth is kept (16, 24 or 32-bit), and floating point stays floating point at its own width
            // (values over full scale are kept, not clipped).
            case .wav: args += ["-c:a", pcm(plan, endian: "le")]
            case .aiff: args += ["-c:a", pcm(plan, endian: "be")]
            }
        }
        switch plan.format {
        case .mp3: args += ["-id3v2_version", "3", "-write_id3v1", "1", "-f", "mp3"]
        case .aac, .alac: args += ["-f", "ipod"]
        case .flac: args += ["-f", "flac"]
        case .wav: args += ["-f", "wav"]
        case .aiff: args += ["-write_id3v2", "1", "-id3v2_version", "3", "-f", "aiff"]
        }
        args.append(plan.output.path)
        return args
    }

    /// The PCM encoder that keeps the source's depth (audit 2026-11-21-3, C3-7).
    static func pcm(_ plan: AudioEditPlan, endian: String) -> String {
        let bits = plan.sourceFormat?.bits ?? 16
        if plan.isFloat { return "pcm_f\(bits > 32 ? 64 : 32)\(endian)" }
        return "pcm_s\(bits > 24 ? 32 : bits > 16 ? 24 : 16)\(endian)"
    }

    /// The highest level in each of `buckets` equal slices of `samples`, 0 to 1.
    public static func peaks(_ samples: [Float], buckets: Int) -> [Float] {
        guard buckets > 0, !samples.isEmpty else { return [] }
        // Slice i covers samples i·n/b up to (i+1)·n/b, so the slices reach the end of the sound and each is drawn where it
        // is (audit 2026-11-21-7, C7-3).
        let count = min(buckets, samples.count)
        var out: [Float] = []
        out.reserveCapacity(count)
        for index in 0 ..< count {
            let start = index * samples.count / count, end = (index + 1) * samples.count / count
            var peak: Float = 0
            for value in samples[start ..< max(start + 1, end)] {
                peak = max(peak, abs(value))
            }
            out.append(min(peak, 1))
        }
        return out
    }
}

public extension FFmpeg {
    /// The audio's waveform as `buckets` peaks (R-4610): decoded to 2 kHz floats in a temporary file, every channel kept,
    /// so the peak is the loudest channel's (a mono mix would draw channels out of phase as silence, round 12, C12-3).
    /// Off the main actor: it reads the file and goes through every sample.
    @concurrent
    func waveform(_ url: URL, buckets: Int) async throws -> [Float] {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("MediaPull-wave-\(UUID().uuidString).f32")
        defer { try? FileManager.default.removeItem(at: raw) }
        _ = try await Self.run(ffmpeg, ["-hide_banner", "-nostdin", "-v", "error", "-y", "-i", url.path, "-map", "0:a:0",
                                        "-ar", "2000", "-f", "f32le", raw.path])
        let data = try Data(contentsOf: raw)
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return AudioEdit.peaks(samples, buckets: buckets)
    }

    /// Writes `plan` (R-4610); the output is removed when it fails or is cancelled.
    @concurrent
    func editAudio(_ plan: AudioEditPlan) async throws {
        var list: URL?
        var link: URL?
        if plan.copiesStreams, !plan.kept.isEmpty {
            let temporary = FileManager.default.temporaryDirectory
            var listed = plan
            // The list is read line by line, so a name with a line break is listed through a link of a plain name
            // (audit 2026-11-21-4, C4-7).
            if plan.source.path.contains(where: \.isNewline) {
                let plain = temporary.appendingPathComponent("MediaPull-cut-\(UUID().uuidString).\(plan.source.pathExtension)")
                try FileManager.default.createSymbolicLink(at: plain, withDestinationURL: plan.source)
                link = plain
                listed.source = plain
            }
            let file = temporary.appendingPathComponent("MediaPull-cut-\(UUID().uuidString).ffconcat")
            try AudioEdit.concatList(listed).write(to: file, atomically: true, encoding: .utf8)
            list = file
        }
        defer {
            if let list { try? FileManager.default.removeItem(at: list) }
            if let link { try? FileManager.default.removeItem(at: link) }
        }
        do {
            _ = try await Self.run(ffmpeg, AudioEdit.arguments(plan, list: list))
        } catch {
            try? FileManager.default.removeItem(at: plan.output)
            throw error
        }
    }
}
