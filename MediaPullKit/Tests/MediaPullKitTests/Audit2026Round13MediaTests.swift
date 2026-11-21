/// Audit 2026-11-22, round 13 (auditor C): video and audio editing.
@preconcurrency import AVFoundation
import CryptoKit
import Foundation
@testable import MediaPullCore
@testable import MediaPullEdit
@testable import MediaPullEngines
import XCTest

extension VideoEditTests {
    /// RMS of a whole channel's middle second.
    @nonobjc func c13level(_ s: [Float], rate: Double) -> Double {
        let mid = Double(s.count) / rate / 2
        return c12rms(s, rate: rate, from: mid - 0.5, to: mid + 0.5)
    }

    /// The amplitude of a tone of `hz` in the middle second of a channel.
    @nonobjc func c13tone(_ s: [Float], hz: Double, rate: Double) -> Double {
        let mid = s.count / 2, n = min(Int(rate), mid)
        var re = 0.0, im = 0.0
        for i in mid - n / 2 ..< mid + n / 2 {
            let a = 2 * Double.pi * hz * Double(i) / rate
            re += Double(s[i]) * cos(a)
            im += Double(s[i]) * sin(a)
        }
        return 2 * (re * re + im * im).squareRoot() / Double(n / 2 * 2)
    }

    /// For each tone, its loudest amplitude in any channel of `url`.
    @nonobjc func c13toneLevels(_ url: URL, tones: [Int]) async throws -> [Int: Double] {
        let got = try await c11readSound(url)
        var out: [Int: Double] = [:]
        for t in tones { out[t] = got.samples.map { c13tone($0, hz: Double(t), rate: got.rate) }.max() ?? 0 }
        return out
    }

    /// Each channel's tone and level, in file order.
    @nonobjc func c13channels(_ url: URL) async throws -> [(hz: Int, level: Double)] {
        let got = try await c11readSound(url)
        return got.samples.map { s in
            let mid = s.count / 2
            let n = min(4800, mid)
            return (Int(c11frequency(s[mid - n ..< mid + n], rate: got.rate).rounded()), c13level(s, rate: got.rate))
        }
    }

