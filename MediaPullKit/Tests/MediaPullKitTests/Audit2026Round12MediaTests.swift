/// Audit 2026-11-22, round 12 (auditor C): video and audio editing.
@preconcurrency import AVFoundation
import Foundation
@testable import MediaPullCore
@testable import MediaPullEdit
@testable import MediaPullEngines
import XCTest

extension VideoEditTests {
    /// A 4 s clip with a sound written from `fill` (per channel, per sample), in `format`, placed at `at` for `length`
    /// seconds of the sound (and optionally a second piece at `second`).
    @nonobjc func c12clip(format: AVAudioFormat, seconds: Double = 4, at: Double = 0, length: Double? = nil,
                          second: (at: Double, from: Double, length: Double)? = nil,
                          fill: (Int, Int) -> Float) async throws -> URL
    {
        let picture = AVURLAsset(url: try await clip())
        let sound = folder.appendingPathComponent("c12-\(UUID().uuidString).caf")
        let rate = format.sampleRate
        do {
            let file = try AVAudioFile(forWriting: sound, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * (seconds + 1)))!
            buffer.frameLength = buffer.frameCapacity
            for c in 0 ..< Int(format.channelCount) {
                for i in 0 ..< Int(buffer.frameLength) { buffer.floatChannelData![c][i] = fill(c, i) }
            }
            try file.write(from: buffer)
            file.close()
        }
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 4, preferredTimescale: 600))
        let v = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try v.insertTimeRange(range, of: try await picture.loadTracks(withMediaType: .video)[0], at: .zero)
        let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let soundAsset = AVURLAsset(url: sound)
        let source = try await soundAsset.loadTracks(withMediaType: .audio)[0]
        try a.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: length ?? seconds, preferredTimescale: 600)),
                              of: source, at: CMTime(seconds: at, preferredTimescale: 600))
        if let second {
            try a.insertTimeRange(CMTimeRange(start: CMTime(seconds: second.from, preferredTimescale: 600),
                                              duration: CMTime(seconds: second.length, preferredTimescale: 600)),
                                  of: source, at: CMTime(seconds: second.at, preferredTimescale: 600))
        }
        let output = folder.appendingPathComponent("c12-\(UUID().uuidString).mov")
        let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        try await session.export(to: output, as: .mov)
        withExtendedLifetime(soundAsset) {}
        return output
    }

    @nonobjc func c12export(_ source: URL, speed: Double, kept: [TimeRange] = [], fadeIn: Double = 0, fadeOut: Double = 0,
                            volume: Double = 1, ext: String = "mov") async throws -> URL
    {
        var edit = recipe(source)
        edit.adjust.exposure = 0.01
        var time = EditTimeline()
        time.speed = speed
        time.kept = kept
        time.fadeIn = fadeIn
        time.fadeOut = fadeOut
        time.volume = volume
        edit.timeline = time
        let out = folder.appendingPathComponent("c12-out-\(UUID().uuidString).\(ext)")
        _ = try await VideoComposer.export(source, recipe: edit, to: out) { _ in }
        return out
    }

    /// Root mean square of a stretch of a channel.
    @nonobjc func c12rms(_ s: [Float], rate: Double, from: Double, to: Double) -> Double {
        let a = max(0, Int(from * rate)), b = min(s.count, Int(to * rate))
        guard b > a else { return 0 }
        var sum = 0.0
        for i in a ..< b { sum += Double(s[i] * s[i]) }
        return (sum / Double(b - a)).squareRoot()
    }

    /// Times where a channel's loud bursts begin.
    @nonobjc func c12onsets(_ s: [Float], rate: Double, threshold: Float = 0.2) -> [Double] {
        var out: [Double] = []
        var last = -1.0
        for (i, v) in s.enumerated() where abs(v) > threshold {
            let t = Double(i) / rate
            if t - last > 0.15 { out.append(t) }
            last = t
        }
        return out
    }

    /// Sound with more than two channels in layouts other than 5.1 at another speed: kept, channel for channel, or
    /// refused with a reason (never a crash). 7.1 is in `testC12SurroundChannelsStayInTheirPlaces`.
    func testC12OtherChannelLayoutsAtSpeed() async throws {
        let layouts: [(String, AudioChannelLayoutTag)] = [
            // 3.0 is read in the encoder's order (C L R) and checked by label in `testC12SurroundChannelsStayInTheirPlaces`.
            ("quad", kAudioChannelLayoutTag_Quadraphonic),
            ("discrete4", kAudioChannelLayoutTag_DiscreteInOrder | 4),
            ("ambisonic4", kAudioChannelLayoutTag_HOA_ACN_SN3D | 4),
        ]
        var problems: [String] = []
        for (name, tag) in layouts {
            let layout = AVAudioChannelLayout(layoutTag: tag)!
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
            let channels = Int(format.channelCount)
            let source = try await c12clip(format: format) { c, i in
                c == 0 ? Float(sin(Double(i) * 2 * .pi * 1000 / 48000) * 0.5)
                    : c == channels - 1 ? Float(sin(Double(i) * 2 * .pi * 600 / 48000) * 0.5) : 0
            }
            for speed in [2.0, 0.5] {
                do {
                    let out = try await c12export(source, speed: speed)
                    let got = try await c11readSound(out)
                    if got.channels != channels { problems.append("\(name) \(speed)x: \(got.channels) channels, not \(channels)") }
                    let mid = got.samples[0].count / 2
                    let f0 = c11frequency(got.samples[0][mid - 4800 ..< mid + 4800], rate: got.rate)
                    if abs(f0 - 1000) > 30 { problems.append(String(format: "%@ %.1fx: first channel %.0f Hz", name, speed, f0)) }
                    if got.channels == channels {
                        let fl = c11frequency(got.samples[channels - 1][mid - 4800 ..< mid + 4800], rate: got.rate)
                        if abs(fl - 600) > 30 { problems.append(String(format: "%@ %.1fx: last channel %.0f Hz", name, speed, fl)) }
                    }
                } catch {
                    problems.append("\(name) \(speed)x: throws \(error.localizedDescription)")
                }
            }
        }
        XCTAssertTrue(problems.isEmpty, "\(problems)")
    }

    /// Reads a file's first sound with the channels remapped by label into `layout`, and gives each channel's frequency.
    @nonobjc func c12frequencies(_ url: URL, in layout: AVAudioChannelLayout) async throws -> [Int] {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .audio)[0]
        let reader = try AVAssetReader(asset: asset)
        let n = Int(layout.channelCount)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                                       AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: n,
                                       AVSampleRateKey: 48000, AVChannelLayoutKey: SoundAtSpeed.data(of: layout)]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        reader.startReading()
        var ch = [[Float]](repeating: [], count: n)
        while let b = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(b) else { continue }
            let len = CMBlockBufferGetDataLength(block)
            var d = [Float](repeating: 0, count: len / 4)
            _ = d.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len / 4 * 4,
                                                                      destination: $0.baseAddress!) }
            for i in 0 ..< d.count { ch[i % n].append(d[i]) }
        }
        let mid = ch[0].count / 2
        return (0 ..< n).map { Int(c11frequency(ch[$0][mid - 4800 ..< mid + 4800], rate: 48000).rounded()) }
    }

    /// Each channel of a 5.1 or 7.1 sound stays at its own place (by label) in a re-encoded export, at normal speed and
    /// at another speed, as Play Result plays it: front left stays front left, the LFE stays the LFE.
    func testC12SurroundChannelsStayInTheirPlaces() async throws {
        var problems: [String] = []
        let ffmpeg = FFmpeg(ffmpeg: TestEngines.ffmpegFolder.appendingPathComponent("ffmpeg"),
                            ffprobe: TestEngines.ffmpegFolder.appendingPathComponent("ffprobe"))
        for (name, tag) in [("5.1 L R C LFE Ls Rs", kAudioChannelLayoutTag_MPEG_5_1_A), ("7.1 L R C LFE Ls Rs Rls Rrs",
                                                                                         kAudioChannelLayoutTag_MPEG_7_1_C),
                            ("3.0 L R C", kAudioChannelLayoutTag_MPEG_3_0_A), ("quad", kAudioChannelLayoutTag_Quadraphonic),
                            ("5.0 L R C Ls Rs", kAudioChannelLayoutTag_MPEG_5_0_A)] {
            let layout = AVAudioChannelLayout(layoutTag: tag)!
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
            let n = Int(format.channelCount)
            // Channel k carries a tone of 200 + 100k Hz; the LFE (index 3) a 100 Hz tone, which its low-pass keeps.
            let tones = (0 ..< n).map { $0 == 3 && n >= 6 ? 100 : 200 + 100 * $0 }
            let mov = try await c12clip(format: format) { c, i in Float(sin(Double(i) * 2 * .pi * Double(tones[c]) / 48000) * 0.3) }
            var sources = [("LPCM MOV", mov)]
            if ffmpeg.isAvailable, n == 6 {
                let mp4 = folder.appendingPathComponent("aac-\(n).mp4")
                _ = try await FFmpeg.run(ffmpeg.ffmpeg, ["-hide_banner", "-nostdin", "-v", "error", "-y", "-i", mov.path, "-c:v", "copy",
                                                         "-c:a", "aac", "-b:a", "384k", mp4.path])
                sources.append(("AAC MP4", mp4))
            }
            for (kind, source) in sources {
                let before = try await c12frequencies(source, in: layout)
                for speed in [1.0, 2.0] {
                    let out = try await c12export(source, speed: speed, ext: "mov")
                    let got = try await c12frequencies(out, in: layout)
                    // 7.1's rear pair has no place in the AAC encoder's 7.1 (recorded, audit 2026-11-21-12): the other six
                    // channels are checked there.
                    let checked = n == 8 ? 6 : n
                    let wrong = zip(before, got).prefix(checked).enumerated().filter { abs($0.element.0 - $0.element.1) > 15 }
                    if !wrong.isEmpty {
                        problems.append("\(name) \(kind) at \(speed)x: source \(before), export \(got)")
                    }
                }
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    /// Cancel while the picture is encoded (normal speed, and the second half at another speed) is reported as a Cancel,
    /// promptly, with nothing left behind.
    func testC12CancelWhileEncodingIsACancel() async throws {
        let base = AVURLAsset(url: try await clip())
        let composition = AVMutableComposition()
        let v = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 4, preferredTimescale: 600))
        let pv = try await base.loadTracks(withMediaType: .video)[0], pa = try await base.loadTracks(withMediaType: .audio)[0]
        for i in 0 ..< 30 {
            try v.insertTimeRange(range, of: pv, at: CMTime(seconds: Double(i) * 4, preferredTimescale: 600))
            try a.insertTimeRange(range, of: pa, at: CMTime(seconds: Double(i) * 4, preferredTimescale: 600))
        }
        let long = folder.appendingPathComponent("long.mov")
        let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        try await session.export(to: long, as: .mov)
        var problems: [String] = []
        for speed in [1.0, 2.0] {
            var edit = recipe(long)
            edit.adjust.exposure = 0.01
            var time = EditTimeline()
            time.speed = speed
            edit.timeline = time
            let out = folder.appendingPathComponent("long-\(speed).mov")
            final class Box: @unchecked Sendable { let lock = NSLock(); var last = 0.0 }
            let box = Box()
            let task = Task { try await VideoComposer.export(long, recipe: edit, to: out) { v in box.lock.withLock { box.last = v } } }
            // Into the encoding of the picture.
            while box.lock.withLock({ box.last }) < (speed == 1 ? 0.05 : 0.55) { try await Task.sleep(for: .milliseconds(20)) }
            let cancelled = Date()
            task.cancel()
            let result = await task.result
            let took = Date().timeIntervalSince(cancelled)
            switch result {
            case .success: problems.append("\(speed)x: finished after Cancel")
            case let .failure(error) where !(error is CancellationError):
                problems.append("\(speed)x: Cancel reported as a failure: \(error.localizedDescription)")
            default: break
            }
            if took > 2 { problems.append("\(speed)x: Cancel took \(took) s") }
            if FileManager.default.fileExists(atPath: out.path) { problems.append("\(speed)x: a partial file is left") }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    /// High sample rates (96 and 192 kHz) at another speed and at normal speed export, keep pitch and end on time.
    func testC12HighRatesAtSpeed() async throws {
        var problems: [String] = []
        for rate in [96000.0, 192_000] {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            let source = try await c12clip(format: format) { _, i in Float(sin(Double(i) * 2 * .pi * 1000 / rate) * 0.5) }
            for speed in [1.0, 2.0, 0.5] {
                for ext in ["mov", "mp4"] {
                    do {
                        let out = try await c12export(source, speed: speed, ext: ext)
                        let got = try await c11readSound(out)
                        let mid = got.samples[0].count / 2
                        let f = c11frequency(got.samples[0][mid - 4800 ..< mid + 4800], rate: got.rate)
                        if abs(f - 1000) > 30 { problems.append(String(format: "%.0f Hz %.1fx %@: %.0f Hz", rate, speed, ext, f)) }
                        let length = 4 / speed
                        let tail = c12rms(got.samples[0], rate: got.rate, from: length - 0.06, to: length - 0.01)
                        if tail < 0.2 { problems.append(String(format: "%.0f Hz %.1fx %@: end lost", rate, speed, ext)) }
                    } catch {
                        problems.append("\(rate) \(speed)x \(ext): throws \(error.localizedDescription)")
                    }
                }
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    /// Sound that starts late and has a gap, at another speed: each piece at its own time divided by the speed.
    func testC12LateAndGappedSoundAtSpeed() async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        // Clicks at 0.2 s and 1.2 s of the sound; the sound placed at 1 s (0.2 + 1 = 1.2 s), then from 1.0 s of the sound
        // at 2.8 s (the click at 1.2 s of the sound heard at 3.0 s).
        let source = try await c12clip(format: format, at: 1, length: 0.5, second: (at: 2.8, from: 1.0, length: 0.6)) { _, i in
            let t = Double(i) / 48000
            return (abs(t - 0.2) < 0.01 || abs(t - 1.2) < 0.01) ? Float(sin(Double(i) * 2 * .pi * 1000 / 48000) * 0.8) : 0
        }
        let original = try await c11readSound(source)
        let due = c12onsets(original.samples[0], rate: original.rate)
        XCTAssertEqual(due.count, 2, "fixture: \(due)")
        var problems: [String] = []
        for speed in [0.5, 2.0, 4.0] {
            let out = try await c12export(source, speed: speed)
            let got = try await c11readSound(out)
            let heard = c12onsets(got.samples[0], rate: got.rate)
            if heard.count != due.count { problems.append("\(speed)x: heard \(heard), due \(due.map { $0 / speed })"); continue }
            for (h, d) in zip(heard, due.map { $0 / speed }) where abs(h - d) > 0.03 {
                problems.append(String(format: "%.2fx: due %.3f heard %.3f", speed, d, h))
            }
        }
        XCTAssertTrue(problems.isEmpty, "\(problems)")
    }

    /// Fades and volume at another speed, over a steady tone: silent at the ends, half way at the volume in the middle.
    func testC12FadesAndVolumeAtSpeed() async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let source = try await c12clip(format: format) { _, i in Float(sin(Double(i) * 2 * .pi * 440 / 48000) * 0.5) }
        var problems: [String] = []
        for speed in [0.5, 2.0] {
            let out = try await c12export(source, speed: speed, fadeIn: 0.5, fadeOut: 0.5, volume: 0.5)
            let got = try await c11readSound(out)
            let length = 4 / speed
            let start = c12rms(got.samples[0], rate: got.rate, from: 0, to: 0.02)
            let middle = c12rms(got.samples[0], rate: got.rate, from: length / 2 - 0.1, to: length / 2 + 0.1)
            let end = c12rms(got.samples[0], rate: got.rate, from: length - 0.03, to: length)
            // A 0.5 sine is 0.354 RMS; at volume 0.5, 0.177.
            if abs(middle - 0.177) > 0.03 { problems.append(String(format: "%.1fx: middle %.3f RMS", speed, middle)) }
            if start > 0.03 { problems.append(String(format: "%.1fx: start %.3f RMS", speed, start)) }
            if end > 0.03 { problems.append(String(format: "%.1fx: end %.3f RMS", speed, end)) }
            let d = try await AVURLAsset(url: out).load(.duration).seconds
            if abs(d - length) > 0.05 { problems.append("\(speed)x: \(d) s long, not \(length)") }
        }
        XCTAssertTrue(problems.isEmpty, "\(problems)")
    }

    /// Cuts at another speed: each click at the time of the parts kept before it, divided by the speed.
    func testC12CutsAtSpeed() async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let clicks = [0.5, 2.5, 3.5]
        let source = try await c12clip(format: format) { _, i in
            let t = Double(i) / 44100
            return clicks.contains { t >= $0 && t < $0 + 0.02 } ? Float(sin(Double(i) * 2 * .pi * 1000 / 44100) * 0.8) : 0
        }
        let kept = [TimeRange(start: 0, end: 1), TimeRange(start: 2, end: 4)]
        var problems: [String] = []
        for speed in [0.5, 2.0] {
            let out = try await c12export(source, speed: speed, kept: kept, ext: "mp4")
            let got = try await c11readSound(out)
            let heard = c12onsets(got.samples[0], rate: got.rate)
            let due = [0.5, 1.5, 2.5].map { $0 / speed }
            if heard.count != due.count { problems.append("\(speed)x: heard \(heard), due \(due)"); continue }
            for (h, d) in zip(heard, due) where abs(h - d) > 0.03 {
                problems.append(String(format: "%.2fx: due %.3f heard %.3f", speed, d, h))
            }
        }
        XCTAssertTrue(problems.isEmpty, "\(problems)")
    }

    /// A low rate (8 kHz and 22.05 kHz mono) at speed keeps its pitch, and a 5.1 AAC MP4 (as cameras and downloads have)
    /// keeps its channels.
    func testC12LowRatesAndAACFiveOneAtSpeed() async throws {
        var problems: [String] = []
        for rate in [8000.0, 22050] {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            let source = try await c12clip(format: format) { _, i in Float(sin(Double(i) * 2 * .pi * 1000 / rate) * 0.5) }
            for speed in [0.25, 4.0] {
                let out = try await c12export(source, speed: speed)
                let got = try await c11readSound(out)
                let mid = got.samples[0].count / 2
                let window = min(mid - 1, Int(got.rate * 0.1))
                let f = c11frequency(got.samples[0][mid - window ..< mid + window], rate: got.rate)
                if abs(f - 1000) > 30 { problems.append(String(format: "%.0f Hz %.2fx: %.0f Hz", rate, speed, f)) }
                let length = 4 / speed
                let tail = c12rms(got.samples[0], rate: got.rate, from: length - 0.06, to: length - 0.01)
                if tail < 0.2 { problems.append(String(format: "%.0f Hz %.2fx: end lost (%.3f RMS)", rate, speed, tail)) }
            }
        }
        let ffmpeg = FFmpeg(ffmpeg: TestEngines.ffmpegFolder.appendingPathComponent("ffmpeg"),
                            ffprobe: TestEngines.ffmpegFolder.appendingPathComponent("ffprobe"))
        if ffmpeg.isAvailable {
            let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)!
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
            let mov = try await c12clip(format: format) { c, i in
                c == 0 ? Float(sin(Double(i) * 2 * .pi * 1000 / 48000) * 0.5)
                    : c == 5 ? Float(sin(Double(i) * 2 * .pi * 600 / 48000) * 0.5) : 0
            }
            let mp4 = folder.appendingPathComponent("aac51.mp4")
            _ = try await FFmpeg.run(ffmpeg.ffmpeg, ["-hide_banner", "-nostdin", "-v", "error", "-y", "-i", mov.path, "-c:v", "copy",
                                                     "-c:a", "aac", "-b:a", "384k", mp4.path])
            for speed in [2.0, 0.5] {
                do {
                    let out = try await c12export(mp4, speed: speed, ext: "mp4")
                    let got = try await c11readSound(out)
                    if got.channels != 6 { problems.append("AAC 5.1 \(speed)x: \(got.channels) channels") }
                } catch { problems.append("AAC 5.1 \(speed)x: throws \(error.localizedDescription)") }
            }
        }
        XCTAssertTrue(problems.isEmpty, "\(problems)")
    }

    /// No temporary sound file is left after an export at speed, nor after one that fails after the sound was rendered.
    func testC12NoTemporarySoundLeftAfterExportOrFailure() async throws {
        let tmp = FileManager.default.temporaryDirectory
        func leftovers() -> Set<String> {
            Set(((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []).filter { $0.hasPrefix("MediaPull-sound-") })
        }
        let before = leftovers()
        let source = try await clip()
        _ = try await c12export(source, speed: 2)
        // Into a folder that is not there: the sound is rendered, then the export fails.
        var edit = recipe(source)
        edit.adjust.exposure = 0.01
        var time = EditTimeline()
        time.speed = 2
        edit.timeline = time
        let nowhere = folder.appendingPathComponent("missing/out.mov")
        do {
            _ = try await VideoComposer.export(source, recipe: edit, to: nowhere) { _ in }
        } catch {}
        XCTAssertTrue(leftovers().subtracting(before).isEmpty, "\(leftovers().subtracting(before))")
    }

    /// Progress at another speed only goes up, from the sound's render to the picture's.
    func testC12ProgressAtSpeedOnlyRises() async throws {
        let source = try await clip()
        var edit = recipe(source)
        edit.adjust.exposure = 0.01
        var time = EditTimeline()
        time.speed = 0.5
        edit.timeline = time
        let out = folder.appendingPathComponent("progress.mov")
        final class Box: @unchecked Sendable { let lock = NSLock(); var values: [Double] = [] }
        let box = Box()
        _ = try await VideoComposer.export(source, recipe: edit, to: out) { v in box.lock.withLock { box.values.append(v) } }
        let values = box.lock.withLock { box.values }
        let drops = zip(values, values.dropFirst()).filter { $1 + 1e-9 < $0 }
        XCTAssertTrue(drops.isEmpty, "progress went back: \(drops.prefix(5))")
        XCTAssertEqual(values.last ?? 0, 1, accuracy: 1e-9)
    }

    /// Cuts only: neither the picture nor the sound is encoded again.
    func testC12CutsOnlyKeepTheSoundsSamples() async throws {
        let source = try await clip()
        var edit = recipe(source)
        var time = EditTimeline()
        time.kept = [TimeRange(start: 0, end: 4)]
        edit.timeline = time
        edit.geometry.quarterTurns = 1
        let out = folder.appendingPathComponent("cut.mov")
        let built = try await VideoComposer.export(source, recipe: edit, to: out) { _ in }
        XCTAssertTrue(built.lossless)
        func audioDigest(_ url: URL) async throws -> (String, FourCharCode) {
            let asset = AVURLAsset(url: url)
            let track = try await asset.loadTracks(withMediaType: .audio)[0]
            let codec = CMFormatDescriptionGetMediaSubType(try await track.load(.formatDescriptions)[0])
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            reader.startReading()
            var count = 0
            var bytes = 0
            while let b = output.copyNextSampleBuffer() {
                count += CMSampleBufferGetNumSamples(b)
                bytes += CMSampleBufferGetTotalSampleSize(b)
            }
            return ("\(count)/\(bytes)", codec)
        }
        let a = try await audioDigest(source), b = try await audioDigest(out)
        XCTAssertEqual(a.1, b.1, "the sound's codec is kept")
        XCTAssertEqual(a.0, b.0, "the sound's samples are copied")
    }
}

/// Audio exports through the bundled ffmpeg (R-4610, D-131).
final class Audit2026Round12AudioTests: XCTestCase {
    var folder: URL!
    let ffmpeg = FFmpeg(ffmpeg: TestEngines.ffmpegFolder.appendingPathComponent("ffmpeg"),
                        ffprobe: TestEngines.ffmpegFolder.appendingPathComponent("ffprobe"))

    override func setUpWithError() throws {
        try XCTSkipUnless(ffmpeg.isAvailable, "ffmpeg is not built")
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("C12Audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// A tone WAV (or other) file: `rate`, `channels`, ffmpeg's PCM codec.
    @nonobjc func tone(_ name: String, rate: Int, channels: Int = 2, codec: String = "pcm_s16le", seconds: Double = 3,
                       extra: [String] = [], opposite: Bool = false) async throws -> URL
    {
        let caf = folder.appendingPathComponent("\(name)-src.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: AVAudioChannelCount(channels))!
        let file = try AVAudioFile(forWriting: caf, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                                               AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 32,
                                                               AVLinearPCMIsFloatKey: true])
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(rate) * seconds))!
        buffer.frameLength = buffer.frameCapacity
        for c in 0 ..< channels {
            for i in 0 ..< Int(buffer.frameLength) {
                buffer.floatChannelData![c][i] = Float(sin(Double(i) * 2 * .pi * 440 / Double(rate)) * 0.3) * (opposite && c == 1 ? -1 : 1)
            }
        }
        try file.write(from: buffer)
        // ffmpeg has no CAF demuxer: through AVFoundation to WAV float first.
        let wav = folder.appendingPathComponent("\(name)-float.wav")
        let out = try AVAudioFile(forWriting: wav, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                                              AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 32,
                                                              AVLinearPCMIsFloatKey: true])
        try out.write(from: buffer)
        let target = folder.appendingPathComponent(name)
        if codec == "u8" {
            let u8 = try AVAudioFile(forWriting: target, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                                                    AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 8,
                                                                    AVLinearPCMIsFloatKey: false])
            try u8.write(from: buffer)
            return target
        }
        _ = try await FFmpeg.run(ffmpeg.ffmpeg, ["-hide_banner", "-nostdin", "-v", "error", "-y", "-i", wav.path] + extra
            + ["-c:a", codec, target.path])
        return target
    }

    @nonobjc func streams(_ url: URL) async throws -> [[String: Any]] {
        let out = try await FFmpeg.run(ffmpeg.ffprobe, ["-v", "error", "-print_format", "json", "-show_streams", "-show_format", url.path])
        let json = try JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any]
        return (json?["streams"] as? [[String: Any]]) ?? []
    }

    @nonobjc func export(_ source: URL, to format: AudioOutput, _ body: (inout EditTimeline, inout AudioTagEdit) -> Void = { _, _ in })
        async throws -> URL
    {
        var recipe = EditRecipe(source: EditSource(path: source.path, kind: .audio))
        var time = EditTimeline()
        var tags = AudioTagEdit()
        body(&time, &tags)
        recipe.timeline = time
        recipe.tags = tags
        recipe.export.audioFormat = format
        let measured = await ffmpeg.audioFormat(source)
        let info = try XCTUnwrap(measured)
        let out = folder.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)-\(format.rawValue)."
            + format.fileExtension)
        try await ffmpeg.editAudio(AudioEditPlan(source: source, output: out, recipe: recipe, format: info))
        return out
    }

    /// High-resolution sources (96 and 192 kHz) into MP3 with a change of volume, and float and 32-bit sources into FLAC
    /// and Apple Lossless: every pairing writes a file.
    func testC12RatesAndDepthsIntoEveryFormat() async throws {
        let sources: [(String, Int, String)] = [
            ("hi96.wav", 96000, "pcm_s24le"), ("hi192.flac", 192_000, "flac"), ("f32.wav", 48000, "pcm_f32le"),
            ("s32.wav", 48000, "pcm_s32le"), ("f64.aiff", 44100, "pcm_f64be"), ("low8k.wav", 8000, "pcm_s16le"),
            ("u8.wav", 11025, "u8"),
        ]
        var problems: [String] = []
        for (name, rate, codec) in sources {
            let source = try await tone(name, rate: rate, codec: codec)
            for format in AudioOutput.allCases {
                for variant in ["plain", "volume", "normalize"] {
                    do {
                        let out = try await export(source, to: format) { time, _ in
                            if variant == "volume" { time.volume = 0.7 }
                            if variant == "normalize" { time.normalize = true }
                            time.fadeIn = 0.2
                        }
                        let s = try await streams(out).first { $0["codec_type"] as? String == "audio" }
                        let d = (s?["duration"] as? String).flatMap(Double.init)
                        if let d, abs(d - 3) > 0.1 { problems.append("\(name) → \(format) \(variant): \(d) s") }
                    } catch {
                        problems.append("\(name) → \(format) \(variant): \(error.localizedDescription)")
                    }
                }
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    /// Every tag the Export tab offers is written into every format that holds it, and artwork where it can be held.
    func testC12TagsAndArtworkInEveryFormat() async throws {
        let source = try await tone("tags.wav", rate: 44100)
        let png = folder.appendingPathComponent("cover.png")
        _ = try await FFmpeg.run(ffmpeg.ffmpeg, ["-hide_banner", "-nostdin", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24",
                                                 "-s", "8x8", "-i", "/dev/zero", "-frames:v", "1", png.path])
        var problems: [String] = []
        for format in AudioOutput.allCases {
            let out = try await export(source, to: format) { _, tags in
                tags.title = "T1"; tags.artist = "A1"; tags.album = "B1"; tags.albumArtist = "AA1"; tags.year = "2021"
                tags.genre = "G1"; tags.track = "7"; tags.artworkPath = png.path
            }
            let read = await ffmpeg.audioTags(out)
            guard let tags = read?.tags else { problems.append("\(format): unreadable"); continue }
            if tags.title != "T1" { problems.append("\(format): title \(tags.title ?? "nil")") }
            if tags.artist != "A1" { problems.append("\(format): artist \(tags.artist ?? "nil")") }
            if tags.album != "B1" { problems.append("\(format): album \(tags.album ?? "nil")") }
            if format.holdsAlbumArtist, tags.albumArtist != "AA1" {
                problems.append("\(format): album artist \(tags.albumArtist ?? "nil")")
            }
            if tags.year != 2021 { problems.append("\(format): year \(tags.year.map(String.init) ?? "nil")") }
            if tags.genre != "G1" { problems.append("\(format): genre \(tags.genre ?? "nil")") }
            if tags.track != 7 { problems.append("\(format): track \(tags.track.map(String.init) ?? "nil")") }
            let covers = try await streams(out).filter { ($0["disposition"] as? [String: Any])?["attached_pic"] as? Int == 1 }
            if format.holdsArtwork, covers.count != 1 { problems.append("\(format): \(covers.count) covers") }
            // The system reads the cover too (Finder, Music).
            if format.holdsArtwork, format != .flac {
                let items = try await AVURLAsset(url: out).load(.commonMetadata)
                if !items.contains(where: { $0.commonKey == .commonKeyArtwork }) { problems.append("\(format): the system sees no cover") }
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    /// Cuts that only copy keep the MP3 and AAC frames, and the result is as long as the parts kept (within a frame).
    func testC12CopyCutsKeepTheirLength() async throws {
        let wav = try await tone("cut.wav", rate: 44100, seconds: 8)
        var problems: [String] = []
        for (ext, codec) in [("mp3", "libmp3lame"), ("m4a", "aac_at")] {
            let source = folder.appendingPathComponent("cut-src.\(ext)")
            _ = try await FFmpeg.run(ffmpeg.ffmpeg, ["-hide_banner", "-nostdin", "-v", "error", "-y", "-i", wav.path, "-c:a", codec,
                                                     source.path])
            let out = try await export(source, to: ext == "mp3" ? .mp3 : .aac) { time, _ in
                time.kept = [TimeRange(start: 1, end: 2.5), TimeRange(start: 4, end: 6)]
            }
            let measured = await ffmpeg.audioFormat(out)
            let d = measured?.duration ?? 0
            if abs(d - 3.5) > 0.06 { problems.append("\(ext): \(d) s, not 3.5") }
            let info = try await streams(out).first { $0["codec_type"] as? String == "audio" }
            if (info?["codec_name"] as? String) != (ext == "mp3" ? "mp3" : "aac") {
                problems.append("\(ext): \(info?["codec_name"] ?? "?")")
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    /// The waveform of a stereo file whose channels are opposite (a wide recording) is not drawn as silence.
    func testC12WaveformOfOppositeChannels() async throws {
        let wav = try await tone("wide.wav", rate: 44100, codec: "pcm_s16le", opposite: true)
        let peaks = try await ffmpeg.waveform(wav, buckets: 10)
        XCTAssertGreaterThan(peaks.max() ?? 0, 0.2, "\(peaks)")
    }

    /// A file's first sound as mono floats at its rate, decoded by ffmpeg (priming and padding removed as players do).
    @nonobjc func decoded(_ url: URL, rate: Int = 44100) async throws -> [Float] {
        let raw = folder.appendingPathComponent("dec-\(UUID().uuidString).f32")
        _ = try await FFmpeg.run(ffmpeg.ffmpeg, ["-hide_banner", "-nostdin", "-v", "error", "-y", "-i", url.path, "-map", "0:a:0", "-ac",
                                                 "1",
                                                 "-ar", "\(rate)", "-f", "f32le", raw.path])
        let data = try Data(contentsOf: raw)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// A 6 s WAV, silent but for 20 ms clicks at `clicks`, 44.1 kHz stereo 16-bit.
    @nonobjc func clicks(_ name: String, at clicks: [Double], level: Float = 0.8) async throws -> URL {
        let rate = 44100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let wav = folder.appendingPathComponent(name)
        let file = try AVAudioFile(forWriting: wav, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                                               AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                                                               AVLinearPCMIsFloatKey: false])
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 6))!
        buffer.frameLength = buffer.frameCapacity
        for click in clicks {
            for i in 0 ..< Int(rate * 0.02) {
                for c in 0 ..< 2 {
                    buffer.floatChannelData![c][Int(click * rate) + i] = Float(sin(Double(i) * 2 * .pi * 1000 / rate)) * level
                }
            }
        }
        try file.write(from: buffer)
        file.close()
        return wav
    }

    func onsets(_ s: [Float], rate: Double) -> [Double] {
        var out: [Double] = []
        var last = -1.0
        for (i, v) in s.enumerated() where abs(v) > 0.2 {
            let t = Double(i) / rate
            if t - last > 0.15 { out.append(t) }
            last = t
        }
        return out
    }

    /// A fade out reaches silence at the very end of the result in every format, whatever the source's priming.
    func testC12FadeOutEndsSilentAtTheEnd() async throws {
        let wav = try await tone("steady.wav", rate: 44100, seconds: 5)
        var sources: [(URL, AudioOutput)] = [(wav, .wav), (wav, .mp3), (wav, .aac), (wav, .flac)]
        for (ext, codec) in [("mp3", "libmp3lame"), ("m4a", "aac_at")] {
            let encoded = folder.appendingPathComponent("steady-src.\(ext)")
            _ = try await FFmpeg.run(ffmpeg.ffmpeg, ["-hide_banner", "-nostdin", "-v", "error", "-y", "-i", wav.path, "-c:a", codec,
                                                     "-b:a", "192k", encoded.path])
            sources.append((encoded, ext == "mp3" ? .mp3 : .aac))
        }
        var problems: [String] = []
        for (source, format) in sources {
            for kept in [[], [TimeRange(start: 1, end: 4)]] {
                let out = try await export(source, to: format) { time, _ in
                    time.kept = kept
                    time.fadeOut = 1
                }
                let s = try await decoded(out)
                let tail = s.suffix(Int(44100 * 0.03))
                let peak = tail.map { abs($0) }.max() ?? 0
                let full = s.dropLast(Int(44100 * 1.2)).suffix(4410).map { abs($0) }.max() ?? 0
                if peak > 0.03 {
                    problems.append(String(format: "%@ → %@ kept %@: last 30 ms peak %.3f (full level %.3f)", source.lastPathComponent,
                                           format.rawValue, kept.isEmpty ? "all" : "1-4", peak, full))
                }
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }
}
