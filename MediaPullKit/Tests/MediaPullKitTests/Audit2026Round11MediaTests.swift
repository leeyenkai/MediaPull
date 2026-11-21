/// Audit 2026-11-21, round 11: sound at another speed keeps every channel, its pitch and its time; tiny parts; Cancel.
@preconcurrency import AVFoundation
import Foundation
@testable import MediaPullCore
@testable import MediaPullEdit
import XCTest

/// Reads a file's first sound track as float PCM at its own rate and channels.
func c11readSound(_ url: URL) async throws -> (rate: Double, channels: Int, samples: [[Float]]) {
    let asset = AVURLAsset(url: url)
    let track = try await asset.loadTracks(withMediaType: .audio)[0]
    let description = try await track.load(.formatDescriptions)[0]
    let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)!.pointee
    let reader = try AVAssetReader(asset: asset)
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    reader.add(output)
    reader.startReading()
    let channels = Int(basic.mChannelsPerFrame)
    var samples = [[Float]](repeating: [], count: channels)
    while let buffer = output.copyNextSampleBuffer() {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
        let length = CMBlockBufferGetDataLength(block)
        var data = [Float](repeating: 0, count: length / 4)
        _ = data.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length / 4 * 4, destination: $0.baseAddress!)
        }
        for i in 0 ..< data.count { samples[i % channels].append(data[i]) }
    }
    return (basic.mSampleRate, channels, samples)
}

/// The dominant frequency of a stretch of samples, by zero crossings.
func c11frequency(_ x: ArraySlice<Float>, rate: Double) -> Double {
    var crossings = 0
    var previous = x.first ?? 0
    for v in x.dropFirst() {
        if (previous < 0) != (v < 0) { crossings += 1 }
        previous = v
    }
    return Double(crossings) / 2 / (Double(x.count) / rate)
}