    /// A sound of `n` channels with no labels (discrete, as pro cameras and multitrack recorders write it): each channel
    /// is kept on a re-encode, at normal speed and at another speed, rather than silenced or dropped.
    func testC13UnlabelledSurroundKeepsEveryChannelOnAReencode() async throws {
        var problems: [String] = []
        for n in [3, 5, 6, 7, 8] {
            let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(n))!
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
            let tones = (0 ..< n).map { 200 + 100 * $0 }
            let source = try await c12clip(format: format) { c, i in Float(sin(Double(i) * 2 * .pi * Double(tones[c]) / 48000) * 0.3) }
            let before = try await c13channels(source)
            var system = "?"
            do {
                var edit = recipe(source)
                edit.adjust.exposure = 0.01
                let built = try await VideoComposer.build(AVURLAsset(url: source), recipe: edit)
                let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHEVCHighestQuality)!
                session.videoComposition = built.videoComposition
                let out = folder.appendingPathComponent("sys-\(UUID().uuidString).mov")
                try await session.export(to: out, as: .mov)
                let got = try await c13channels(out)
                system = "\(got.count) channels, \(got.filter { $0.level > 0.05 }.map(\.hz)) with sound"
            } catch {
                system = "throws \(error.localizedDescription)"
            }
            for speed in [1.0, 2.0] {
                do {
                    let out = try await c12export(source, speed: speed)
                    let got = try await c13channels(out)
                    // Six channels or more: the last is the encoder's LFE, low-passed by the system's own exporter too.
                    let lfe = n >= 6 ? n - 1 : -1
                    let silent = got.enumerated().filter { $0.element.level < 0.05 && $0.offset != lfe }.map(\.offset)
                    let present = Set(got.filter { $0.level >= 0.05 }.map { ($0.hz + 50) / 100 * 100 })
                    let lost = tones.enumerated().filter { $0.offset != lfe && !present.contains($0.element) }.map(\.element)
                    if got.count != n || !silent.isEmpty || !lost.isEmpty {
                        problems.append("\(n) discrete at \(speed)x: source \(before.map(\.hz)), export \(got.count) channels "
                            + "\(got.map { "\($0.hz) Hz @\(String(format: "%.2f", $0.level))" }), silent \(silent), "
                            + "tones lost \(lost); system exporter alone at 1x: \(system)")
                    }
                } catch {
                    problems.append("\(n) discrete at \(speed)x: throws \(error.localizedDescription)")
                }
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    /// Labelled layouts whose labels are not all in the AAC encoder's layout of that count, and sound written by ffmpeg
    /// (5.1 side, or channels with no layout): no channel that has sound goes silent on a re-encode at normal speed.
    func testC13NoChannelGoesSilentOnAReencode() async throws {
        var problems: [String] = []
        let ffmpeg = FFmpeg(ffmpeg: TestEngines.ffmpegFolder.appendingPathComponent("ffmpeg"),
                            ffprobe: TestEngines.ffmpegFolder.appendingPathComponent("ffprobe"))
        var sources: [(String, URL, [Int])] = []
        for (name, tag) in [("6.0 L R Ls Rs C Cs", kAudioChannelLayoutTag_AudioUnit_6_0),
                            ("7.0 L R Ls Rs C Rls Rrs", kAudioChannelLayoutTag_AudioUnit_7_0),
                            ("7.1 wide C Lc Rc L R Ls Rs LFE", kAudioChannelLayoutTag_MPEG_7_1_B),
                            ("5.0 C L R Ls Rs (AAC order)", kAudioChannelLayoutTag_MPEG_5_0_D),
                            ("3.0 L R Cs", kAudioChannelLayoutTag_ITU_2_1)] {
            let layout = AVAudioChannelLayout(layoutTag: tag)!
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
            let n = Int(format.channelCount)
            let labels = (0 ..< n).map { Int(layout.layout.pointee.mNumberChannelDescriptions) > 0 ? 0 : $0 }
            _ = labels
            let lfe = (0 ..< n).first { i in
                let tagged = AVAudioChannelLayout(layoutTag: tag)!
                var size = UInt32(0)
                var t = tagged.layoutTag
                AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag, 4, &t, &size)
                let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
                defer { raw.deallocate() }
                AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag, 4, &t, &size, raw)
                let l = raw.assumingMemoryBound(to: AudioChannelLayout.self)
                return withUnsafePointer(to: &l.pointee.mChannelDescriptions) { p in
                    p.withMemoryRebound(to: AudioChannelDescription.self,
                                        capacity: n) { $0[i].mChannelLabel == kAudioChannelLabel_LFEScreen }
                }
            }
            let tones = (0 ..< n).map { $0 == lfe ? 100 : 200 + 100 * $0 }
            let url = try await c12clip(format: format) { c, i in Float(sin(Double(i) * 2 * .pi * Double(tones[c]) / 48000) * 0.3) }
            sources.append((name, url, tones))
        }
        if ffmpeg.isAvailable {
            let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)!
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
            let tones = [200, 300, 400, 100, 600, 700]
            let mov = try await c12clip(format: format) { c, i in Float(sin(Double(i) * 2 * .pi * Double(tones[c]) / 48000) * 0.3) }
            for (name, args) in [("ffmpeg 5.1(side) PCM MOV", ["-ch_layout", "5.1(side)", "-c:a", "pcm_s16le"]),
                                 ("ffmpeg 6 unlabelled PCM MOV", ["-ch_layout", "6 channels", "-c:a", "pcm_s16le"])] {
                let out = folder.appendingPathComponent("ff-\(UUID().uuidString).mov")
                do {
                    _ = try await FFmpeg.run(ffmpeg.ffmpeg, ["-hide_banner", "-nostdin", "-v", "error", "-y", "-i", mov.path, "-c:v",
                                                             "copy"]
                        + args + [out.path])
                    sources.append((name, out, tones))
                } catch {
                    print("C13 could not make \(name): \(error)")
                }
            }
        }
        for (name, url, tones) in sources {
            let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)[0]
            let description = try await track.load(.formatDescriptions)[0]
            let tag = AVAudioFormat(cmAudioFormatDescription: description).channelLayout?.layoutTag ?? 0
            do {
                let out = try await c12export(url, speed: 1)
                let levels = try await c13toneLevels(out, tones: tones)
                let lost = tones.filter { (levels[$0] ?? 0) < 0.05 }
                print("C13 \(name) (tag \(tag >> 16)|\(tag & 0xFFFF)): " + tones.map { String(format: "%d Hz %.2f", $0,
                                                                                              levels[$0] ?? 0) }.joined(separator: ", "))
                if !lost.isEmpty {
                    problems.append("\(name) (tag \(tag >> 16)|\(tag & 0xFFFF)): tones lost \(lost)")
                }
            } catch {
                problems.append("\(name): throws \(error.localizedDescription)")
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    /// Six channels labelled Discrete 0 to 5 or Unknown (channel descriptions, as some editors write them): kept on a re-encode.
    func testC13DiscreteLabelledChannelsAreKept() async throws {
        var problems: [String] = []
        for (name, label) in [("Discrete_n", { (k: UInt32) in AudioChannelLabel(kAudioChannelLabel_Discrete_0 | k) }),
                              ("Unknown", { (_: UInt32) in AudioChannelLabel(kAudioChannelLabel_Unknown) })] {
            let n = 6
            let size = MemoryLayout<AudioChannelLayout>.size + (n - 1) * MemoryLayout<AudioChannelDescription>.size
            let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
            defer { raw.deallocate() }
            memset(raw, 0, size)
            let l = raw.assumingMemoryBound(to: AudioChannelLayout.self)
            l.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
            l.pointee.mNumberChannelDescriptions = UInt32(n)
            withUnsafeMutablePointer(to: &l.pointee.mChannelDescriptions) { p in
                p.withMemoryRebound(to: AudioChannelDescription.self, capacity: n) { d in
                    for k in 0 ..< n { d[k].mChannelLabel = label(UInt32(k)) }
                }
            }
            let layout = AVAudioChannelLayout(layout: l)
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
            let tones = (0 ..< n).map { 200 + 100 * $0 }
            do {
                let url = try await c12clip(format: format) { c, i in Float(sin(Double(i) * 2 * .pi * Double(tones[c]) / 48000) * 0.3) }
                let levels = try await c13toneLevels(try await c12export(url, speed: 1), tones: tones)
                // The sixth of six channels is the encoder's LFE, low-passed by the system's own exporter too (not counted).
                let lost = tones.dropLast().filter { (levels[$0] ?? 0) < 0.05 }
                if !lost.isEmpty { problems.append("\(name): tones lost \(lost)") }
            } catch {
                problems.append("\(name): throws \(error.localizedDescription)")
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    /// The codec chosen is the codec written, whatever the source's (an HEVC or ProRes source exported as H.264).
    func testC13ChosenCodecIsWritten() async throws {
        var problems: [String] = []
        for (name, codec) in [("hevc", AVVideoCodecType.hevc), ("prores", AVVideoCodecType.proRes422), ("h264", AVVideoCodecType.h264)] {
            let src = folder.appendingPathComponent("src-\(name).mov")
            let writer = try AVAssetWriter(outputURL: src, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: codec, AVVideoWidthKey: 640,
                                                                               AVVideoHeightKey: 360])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 640,
                kCVPixelBufferHeightKey as String: 360])
            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            for frame in 0 ..< 50 {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
                adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 25))
            }
            input.markAsFinished()
            await writer.finishWriting()
            for chosen in ExportSettings.VideoCodec.allCases {
                for container in ExportSettings.VideoContainer.allCases {
                    var edit = recipe(src)
                    edit.adjust.exposure = 0.1
                    edit.export.videoCodec = chosen
                    edit.export.videoContainer = container
                    let out = folder.appendingPathComponent("out-\(name)-\(chosen.rawValue).\(container.rawValue)")
                    do {
                        _ = try await VideoComposer.export(src, recipe: edit, to: out) { _ in }
                        let f = try await facts(out)
                        let want: FourCharCode = chosen == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
                        if f.codec != want {
                            let codec = f.codec.map { String(format: "%08x", $0) } ?? "nil"
                            problems.append("\(name) as \(chosen) \(container): wrote \(codec)")
                        }
                    } catch {
                        problems.append("\(name) as \(chosen) \(container): throws \(error.localizedDescription)")
                    }
                }
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    /// A 29.97 fps clip re-encoded keeps its frame rate and its frames (no frame shown twice).
    func testC13NTSCFrameRateIsKept() async throws {
        let src = folder.appendingPathComponent("ntsc.mov")
        let writer = try AVAssetWriter(outputURL: src, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320,
                                                                            AVVideoHeightKey: 180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 180])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let frames = 1200
        for frame in 0 ..< frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame) * 1001, timescale: 30000))
        }
        input.markAsFinished()
        await writer.finishWriting()
        var edit = recipe(src)
        edit.adjust.exposure = 0.1
        let out = folder.appendingPathComponent("ntsc-out.mov")
        _ = try await VideoComposer.export(src, recipe: edit, to: out) { _ in }
        func count(_ url: URL) async throws -> (Int, Float) {
            let asset = AVURLAsset(url: url)
            let track = try await asset.loadTracks(withMediaType: .video)[0]
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            reader.startReading()
            var n = 0
            while let b = output.copyNextSampleBuffer() { if CMSampleBufferGetNumSamples(b) > 0 { n += 1 } }
            return (n, try await track.load(.nominalFrameRate))
        }
        let a = try await count(src), b = try await count(out)
        print("C13 29.97: source \(a), export \(b)")
        XCTAssertEqual(b.0, a.0, "frames: source \(a), export \(b)")
    }

    /// 6.1 (seven channels) stays in place by label on a re-encode, like 5.1.
    func testC13SixOneKeepsItsChannels() async throws {
        var problems: [String] = []
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_6_1_A)!
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
        let tones = (0 ..< 7).map { $0 == 3 ? 100 : 200 + 100 * $0 }
        let source = try await c12clip(format: format) { c, i in Float(sin(Double(i) * 2 * .pi * Double(tones[c]) / 48000) * 0.3) }
        let before = try await c12frequencies(source, in: layout)
        for speed in [1.0, 2.0] {
            do {
                let out = try await c12export(source, speed: speed)
                let got = try await c12frequencies(out, in: layout)
                if zip(before, got).contains(where: { abs($0 - $1) > 15 }) {
                    problems.append("6.1 at \(speed)x: source \(before), export \(got)")
                }
            } catch {
                problems.append("6.1 at \(speed)x: throws \(error.localizedDescription)")
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    /// More than eight channels (second-order ambisonics, 10 or 16 discrete channels): a re-encode at normal speed
    /// is written, or refused with a reason, and does not do worse than the system's exporter alone did before C12-1.
    func testC13ManyChannelsOnAReencodeAtNormalSpeed() async throws {
        var problems: [String] = []
        for (name, tag) in [("HOA 2nd order (9)", kAudioChannelLayoutTag_HOA_ACN_SN3D | 9),
                            ("10 discrete", kAudioChannelLayoutTag_DiscreteInOrder | 10),
                            ("16 discrete", kAudioChannelLayoutTag_DiscreteInOrder | 16)] {
            let layout = AVAudioChannelLayout(layoutTag: tag)!
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
            let n = Int(format.channelCount)
            let source = try await c12clip(format: format) { c, i in Float(sin(Double(i) * 2 * .pi * Double(200 + 50 * c) / 48000) * 0.3) }
            // What the system's exporter alone does with this composition (the path before C12-1).
            var system = "?"
            do {
                let asset = AVURLAsset(url: source)
                var edit = recipe(source)
                edit.adjust.exposure = 0.01
                let built = try await VideoComposer.build(asset, recipe: edit)
                let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHEVCHighestQuality)!
                session.videoComposition = built.videoComposition
                let out = folder.appendingPathComponent("sys-\(UUID().uuidString).mov")
                try await session.export(to: out, as: .mov)
                let got = try await c13channels(out)
                system = "\(got.count) channels, \(got.filter { $0.level > 0.05 }.count) with sound"
            } catch {
                system = "throws \(error.localizedDescription)"
            }
            do {
                let out = try await c12export(source, speed: 1)
                let got = try await c13channels(out)
                let sounding = got.filter { $0.level > 0.05 }.count
                if sounding < min(n, 8) {
                    problems.append("\(name): export has \(got.count) channels, \(sounding) with sound (system alone: \(system))")
                }
            } catch {
                // A sound the system itself cannot decode is not counted (the fixture, not MediaPull).
                if !system.hasPrefix("throws") {
                    problems.append("\(name): throws \(error.localizedDescription) (system alone: \(system))")
                }
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    /// The compressed audio packets of a file's first sound track.
    @nonobjc func c13audioDigest(_ url: URL) async throws -> String {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .audio)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var bytes = 0, hash = SHA256()
        while let b = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(b) else { continue }
            let len = CMBlockBufferGetDataLength(block)
            var d = Data(count: len)
            _ = d.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            hash.update(data: d)
            bytes += len
        }
        return "\(bytes)/" + hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A cut and a turn of a 5.1 video are passthrough for the sound too: never rendered (C12-1 renders only re-encodes).
    func testC13LosslessSurroundIsNeverRendered() async throws {
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)!
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
        let source = try await c12clip(format: format) { c, i in Float(sin(Double(i) * 2 * .pi * Double(200 + 100 * c) / 48000) * 0.3) }
        var edit = recipe(source)
        edit.geometry.quarterTurns = 1
        var time = EditTimeline()
        time.kept = [TimeRange(start: 0, end: 4)]
        edit.timeline = time
        let out = folder.appendingPathComponent("c13-lossless.mov")
        let built = try await VideoComposer.export(source, recipe: edit, to: out) { _ in }
        XCTAssertTrue(built.lossless)
        let a = try await c13audioDigest(source), b = try await c13audioDigest(out)
        XCTAssertEqual(a, b, "the 5.1 sound is copied as it is")
        let leftovers = (try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()))
            .filter { $0.hasPrefix("MediaPull-sound-") }
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
    }

    /// At normal speed a 5.1 video with a fade in and half volume: the rendered track gets both.
    func testC13SurroundAtNormalSpeedTakesFadesAndVolume() async throws {
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)!
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
        let source = try await c12clip(format: format) { c, i in c < 3 ? Float(sin(Double(i) * 2 * .pi * 500 / 48000) * 0.5) : 0 }
        let plain = try await c11readSound(try await c12export(source, speed: 1))
        let edited = try await c11readSound(try await c12export(source, speed: 1, fadeIn: 1, volume: 0.5))
        let full = c12rms(plain.samples[0], rate: plain.rate, from: 2, to: 3)
        let half = c12rms(edited.samples[0], rate: edited.rate, from: 2, to: 3)
        let start = c12rms(edited.samples[0], rate: edited.rate, from: 0, to: 0.1)
        XCTAssertEqual(half / full, 0.5, accuracy: 0.05, "volume")
        XCTAssertLessThan(start, full * 0.1, "fade in")
        // Mono and stereo at normal speed are not rendered: the export's sound is the composition's.
        let mono = try await SoundAtSpeed.channels(of: AVURLAsset(url: try await clip()))
        XCTAssertEqual(mono, 1)
    }

    /// An edited MOV written as MP4 keeps its capture date (R-4609), as an MP4 does.
    func testC13MOVWrittenAsMP4KeepsItsCaptureDate() async throws {
        let base = try await clip()
        let dated = folder.appendingPathComponent("dated.mov")
        let session = AVAssetExportSession(asset: AVURLAsset(url: base), presetName: AVAssetExportPresetPassthrough)!
        let date = AVMutableMetadataItem()
        date.identifier = .quickTimeMetadataCreationDate
        date.value = "2019-06-01T10:20:30+0200" as NSString
        date.dataType = kCMMetadataBaseDataType_UTF8 as String
        let make = AVMutableMetadataItem()
        make.identifier = .quickTimeMetadataMake
        make.value = "Apple" as NSString
        session.metadata = [date, make]
        try await session.export(to: dated, as: .mov)
        var problems: [String] = []
        for (lossless, ext) in [(true, "mp4"), (false, "mp4"), (false, "mov")] {
            var edit = recipe(dated)
            if !lossless { edit.adjust.exposure = 0.1 }
            edit.export.videoContainer = ext == "mp4" ? .mp4 : .mov
            let out = folder.appendingPathComponent("dated-\(lossless)-\(UUID().uuidString).\(ext)")
            _ = try await VideoComposer.export(dated, recipe: edit, to: out) { _ in }
            let asset = AVURLAsset(url: out)
            let created = try await asset.load(.creationDate)
            let value = try await created?.load(.dateValue)
            let text = try await created?.load(.stringValue)
            if value == nil && text == nil { problems.append("\(lossless ? "lossless" : "re-encoded") \(ext): no capture date") }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }
}

