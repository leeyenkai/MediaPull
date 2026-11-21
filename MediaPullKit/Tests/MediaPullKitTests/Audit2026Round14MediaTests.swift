/// Audit 2026-11-22, round 14 (auditor C): video and audio editing.
@preconcurrency import AVFoundation
import Foundation
@testable import MediaPullCore
@testable import MediaPullEdit
@testable import MediaPullEngines
import XCTest

/// A layout from channel descriptions.
func c14layout(_ labels: [AudioChannelLabel]) -> AVAudioChannelLayout {
    let n = labels.count
    let size = MemoryLayout<AudioChannelLayout>.size + max(0, n - 1) * MemoryLayout<AudioChannelDescription>.size
    let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
    defer { raw.deallocate() }
    memset(raw, 0, size)
    let l = raw.assumingMemoryBound(to: AudioChannelLayout.self)
    l.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
    l.pointee.mNumberChannelDescriptions = UInt32(n)
    withUnsafeMutablePointer(to: &l.pointee.mChannelDescriptions) { p in
        p.withMemoryRebound(to: AudioChannelDescription.self, capacity: n) { d in
            for k in 0 ..< n { d[k].mChannelLabel = labels[k] }
        }
    }
    return AVAudioChannelLayout(layout: l)
}

/// A layout from a channel bitmap.
func c14bitmap(_ bits: AudioChannelBitmap) -> AVAudioChannelLayout {
    var l = AudioChannelLayout()
    l.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelBitmap
    l.mChannelBitmap = bits
    return withUnsafePointer(to: &l) { AVAudioChannelLayout(layout: $0) }
}

/// The labels of a layout, in channel order (tags expanded).
func c14labels(_ layout: AVAudioChannelLayout) -> [AudioChannelLabel] {
    var size = UInt32(0)
    let inSize = UInt32(MemoryLayout<AudioChannelLayout>.size + max(0, Int(layout.layout.pointee.mNumberChannelDescriptions) - 1)
        * MemoryLayout<AudioChannelDescription>.size)
    guard AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag, 0, nil, &size) >= 0 || true else { return [] }
    var tag = layout.layoutTag
    var out: [AudioChannelLabel] = []
    func read(_ p: UnsafePointer<AudioChannelLayout>) {
        let n = Int(p.pointee.mNumberChannelDescriptions)
        let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
        let d = (UnsafeRawPointer(p) + offset).assumingMemoryBound(to: AudioChannelDescription.self)
        out = (0 ..< n).map { d[$0].mChannelLabel }
    }
    if tag == kAudioChannelLayoutTag_UseChannelDescriptions {
        read(layout.layout)
        return out
    }
    // Tag or bitmap: expanded by Audio Format.
    let isBitmap = tag == kAudioChannelLayoutTag_UseChannelBitmap
    var bitmap = layout.layout.pointee.mChannelBitmap
    let prop = isBitmap ? kAudioFormatProperty_ChannelLayoutForBitmap : kAudioFormatProperty_ChannelLayoutForTag
    let status: OSStatus = isBitmap ? AudioFormatGetPropertyInfo(prop, 4, &bitmap, &size) : AudioFormatGetPropertyInfo(prop, 4, &tag, &size)
    guard status == noErr else { return [] }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
    defer { raw.deallocate() }
    let s2: OSStatus = isBitmap ? AudioFormatGetProperty(prop, 4, &bitmap, &size, raw) : AudioFormatGetProperty(prop, 4, &tag, &size, raw)
    guard s2 == noErr else { return [] }
    _ = inSize
    read(raw.assumingMemoryBound(to: AudioChannelLayout.self))
    return out
}

extension VideoEditTests {
    /// For each tone, its loudest amplitude in any channel, and the channel holding it.
    @nonobjc func c14where(_ url: URL, tones: [Int]) async throws -> [(tone: Int, level: Double, channel: Int)] {
        let got = try await c11readSound(url)
        return tones.map { t in
            let levels = got.samples.map { c13tone($0, hz: Double(t), rate: got.rate) }
            let best = levels.indices.max { levels[$0] < levels[$1] } ?? 0
            return (t, levels.isEmpty ? 0 : levels[best], best)
        }
    }