extension VideoEditTests {
    /// The 4 s clip's picture with a sound of `channels` channels (layout given above 2): a 1 kHz tone in the first
    /// channel, a 600 Hz tone in the third when there is one.
    @nonobjc func c11toneClip(channels: Int, rate: Double = 48000) async throws -> URL {
        let picture = AVURLAsset(url: try await clip())
        let sound = folder.appendingPathComponent("tone\(channels)-\(UUID().uuidString).caf")
        let format = channels <= 2 ? AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels))!
            : AVAudioFormat(standardFormatWithSampleRate: rate,
                            channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)!)
        let file = try AVAudioFile(forWriting: sound, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 4))!
        buffer.frameLength = buffer.frameCapacity
        for i in 0 ..< Int(buffer.frameLength) {
            buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 1000 / rate) * 0.5)
            if channels > 2 { buffer.floatChannelData![2][i] = Float(sin(Double(i) * 2 * .pi * 600 / rate) * 0.5) }
        }
        try file.write(from: buffer)
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 4, preferredTimescale: 600))
        let v = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try v.insertTimeRange(range, of: try await picture.loadTracks(withMediaType: .video)[0], at: .zero)
        let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try a.insertTimeRange(range, of: try await AVURLAsset(url: sound).loadTracks(withMediaType: .audio)[0], at: .zero)
        let output = folder.appendingPathComponent("tone\(channels)-\(UUID().uuidString).mov")
        let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        try await session.export(to: output, as: .mov)
        return output
    }

    /// At another speed a 5.1 video keeps its pitch (D-130) and its channels, as stereo does.
    func testC11FiveOneAtAnotherSpeedKeepsPitchAndChannels() async throws {
        var problems: [String] = []
        for channels in [1, 2, 6] {
            let source = try await c11toneClip(channels: channels)
            for speed in [1.0, 2.0, 0.5] {
                var edit = recipe(source)
                edit.adjust.exposure = 0.01
                var time = EditTimeline()
                time.speed = speed
                edit.timeline = time
                let out = folder.appendingPathComponent("tone-\(channels)-\(speed).mov")
                _ = try await VideoComposer.export(source, recipe: edit, to: out) { _ in }
                let sound = try await c11readSound(out)
                let mid = sound.samples[0].count / 2
                let f = c11frequency(sound.samples[0][mid - 4800 ..< mid + 4800], rate: sound.rate)
                if abs(f - 1000) > 30 {
                    problems.append(String(format: "%dch at %.1fx: first channel at %.0f Hz, not 1000", channels, speed, f))
                }
                if sound.channels != channels { problems.append("\(channels)ch at \(speed)x: \(sound.channels) channels out") }
            }
        }
        XCTAssertTrue(problems.isEmpty, "\(problems)")
    }

    /// The burst centres of an exported clip at each speed are at their times divided by the speed, within 20 ms.
    func testC11ExportedBurstsAreOnTimeAtEverySpeed() async throws {
        var problems: [String] = []
        let source = try await clickClip(rate: 48000, clicks: [1, 2.5])
        let original = try await c11readSound(source)
        func centre(_ s: [Float], rate: Double, around t: Double, half: Double) -> Double {
            var w = 0.0, sum = 0.0
            for i in max(0, Int((t - half) * rate)) ..< min(s.count, Int((t + half) * rate)) {
                let e = Double(s[i] * s[i]); w += e; sum += e * Double(i) / rate
            }
            return sum / max(w, 1e-12)
        }
        let originalCentres = [1.0, 2.5].map { centre(original.samples[0], rate: original.rate, around: $0 + 0.01, half: 0.2) }
        for speed in [0.25, 0.5, 2, 4] {
            var edit = recipe(source)
            edit.adjust.exposure = 0.01
            var time = EditTimeline()
            time.speed = speed
            edit.timeline = time
            let out = folder.appendingPathComponent("click-\(speed).mp4")
            _ = try await VideoComposer.export(source, recipe: edit, to: out) { _ in }
            let got = try await c11readSound(out)
            for c in originalCentres {
                let due = c / speed
                let heard = centre(got.samples[0], rate: got.rate, around: due, half: 0.2 / speed * 0.6)
                let err = (heard - due) * 1000
                if abs(err) > 20 {
                    problems.append(String(format: "%.2fx: burst due %.3f s heard %.3f s (%+.0f ms)", speed, due, heard, err))
                }
            }
        }
        XCTAssertTrue(problems.isEmpty, "\(problems)")
    }
}

extension VideoEditTests {
    /// A tone that runs to the very end of the clip still sounds to the end of the export at every speed (within 20 ms).
    func testC11ToneRunsToTheEndAtEverySpeed() async throws {
        var problems: [String] = []
        for channels in [1, 2] {
            let source = try await c11toneClip(channels: channels)
            let original = try await c11readSound(source)
            let lastOriginal = Double((original.samples[0].lastIndex { abs($0) > 0.05 } ?? 0)) / original.rate
            for speed in [0.25, 0.5, 2, 4] {
                var edit = recipe(source)
                edit.adjust.exposure = 0.01
                var time = EditTimeline()
                time.speed = speed
                edit.timeline = time
                let out = folder.appendingPathComponent("end-\(channels)-\(speed).mov")
                _ = try await VideoComposer.export(source, recipe: edit, to: out) { _ in }
                let got = try await c11readSound(out)
                let last = Double((got.samples[0].lastIndex { abs($0) > 0.05 } ?? 0)) / got.rate
                let due = lastOriginal / speed
                if due - last > 0.02 {
                    problems.append(String(format: "%dch %.2fx: tone ends %.0f ms early (%.3f of %.3f s)", channels, speed,
                                           (due - last) * 1000, last, due))
                }
            }
        }
        XCTAssertTrue(problems.isEmpty, "\(problems)")
    }