/// Audio (R-4610): the waveform.
final class Audit2026Round13AudioTests: XCTestCase {
    var folder: URL!
    let ffmpeg = FFmpeg(ffmpeg: TestEngines.ffmpegFolder.appendingPathComponent("ffmpeg"),
                        ffprobe: TestEngines.ffmpegFolder.appendingPathComponent("ffprobe"))

    override func setUpWithError() throws {
        try XCTSkipUnless(ffmpeg.isAvailable, "ffmpeg is not built")
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("C13Audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// A WAV of `seconds`, `channels`, holding a tone of `hz` at `level` (16-bit).
    @nonobjc func wav(_ name: String, hz: Double, level: Float = 0.5, rate: Double = 44100, channels: Int = 2,
                      seconds: Double = 3) throws -> URL
    {
        let url = folder.appendingPathComponent(name)
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                                               AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16,
                                                               AVLinearPCMIsFloatKey: false])
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels))!
        let chunk = AVAudioFrameCount(rate * 10)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
        var done = 0
        let total = Int(rate * seconds)
        while done < total {
            let n = min(Int(chunk), total - done)
            buffer.frameLength = AVAudioFrameCount(n)
            for c in 0 ..< channels {
                let p = buffer.floatChannelData![c]
                for i in 0 ..< n { p[i] = Float(sin(Double(done + i) * 2 * .pi * hz / rate)) * level }
            }
            try file.write(from: buffer)
            done += n
        }
        return url
    }

    /// A loud high tone (a whistle, cymbals, birdsong) is drawn as loud as it is, not as silence: the waveform's
    /// decode at 2 kHz filters away everything above 1 kHz.
    func testC13WaveformShowsHighSounds() async throws {
        var problems: [String] = []
        for hz in [440.0, 1500, 3000, 8000] {
            let url = try wav("tone\(Int(hz)).wav", hz: hz)
            let peaks = try await ffmpeg.waveform(url, buckets: 20)
            let top = peaks.max() ?? 0
            print("C13 \(hz) Hz peaks max \(top)")
            if top < 0.35 { problems.append(String(format: "%.0f Hz at 0.5: drawn at %.3f", hz, top)) }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    /// The amplitude of `hz` in the middle second of each channel of a file, decoded by ffmpeg in its own order.
    @nonobjc func channelTones(_ url: URL, tones: [Int]) async throws -> (channels: Int, layout: String, levels: [[Double]]) {
        let info = try await FFmpeg.run(ffmpeg.ffprobe, ["-v", "error", "-select_streams", "a:0", "-show_entries",
                                                         "stream=channels,channel_layout", "-of", "csv=p=0", url.path])
        let parts = info.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",")
        let n = Int(parts.first ?? "0") ?? 0
        let raw = folder.appendingPathComponent("dec-\(UUID().uuidString).f32")
        _ = try await FFmpeg.run(ffmpeg.ffmpeg, ["-hide_banner", "-nostdin", "-v", "error", "-y", "-i", url.path, "-map", "0:a:0",
                                                 "-ar", "48000", "-f", "f32le", raw.path])
        let data = try Data(contentsOf: raw)
        let all = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var levels: [[Double]] = []
        for c in 0 ..< n {
            let ch = stride(from: c, to: all.count, by: n).map { all[$0] }
            let mid = ch.count / 2, m = 24000
            levels.append(tones.map { hz in
                var re = 0.0, im = 0.0
                for i in mid - m ..< mid + m {
                    let a = 2 * Double.pi * Double(hz) * Double(i) / 48000
                    re += Double(ch[i]) * cos(a); im += Double(ch[i]) * sin(a)
                }
                return 2 * (re * re + im * im).squareRoot() / Double(2 * m)
            })
        }
        return (n, parts.count > 1 ? String(parts[1]) : "", levels)
    }

    /// A 5.1 WAV edited (volume, so it is encoded) into every format: written, and each channel's sound kept or folded
    /// down where the format cannot hold 5.1 (MP3), never lost.
    func testC13FiveOneAudioIntoEveryFormat() async throws {
        let url = folder.appendingPathComponent("51.wav")
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)!
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
        let tones = [200, 300, 400, 100, 600, 700]
        do {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000,
                                                                   AVNumberOfChannelsKey: 6, AVLinearPCMBitDepthKey: 16,
                                                                   AVLinearPCMIsFloatKey: false,
                                                                   AVChannelLayoutKey: SoundAtSpeed.data(of: layout)])
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000 * 3)!
            buffer.frameLength = buffer.frameCapacity
            for c in 0 ..< 6 {
                for i in 0 ..< 48000 * 3 {
                    buffer.floatChannelData![c][i] = Float(sin(Double(i) * 2 * .pi * Double(tones[c]) / 48000) * 0.3)
                }
            }
            try file.write(from: buffer)
        }
        let source = try await channelTones(url, tones: tones)
        print("C13 source: \(source.channels) \(source.layout)")
        var problems: [String] = []
        // MP3 holds two channels at most: surround is mixed to stereo there (recorded, audit 2026-11-21-13).
        for out in AudioOutput.allCases where out != .mp3 {
            var recipe = EditRecipe(source: EditSource(path: url.path, kind: .audio))
            var time = EditTimeline()
            time.volume = 0.9
            recipe.timeline = time
            recipe.export.audioFormat = out
            let measured = await ffmpeg.audioFormat(url)
            let info = try XCTUnwrap(measured)
            let target = folder.appendingPathComponent("51-\(out.rawValue).\(out.fileExtension)")
            do {
                try await ffmpeg.editAudio(AudioEditPlan(source: url, output: target, recipe: recipe, format: info))
                let got = try await channelTones(target, tones: tones)
                let lost = tones.enumerated().filter { k, _ in got.levels.map { $0[k] }.max() ?? 0 < 0.05 }.map(\.element)
                let order = got.levels.map { row in tones[row.firstIndex(of: row.max()!)!] }
                print("C13 \(out): \(got.channels) \(got.layout) order \(order)")
                if !lost.isEmpty { problems.append("\(out): \(got.channels) channels \(got.layout), tones lost \(lost)") }
                if got.channels == 6, order != tones { problems.append("\(out): channels moved, \(order)") }
            } catch {
                problems.append("\(out): throws \(error.localizedDescription)")
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    /// Memory and time of the waveform of a long many-channel file.
    func testC13WaveformOfALongFile() async throws {
        // An hour in the checks (C13_HOURS for longer): memory must not grow with the length.
        let hours = Double(ProcessInfo.processInfo.environment["C13_HOURS"] ?? "1") ?? 1
        let url = try wav("long.wav", hz: 200, rate: 8000, channels: 2, seconds: hours * 3600)
        func rss() -> Int {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return usage.ru_maxrss / 1_048_576
        }
        let before = rss()
        let start = Date()
        let peaks = try await ffmpeg.waveform(url, buckets: 1200)
        let elapsed = Date().timeIntervalSince(start)
        let after = rss()
        print(String(format: "C13 waveform %.1f h stereo: %.1f s, peak RSS %d MB -> %d MB, %d peaks", hours, elapsed, before, after,
                     peaks.count))
        XCTAssertLessThan(after - before, 300, "peak memory grows by \(after - before) MB for \(hours) h of stereo")
    }
}