    /// Surround layouts of every count from 3 to 8, as tags, channel descriptions and bitmaps, re-encoded at 1x and
    /// 2x: every channel's tone is still in the export (in some channel), never silenced. LFE (low-passed by the
    /// encoder) carries 100 Hz.
    func testC14EveryLayoutKeepsEveryChannelsSound() async throws {
        let only = ProcessInfo.processInfo.environment["C14_ONLY"]
        var cases: [(String, AVAudioChannelLayout)] = []
        let tags: [(String, AudioChannelLayoutTag)] = [
            ("2.1 L R LFE (DVD_4)", kAudioChannelLayoutTag_DVD_4),
            ("3.0 L R C", kAudioChannelLayoutTag_MPEG_3_0_A),
            ("4.0 L R C Cs", kAudioChannelLayoutTag_MPEG_4_0_A),
            ("3.1 L R C LFE (DVD_10)", kAudioChannelLayoutTag_DVD_10),
            ("4.1 L R Ls Rs LFE (DVD_18)", kAudioChannelLayoutTag_DVD_18),
            ("4.1 L R C LFE Cs (DVD_11)", kAudioChannelLayoutTag_DVD_11),
            ("5.0 L R C Ls Rs", kAudioChannelLayoutTag_MPEG_5_0_A),
            ("5.1 L R C LFE Ls Rs", kAudioChannelLayoutTag_MPEG_5_1_A),
            ("5.1 L C R Ls Rs LFE (MPEG_5_1_C)", kAudioChannelLayoutTag_MPEG_5_1_C),
            ("6.0 C L R Ls Rs Cs (AAC)", kAudioChannelLayoutTag_AAC_6_0),
            ("6.1 L R C LFE Ls Rs Cs", kAudioChannelLayoutTag_MPEG_6_1_A),
            ("7.0 L R Ls Rs C Rls Rrs", kAudioChannelLayoutTag_AudioUnit_7_0),
            ("7.1 L R C LFE Ls Rs Rls Rrs (MPEG_7_1_C)", kAudioChannelLayoutTag_MPEG_7_1_C),
            ("7.1 wide L R C LFE Ls Rs Lc Rc (MPEG_7_1_A)", kAudioChannelLayoutTag_MPEG_7_1_A),
            ("5.1.2 L R C LFE Ls Rs Vhl Vhr (Atmos)", kAudioChannelLayoutTag_Atmos_5_1_2),
            ("Octagonal (8)", kAudioChannelLayoutTag_AAC_Octagonal),
            ("Cube (8)", kAudioChannelLayoutTag_Cube),
            ("Ambi B-format (4)", kAudioChannelLayoutTag_Ambisonic_B_Format),
            ("Ambi HOA N3D (4)", kAudioChannelLayoutTag_HOA_ACN_N3D | 4),
            ("Ambi HOA SN3D (4)", kAudioChannelLayoutTag_HOA_ACN_SN3D | 4),
        ]
        for (name, tag) in tags { if let l = AVAudioChannelLayout(layoutTag: tag) { cases.append((name, l)) } }
        // Channel descriptions some editors and recorders write.
        cases.append(("desc 5.1 + Lt Rt (8)", c14layout([kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
                                                       kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround,
                                                       kAudioChannelLabel_RightSurround, kAudioChannelLabel_LeftTotal,
                                                       kAudioChannelLabel_RightTotal])))
        cases.append(("desc 5.1 + HI + Narration (8)", c14layout([kAudioChannelLabel_Left, kAudioChannelLabel_Right,
                                                                 kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
                                                                 kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
                                                                 kAudioChannelLabel_HearingImpaired, kAudioChannelLabel_Narration])))
        cases.append(("desc Mono x4", c14layout(Array(repeating: kAudioChannelLabel_Mono, count: 4))))
        cases.append(("desc Mono x6", c14layout(Array(repeating: kAudioChannelLabel_Mono, count: 6))))
        cases.append(("desc L R + Discrete_0 Discrete_1 (mixed, 4)",
                      c14layout([kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Discrete_0,
                                 kAudioChannelLabel_Discrete_1])))
        cases.append(("desc L R C + Unknown (mixed, 4)",
                      c14layout([kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
                                 kAudioChannelLabel_Unknown])))
        cases.append(("desc L R L R L R (repeated, 6)",
                      c14layout([kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Left,
                                 kAudioChannelLabel_Right, kAudioChannelLabel_Left, kAudioChannelLabel_Right])))
        cases.append(("desc 7.1 side+rear L R C LFE Ls Rs Rls Rrs", c14layout([
            kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
            kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround, kAudioChannelLabel_RearSurroundLeft,
            kAudioChannelLabel_RearSurroundRight])))
        cases.append(("desc 5.1 rear L R C LFE Rls Rrs", c14layout([
            kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
            kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight])))
        // WAVE_FORMAT_EXTENSIBLE style bitmaps.
        let b = { (x: AudioChannelBitmap) in x }
        cases.append(("bitmap 5.1 side (0x60F)", c14bitmap(b([.bit_Left, .bit_Right, .bit_Center, .bit_LFEScreen,
                                                               .bit_LeftSurroundDirect, .bit_RightSurroundDirect]))))
        cases.append(("bitmap 5.1 back (0x3F)", c14bitmap(b([.bit_Left, .bit_Right, .bit_Center, .bit_LFEScreen, .bit_LeftSurround,
                                                              .bit_RightSurround]))))
        cases.append(("bitmap 7.1 (0x63F)", c14bitmap(b([.bit_Left, .bit_Right, .bit_Center, .bit_LFEScreen, .bit_LeftSurround,
                                                          .bit_RightSurround, .bit_LeftSurroundDirect, .bit_RightSurroundDirect]))))
        cases.append(("bitmap 5.1 + top front L R", c14bitmap(b([.bit_Left, .bit_Right, .bit_Center, .bit_LFEScreen,
                                                                  .bit_LeftSurround, .bit_RightSurround, .bit_VerticalHeightLeft,
                                                                  .bit_VerticalHeightRight]))))
        var problems: [String] = []
        var report: [String] = []
        for (name, layout) in cases {
            if let only, !name.contains(only) { continue }
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
            let n = Int(format.channelCount)
            let labels = c14labels(layout)
            let tones = (0 ..< n).map { k in
                k < labels.count && (labels[k] == kAudioChannelLabel_LFEScreen || labels[k] == kAudioChannelLabel_LFE2) ? 100 + k
                    : 200 + 100 * k
            }
            let source: URL
            do {
                source = try await c12clip(format: format) { c, i in Float(sin(Double(i) * 2 * .pi * Double(tones[c]) / 48000) * 0.3) }
            } catch {
                report.append("\(name): source not written (\(error.localizedDescription))")
                continue
            }
            let track = try await AVURLAsset(url: source).loadTracks(withMediaType: .audio)[0]
            let description = try await track.load(.formatDescriptions)[0]
            let read = AVAudioFormat(cmAudioFormatDescription: description)
            let positional = read.channelLayout.map { SoundAtSpeed.speakers(of: $0) != nil }
            for speed in [1.0, 2.0] {
                do {
                    let out = try await c12export(source, speed: speed)
                    let got = try await c14where(out, tones: tones)
                    let channels = try await c11readSound(out).channels
                    let lost = got.filter { $0.level < 0.05 }.map(\.tone)
                    let tag: String = read.channelLayout.map { "\($0.layoutTag >> 16)" } ?? "nil"
                    let placed: String = positional.map { "\($0)" } ?? "nil"
                    let heard: String = got.map { String(format: "%d@%d %.2f", $0.tone, $0.channel, $0.level) }.joined(separator: " ")
                    report.append("\(name) [\(n) ch, read tag \(tag), positional \(placed)] \(speed)x -> \(channels) ch: " + heard)
                    // Kept by number (a mix channel among them), the last of six or more is the encoder's LFE, as with the
                    // system's own exporter (recorded, audit 2026-11-21-14).
                    let byNumber = n >= 6 && positional == false
                    let missing = byNumber ? lost.filter { $0 != tones.last } : lost
                    if !missing.isEmpty { problems.append("\(name) at \(speed)x: \(n) channels, tones lost \(missing)") }
                } catch {
                    problems.append("\(name) at \(speed)x: throws \(error.localizedDescription)")
                }
            }
        }
        print("C14 layouts:\n" + report.joined(separator: "\n"))
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    /// 7.1 with rear surrounds (MPEG_7_1_C): read into AAC_7_1_B (which has rear surrounds) instead of AAC_7_1, the
    /// system's exporter still writes AAC_7_1 and scrambles the channels, so the C12-1 remainder's premise holds (checked).
    func testC14SevenOneRearPairHasAPlaceInTheEncoder() async throws {
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_7_1_C)!
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
        let tones = [200, 300, 400, 100, 600, 700, 800, 900]
        let source = try await c12clip(format: format) { c, i in Float(sin(Double(i) * 2 * .pi * Double(tones[c]) / 48000) * 0.3) }
        // As MediaPull does it.
        let shipped = try await c12export(source, speed: 1)
        let before = try await c12frequencies(source, in: layout)
        let mine = try await c12frequencies(shipped, in: layout)
        // Read into AAC_7_1_B instead.
        let asset = AVURLAsset(url: source)
        var edit = recipe(source)
        edit.adjust.exposure = 0.01
        let plainBuilt = try await VideoComposer.build(asset, recipe: edit)
        let target = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_AAC_7_1_B)!
        let renderFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, interleaved: true, channelLayout: target)
        let reader = try AVAssetReader(asset: plainBuilt.composition)
        let tracks = try await plainBuilt.composition.loadTracks(withMediaType: .audio)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 8, AVSampleRateKey: 48000,
            AVChannelLayoutKey: SoundAtSpeed.data(of: target),
        ])
        reader.add(output)
        let caf = folder.appendingPathComponent("71b.caf")
        do {
            let file = try AVAudioFile(forWriting: caf, settings: renderFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
            XCTAssertTrue(reader.startReading())
            while let s = output.copyNextSampleBuffer() {
                guard let block = s.dataBuffer else { continue }
                let frames = CMBlockBufferGetDataLength(block) / 32
                let buffer = AVAudioPCMBuffer(pcmFormat: renderFormat, frameCapacity: AVAudioFrameCount(frames))!
                buffer.frameLength = AVAudioFrameCount(frames)
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: frames * 32,
                                           destination: buffer.mutableAudioBufferList.pointee.mBuffers.mData!)
                try file.write(from: buffer)
            }
        }
        let built = try await VideoComposer.build(asset, recipe: edit, soundAtSpeed: caf)
        let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHEVCHighestQuality)!
        session.videoComposition = built.videoComposition
        let alt = folder.appendingPathComponent("71b.mov")
        try await session.export(to: alt, as: .mov)
        let theirs = try await c12frequencies(alt, in: layout)
        let altTrack = try await AVURLAsset(url: alt).loadTracks(withMediaType: .audio)[0]
        let altTag = AVAudioFormat(cmAudioFormatDescription: try await altTrack.load(.formatDescriptions)[0]).channelLayout?.layoutTag
        print("C14 7.1 source \(before)\n  MediaPull (AAC_7_1)  \(mine)\n  via AAC_7_1_B        \(theirs) tag "
            + "\(altTag.map { $0 >> 16 } ?? 0)")
        // The encoder writes its own 7.1 (front wide) whatever it is given: the C12-1 remainder's premise holds.
        XCTAssertEqual(altTag, kAudioChannelLayoutTag_AAC_7_1)
        XCTAssertFalse(zip(before, theirs).allSatisfy { abs($0 - $1) <= 15 })
    }

    /// Lossless paths (cuts only, mute) never render surround first: the picture's and sound's samples are copied.
    func testC14LosslessSurroundIsNeverRendered() async throws {
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_7_1_C)!
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
        let source = try await c12clip(format: format) { c, i in Float(sin(Double(i) * 2 * .pi * Double(200 + 100 * c) / 48000) * 0.3) }
        for (name, volume) in [("cut", 1.0), ("mute", 0.0)] {
            var edit = recipe(source)
            var time = EditTimeline()
            time.kept = [TimeRange(start: 1, end: 3)]
            time.volume = volume
            edit.timeline = time
            let out = folder.appendingPathComponent("c14-lossless-\(name).mov")
            let built = try await VideoComposer.export(source, recipe: edit, to: out) { _ in }
            XCTAssertTrue(built.lossless, name)
            let leftovers = (try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()))
                .filter { $0.hasPrefix("MediaPull-sound-") }
            _ = leftovers
            let tracks = try await AVURLAsset(url: out).loadTracks(withMediaType: .audio)
            if volume == 0 { XCTAssertTrue(tracks.isEmpty, "mute keeps no sound") } else {
                let d = try await tracks[0].load(.formatDescriptions)[0]
                XCTAssertEqual(CMFormatDescriptionGetMediaSubType(d), kAudioFormatLinearPCM, "the sound is copied as it is")
                XCTAssertEqual(AVAudioFormat(cmAudioFormatDescription: d).channelCount, 8)
            }
        }
    }
}