    /// A 2 ms part kept at another speed exports, as it does at normal speed (C11-6).
    func testC11TinyPartAtSpeed() async throws {
        let source = try await clip()
        var results: [String] = []
        let cases: [(Double, Double, Double, Double, Double)] = [
            (2.0, 1.0, 0.1, 1.0, 0.002), (2.0, 0.0, 0.0, 1.0, 0.002), (2.0, 1.0, 0.1, 0.0, 0.002), (1.0, 1.0, 0.1, 1.0, 0.002),
            (4.0, 0.0, 0.0, 1.0, 0.002), (2.0, 0.0, 0.0, 1.0, 0.01), (4.0, 0.0, 0.0, 1.0, 0.01), (2.0, 0.0, 0.0, 1.0, 0.05),
            (0.5, 0.0, 0.0, 1.0, 0.002),
        ]
        for (speed, fadeIn, fadeOut, volume, length) in cases {
            var edit = recipe(source)
            var time = EditTimeline()
            time.kept = [TimeRange(start: 0.225, end: 0.225 + length)]
            time.speed = speed
            time.fadeIn = fadeIn
            time.fadeOut = fadeOut
            time.volume = volume
            edit.timeline = time
            let out = folder.appendingPathComponent("tiny-\(UUID().uuidString).mov")
            let label = "speed \(speed) fades \(fadeIn)/\(fadeOut) vol \(volume) part \(length * 1000) ms"
            do {
                _ = try await VideoComposer.export(source, recipe: edit, to: out) { _ in }
                let d = try await AVURLAsset(url: out).load(.duration).seconds
                results.append("\(label): ok, \(d) s")
            } catch { results.append("\(label): THROWS \(error.localizedDescription)") }
        }
        XCTAssertTrue(results.allSatisfy { !$0.contains("THROWS") }, "\(results)")
    }

    /// Cancel while the sound at another speed is rendered stops the export at once and leaves nothing behind (C11-3).
    func testC11CancelDuringTheSoundRenderStopsPromptly() async throws {
        let base = AVURLAsset(url: try await clip())
        let composition = AVMutableComposition()
        let v = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 4, preferredTimescale: 600))
        let pv = try await base.loadTracks(withMediaType: .video)[0], pa = try await base.loadTracks(withMediaType: .audio)[0]
        for i in 0 ..< 45 {
            try v.insertTimeRange(range, of: pv, at: CMTime(seconds: Double(i) * 4, preferredTimescale: 600))
            try a.insertTimeRange(range, of: pa, at: CMTime(seconds: Double(i) * 4, preferredTimescale: 600))
        }
        let long = folder.appendingPathComponent("long.mov")
        let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        try await session.export(to: long, as: .mov)
        var edit = recipe(long)
        edit.adjust.exposure = 0.01
        var time = EditTimeline()
        time.speed = 0.25
        edit.timeline = time
        let tmp = FileManager.default.temporaryDirectory
        func leftovers() -> Set<String> {
            Set(((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []).filter { $0.hasPrefix("MediaPull-sound-") })
        }
        let before = leftovers()
        let out = folder.appendingPathComponent("long-out.mov")
        let task = Task { try await VideoComposer.export(long, recipe: edit, to: out) { _ in } }
        try await Task.sleep(for: .milliseconds(300))
        let cancelled = Date()
        task.cancel()
        _ = await task.result
        let took = Date().timeIntervalSince(cancelled)
        XCTAssertLessThan(took, 2, "Cancel took \(took) s")
        XCTAssertTrue(leftovers().subtracting(before).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    /// A video export with a picture layer no longer there is refused, as a photo's is (B11-5).
    func testB11VideoExportWithAMissingPictureLayerIsRefused() async throws {
        let source = try await clip()
        var edit = recipe(source)
        edit.layers = [Layer(kind: .image(path: folder.appendingPathComponent("gone-logo.png").path))]
        let out = folder.appendingPathComponent("missing-picture.mov")
        do {
            _ = try await VideoComposer.export(source, recipe: edit, to: out) { _ in }
            XCTFail("exported without its picture layer")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("gone-logo.png"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }
}