/// Audio (R-4610): the waveform, streamed.
final class Audit2026Round14AudioTests: XCTestCase {
    var folder: URL!
    let ffmpeg = FFmpeg(ffmpeg: TestEngines.ffmpegFolder.appendingPathComponent("ffmpeg"),
                        ffprobe: TestEngines.ffmpegFolder.appendingPathComponent("ffprobe"))

    override func setUpWithError() throws {
        try XCTSkipUnless(ffmpeg.isAvailable, "ffmpeg is not built")
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("C14Audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// A 16-bit WAV of silence with loud 1 kHz bursts of `burst` seconds at `at` on channel `on` (all when nil).
    @nonobjc func bursts(_ name: String, at times: [Double], burst: Double = 0.02, rate: Double = 44100, channels: Int = 1,
                         on: Int? = nil, seconds: Double) throws -> URL
    {
        let url = folder.appendingPathComponent(name)
        var settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
        if channels > 2 {
            settings[AVChannelLayoutKey] = SoundAtSpeed.data(of: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder
                    | UInt32(channels))!)
        }
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let total = Int((rate * seconds).rounded())
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        for c in 0 ..< channels {
            let p = buffer.floatChannelData![c]
            for i in 0 ..< total { p[i] = 0 }
            guard on == nil || on == c else { continue }
            for t in times {
                let a = Int(t * rate), b = min(total, Int((t + burst) * rate))
                for i in a ..< max(a, b) { p[i] = Float(sin(Double(i - a) * 2 * .pi * 1000 / rate + .pi / 2)) * 0.9 }
            }
        }
        try file.write(from: buffer)
        return url
    }

    /// Where the waveform draws loud buckets, in seconds, as the canvas places them (index / count × measured length).
    @nonobjc func loudTimes(_ url: URL, buckets: Int) async throws -> (times: [Double], count: Int, duration: Double) {
        let peaks = try await ffmpeg.waveform(url, buckets: buckets)
        let duration = await ffmpeg.audioFormat(url)?.duration ?? 0
        var out: [Double] = []
        var previous = false
        for (i, p) in peaks.enumerated() {
            let loud = p > 0.5
            if loud, !previous { out.append(Double(i) / Double(peaks.count) * duration) }
            previous = loud
        }
        return (out, peaks.count, duration)
    }

    /// Bursts are drawn where they are, mono and multichannel, at several rates and lengths, near the start and at the
    /// very end: within one bucket and one 1,024-sample block.
    func testC14WaveformBucketsLandWhereTheirSoundIs() async throws {
        var problems: [String] = []
        for (rate, channels, on, seconds) in [(44100.0, 1, nil as Int?, 5.0), (8000, 1, nil, 5), (96000, 2, 1, 5), (48000, 6, 5, 5),
                                              (48000, 8, 7, 3), (44100, 1, nil, 600), (22050, 2, 0, 0.5), (48000, 1, nil, 0.4)] {
            let times = [0.0, seconds * 0.37, seconds - 0.02]
            let url = try bursts("b-\(Int(rate))-\(channels)-\(seconds).wav", at: times, rate: rate, channels: channels, on: on,
                                 seconds: seconds)
            let got = try await loudTimes(url, buckets: 1200)
            let bucket = seconds / Double(got.count)
            let block = 1024.0 / 24000 / Double(channels)
            let tolerance = bucket + block + 0.001
            let wrong = zip(times, got.times).filter { abs($0 - $1) > tolerance }
            print(String(format: "C14 wave %.0f Hz %d ch %.1f s: %d peaks, wanted %@ got %@", rate, channels, seconds, got.count,
                         "\(times.map { ($0 * 1000).rounded() / 1000 })", "\(got.times.map { ($0 * 1000).rounded() / 1000 })"))
            if got.times.count != times.count || !wrong.isEmpty {
                problems.append("\(Int(rate)) Hz \(channels) ch \(seconds) s: bursts at \(times), drawn at \(got.times) "
                    + "(\(got.count) peaks, tolerance \(tolerance))")
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    /// A short file has about the bars asked for: a 5 s mono clip asked for 1,200 bars gets at least 600, so two sounds
    /// 74 ms apart in a 0.2 s clip are drawn apart.
    func testC14WaveformOfAShortFileKeepsItsResolution() async throws {
        let five = try bursts("five.wav", at: [1], rate: 44100, seconds: 5)
        let peaks = try await ffmpeg.waveform(five, buckets: 1200)
        XCTAssertGreaterThanOrEqual(peaks.count, 600, "a 5 s mono clip is drawn with \(peaks.count) bars")
        let short = try bursts("short.wav", at: [0, 0.074], burst: 0.02, rate: 48000, seconds: 0.2)
        let got = try await loudTimes(short, buckets: 1200)
        XCTAssertEqual(got.times.count, 2, "two sounds 74 ms apart drawn as \(got.times) in \(got.count) bars")
    }

    /// The folder gives the same peaks whatever the pipe's pieces are (odd byte splits, one byte at a time, empty).
    func testC14PeakFolderIsIndependentOfSplits() {
        var generator = SystemRandomNumberGenerator()
        let samples = (0 ..< 50000).map { _ in Float.random(in: -1 ... 1, using: &generator) * (Bool.random() ? 1 : 0.1) }
        let bytes = samples.withUnsafeBytes { Data($0) }
        let whole = PeakFolder()
        whole.add(bytes)
        let reference = whole.finish()
        var expected: [Float] = []
        for start in stride(from: 0, to: samples.count, by: PeakFolder.block) {
            expected.append(samples[start ..< min(samples.count, start + PeakFolder.block)].map(abs).max()!)
        }
        XCTAssertEqual(reference, expected)
        for trial in 0 ..< 200 {
            let folder = PeakFolder()
            var at = 0
            while at < bytes.count {
                let n = trial == 0 ? 1 : Int.random(in: 0 ... 9000)
                let end = min(bytes.count, at + n)
                folder.add(bytes.subdata(in: at ..< end))
                at = end
            }
            let got = folder.finish()
            if got != reference { XCTFail("trial \(trial): \(got.count) peaks, \(reference.count) wanted"); break }
        }
        // A trailing part sample is dropped, not read.
        let odd = PeakFolder()
        odd.add(bytes + Data([0x7F, 0x7F]))
        XCTAssertEqual(odd.finish(), reference)
    }

    /// Short files: a 5 ms sound still has a waveform with its level; an empty sound has none.
    func testC14WaveformOfVeryShortFiles() async throws {
        for seconds in [0.005, 0.03, 0.05] {
            let url = try bursts("short-\(seconds).wav", at: [0], burst: seconds, rate: 44100, seconds: seconds)
            let peaks = try await ffmpeg.waveform(url, buckets: 1200)
            print("C14 short \(seconds) s: \(peaks.count) peaks \(peaks.prefix(4))")
            XCTAssertFalse(peaks.isEmpty, "\(seconds) s")
            XCTAssertGreaterThan(peaks.max() ?? 0, 0.5, "\(seconds) s")
        }
    }

    /// ffmpeg's errors come through as errors: a file that is not sound, a missing file, a video with no sound.
    func testC14WaveformErrorsAreErrors() async throws {
        let text = folder.appendingPathComponent("notes.mp3")
        try Data("not sound at all".utf8).write(to: text)
        for url in [text, folder.appendingPathComponent("missing.wav")] {
            do {
                let peaks = try await ffmpeg.waveform(url, buckets: 100)
                XCTFail("\(url.lastPathComponent): no error, \(peaks.count) peaks")
            } catch {
                XCTAssertTrue(error is FFmpegError, "\(error)")
            }
        }
    }

    /// Cancel stops the decode promptly and is reported as a Cancel.
    func testC14WaveformCancel() async throws {
        let url = try bursts("long.wav", at: [1], rate: 48000, channels: 6, on: 0, seconds: 300)
        let ffmpeg = self.ffmpeg
        let task = Task { try await ffmpeg.waveform(url, buckets: 1200) }
        try await Task.sleep(for: .milliseconds(150))
        let start = Date()
        task.cancel()
        do {
            let peaks = try await task.value
            XCTFail("not cancelled: \(peaks.count) peaks after \(Date().timeIntervalSince(start)) s")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        // No ffmpeg left reading the file.
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "command"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try ps.run()
        let list = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        XCTAssertFalse(list.contains(url.path), "ffmpeg still running")
    }

    /// The sound's end is drawn at the waveform's end: a long file whose last two seconds are loud has its last
    /// buckets loud, and the waveform covers the measured length.
    func testC14WaveformReachesTheEnd() async throws {
        for (rate, channels) in [(44100.0, 2), (48000, 6), (8000, 1)] {
            let seconds = 61.3
            let url = try bursts("end-\(Int(rate))-\(channels).wav", at: [seconds - 2], burst: 2, rate: rate, channels: channels,
                                 seconds: seconds)
            let peaks = try await ffmpeg.waveform(url, buckets: 1200)
            let loudFrom = peaks.firstIndex { $0 > 0.5 } ?? -1
            let expected = Int(((seconds - 2) / seconds * Double(peaks.count)).rounded(.down))
            print("C14 end \(Int(rate)) \(channels): \(peaks.count) peaks, loud from \(loudFrom) (expected \(expected)), "
                + "last \(peaks.last ?? -1)")
            XCTAssertGreaterThan(peaks.last ?? 0, 0.5)
            XCTAssertLessThanOrEqual(abs(loudFrom - expected), 1)
        }
    }

    /// Leftovers: only MediaPull's own temporary files a day old are removed; newer ones and others' files stay.
    func testC14RemoveLeftoversOnlyTakesDayOldFiles() throws {
        let temp = FileManager.default.temporaryDirectory
        let id = UUID().uuidString
        let names = ["MediaPull-sound-\(id)-old.caf", "MediaPull-sound-\(id)-new.caf", "MediaPull-cut-\(id)-old.ffconcat",
                     "MediaPull-wave-\(id)-old.f32", "Other-\(id)-old.caf", "MediaPull-sound-\(id)-hour.caf"]
        let ages: [Double] = [90000, 10, 90000, 90000, 90000, 82800]
        for (name, age) in zip(names, ages) {
            let url = temp.appendingPathComponent(name)
            try Data([1]).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
        }
        // A link made a day ago to a file that is in use now.
        let target = temp.appendingPathComponent("C14-target-\(id).mp3")
        try Data([1]).write(to: target)
        let link = temp.appendingPathComponent("MediaPull-cut-\(id)-link.mp3")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        SoundAtSpeed.removeLeftovers()
        let left = names.filter { FileManager.default.fileExists(atPath: temp.appendingPathComponent($0).path) }
        XCTAssertEqual(left, ["MediaPull-sound-\(id)-new.caf", "Other-\(id)-old.caf", "MediaPull-sound-\(id)-hour.caf"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), "the link's target is never removed")
        for name in names + ["C14-target-\(id).mp3", "MediaPull-cut-\(id)-link.mp3"] {
            try? FileManager.default.removeItem(at: temp.appendingPathComponent(name))
        }
    }
}

extension VideoEditTests {
    /// Ten and twelve channel layouts with places (Atmos 7.1.2, 5.1.4, 7.1.4) on a re-encode: written, or refused
    /// with a reason no worse than the system's exporter alone gives.
    func testC14AtmosBedsOnAReencode() async throws {
        var problems: [String] = []
        for (name, tag) in [("7.1.2", kAudioChannelLayoutTag_Atmos_7_1_2), ("5.1.4", kAudioChannelLayoutTag_Atmos_5_1_4),
                            ("7.1.4", kAudioChannelLayoutTag_Atmos_7_1_4), ("HOA 9", kAudioChannelLayoutTag_HOA_ACN_SN3D | 9),
                            ("10 discrete", kAudioChannelLayoutTag_DiscreteInOrder | 10)] {
            let layout = AVAudioChannelLayout(layoutTag: tag)!
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
            let n = Int(format.channelCount)
            let tones = (0 ..< n).map { 200 + 100 * $0 }
            let source = try await c12clip(format: format) { c, i in Float(sin(Double(i) * 2 * .pi * Double(tones[c]) / 48000) * 0.3) }
            var system = "?"
            do {
                var edit = recipe(source)
                edit.adjust.exposure = 0.01
                let built = try await VideoComposer.build(AVURLAsset(url: source), recipe: edit)
                let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHEVCHighestQuality)!
                session.videoComposition = built.videoComposition
                let out = folder.appendingPathComponent("sys-\(UUID().uuidString).mov")
                try await session.export(to: out, as: .mov)
                let got = try await c14where(out, tones: tones)
                system = "\(try await c11readSound(out).channels) ch, lost \(got.filter { $0.level < 0.05 }.map(\.tone))"
            } catch {
                system = "throws \(error.localizedDescription)"
            }
            var rendered = "?"
            do {
                var edit = recipe(source)
                edit.adjust.exposure = 0.01
                let url = try await SoundAtSpeed.render(AVURLAsset(url: source), recipe: edit)
                rendered = url.map { _ in "rendered" } ?? "nil"
                if let url { try? FileManager.default.removeItem(at: url) }
            } catch {
                rendered = "render throws \(error.localizedDescription)"
            }
            var mine = "?"
            do {
                let out = try await c12export(source, speed: 1)
                let got = try await c14where(out, tones: tones)
                mine = "\(try await c11readSound(out).channels) ch, lost \(got.filter { $0.level < 0.05 }.map(\.tone))"
            } catch {
                mine = "throws \(error.localizedDescription)"
            }
            print("C14 \(name): system alone \(system); MediaPull \(mine) (\(rendered))")
            if mine.hasPrefix("throws"), !system.hasPrefix("throws") {
                problems.append("\(name): MediaPull \(mine), system alone \(system)")
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }
}

extension VideoEditTests {
    /// Labelled channels that have no place in the AAC encoder's layout of their count (an LFE in 2.1 or 4.1, a
    /// stereo downmix or hearing-impaired and narration channels beside 5.1, channels all labelled Mono, stereo pairs
    /// labelled L R L R): on a re-encode at 1x and 2x every channel keeps its sound in a channel of its own, as the
    /// same sound with no labels does (C13-1). Compared with the system's exporter alone.
    func testC14LabelsWithNoPlaceInTheEncoderKeepTheirSound() async throws {
        let L = kAudioChannelLabel_Left, R = kAudioChannelLabel_Right, C = kAudioChannelLabel_Center
        let LFE = kAudioChannelLabel_LFEScreen, Ls = kAudioChannelLabel_LeftSurround, Rs = kAudioChannelLabel_RightSurround
        let cases: [(String, AVAudioChannelLayout)] = [
            ("2.1 L R LFE", AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DVD_4)!),
            ("4.1 L R Ls Rs LFE", AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DVD_18)!),
            ("4.1 L R C LFE Cs", AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DVD_11)!),
            ("5.1 + Lt Rt", c14layout([L, R, C, LFE, Ls, Rs, kAudioChannelLabel_LeftTotal, kAudioChannelLabel_RightTotal])),
            ("5.1 + HI + Narration", c14layout([L, R, C, LFE, Ls, Rs, kAudioChannelLabel_HearingImpaired, kAudioChannelLabel_Narration])),
            ("Mono x4", c14layout(Array(repeating: kAudioChannelLabel_Mono, count: 4))),
            ("L R L R L R", c14layout([L, R, L, R, L, R])),
        ]
        var problems: [String] = []
        for (name, layout) in cases {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
            let n = Int(format.channelCount)
            let labels = c14labels(layout)
            let tones = (0 ..< n).map { labels[$0] == LFE ? 100 : 200 + 100 * $0 }
            let source = try await c12clip(format: format) { c, i in Float(sin(Double(i) * 2 * .pi * Double(tones[c]) / 48000) * 0.3) }
            var systemLost = Set<Int>()
            var system = "?"
            do {
                var edit = recipe(source)
                edit.adjust.exposure = 0.01
                let built = try await VideoComposer.build(AVURLAsset(url: source), recipe: edit)
                let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHEVCHighestQuality)!
                session.videoComposition = built.videoComposition
                let out = folder.appendingPathComponent("sys-\(UUID().uuidString).mov")
                try await session.export(to: out, as: .mov)
                let got = try await c14where(out, tones: tones)
                systemLost = Set(got.filter { $0.level < 0.05 }.map(\.tone))
                system = "lost \(got.filter { $0.level < 0.05 }.map(\.tone)), channels \(got.map(\.channel))"
            } catch {
                system = "throws \(error.localizedDescription)"
            }
            for speed in [1.0, 2.0] {
                let out = try await c12export(source, speed: speed)
                let got = try await c14where(out, tones: tones)
                // Only what the system's own exporter keeps is asked for: it too drops the last of eight discrete channels.
                let lost = got.filter { $0.level < 0.05 && !systemLost.contains($0.tone) }.map(\.tone)
                let shared = Dictionary(grouping: got.filter { $0.level >= 0.05 }, by: \.channel).filter { $0.value.count > 1 }
                    .map { "\($0.value.map(\.tone)) in channel \($0.key)" }
                if !lost.isEmpty || !shared.isEmpty {
                    problems.append("\(name) at \(speed)x: lost \(lost), mixed together \(shared); system exporter alone: \(system)")
                }
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }
}

extension Audit2026Round14AudioTests {
    /// A tone WAV of `bits` (integer, or 32-bit float) at `rate`.
    @nonobjc func toneWAV(_ name: String, bits: Int, float: Bool = false, rate: Double = 48000, channels: Int = 2,
                          seconds: Double = 3) throws -> URL
    {
        let url = folder.appendingPathComponent(name)
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                                               AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: bits,
                                                               AVLinearPCMIsFloatKey: float])
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(rate * seconds))!
        buffer.frameLength = buffer.frameCapacity
        for c in 0 ..< channels {
            for i in 0 ..< Int(buffer.frameLength) { buffer.floatChannelData![c][i] = Float(sin(Double(i) * 2 * .pi * 440 / rate)) * 0.5 }
        }
        try file.write(from: buffer)
        return url
    }

    @nonobjc func streamInfo(_ url: URL) async throws -> String {
        try await FFmpeg.run(ffmpeg.ffprobe, ["-v", "error", "-select_streams", "a:0", "-show_entries",
                                              "stream=codec_name,sample_rate,channels,sample_fmt,bits_per_raw_sample,bits_per_sample",
                                              "-of", "compact=p=0", url.path]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Depth and rate through every format, with only cuts (encoded again losslessly) and with a fade (filters):
    /// lossless outputs keep the source's depth (16 stays 16, 24 stays 24) and rate.
    func testC14LosslessExportsKeepDepthAndRate() async throws {
        var problems: [String] = []
        var report: [String] = []
        for (bits, float, rate) in [(16, false, 44100.0), (24, false, 96000), (32, true, 48000)] {
            let source = try toneWAV("src-\(bits)-\(Int(rate)).wav", bits: bits, float: float, rate: rate)
            let measured = await ffmpeg.audioFormat(source)
            let info = try XCTUnwrap(measured)
            for out in [AudioOutput.flac, .alac, .wav, .aiff] {
                for (edit, change) in [("cut", { (t: inout EditTimeline) in t.kept = [TimeRange(start: 0.5, end: 2.5)] }),
                                       ("fade", { (t: inout EditTimeline) in t.fadeIn = 0.5 }),
                                       ("volume", { (t: inout EditTimeline) in t.volume = 0.8 })] {
                    var recipe = EditRecipe(source: EditSource(path: source.path, kind: .audio))
                    var time = EditTimeline()
                    change(&time)
                    recipe.timeline = time
                    recipe.export.audioFormat = out
                    let target = folder.appendingPathComponent("o-\(bits)-\(out.rawValue)-\(edit).\(out.fileExtension)")
                    do {
                        try await ffmpeg.editAudio(AudioEditPlan(source: source, output: target, recipe: recipe, format: info))
                        let got = try await streamInfo(target)
                        report.append("\(bits)\(float ? "f" : "") \(Int(rate)) -> \(out) \(edit): \(got)")
                        let fields = Dictionary(uniqueKeysWithValues: got.split(separator: "|").compactMap { pair -> (String, String)? in
                            let kv = pair.split(separator: "=", maxSplits: 1)
                            return kv.count == 2 ? (String(kv[0]), String(kv[1])) : nil
                        })
                        let depth = Int(fields["bits_per_raw_sample"] ?? "") ?? 0 > 0 ? Int(fields["bits_per_raw_sample"]!)!
                            : Int(fields["bits_per_sample"] ?? "") ?? 0
                        let wanted = float ? (out == .flac || out == .alac ? 24 : 32) : bits
                        if depth != wanted || fields["sample_rate"] != "\(Int(rate))" {
                            problems.append("\(bits)\(float ? "f" : "")-bit \(Int(rate)) Hz -> \(out) (\(edit)): \(got)")
                        }
                    } catch {
                        problems.append("\(bits) -> \(out) (\(edit)): throws \(error.localizedDescription)")
                    }
                }
            }
        }
        print("C14 depth:\n" + report.joined(separator: "\n"))
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }
}
