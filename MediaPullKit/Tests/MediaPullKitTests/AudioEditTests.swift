@preconcurrency import AVFoundation
import Foundation
@testable import MediaPullCore
@testable import MediaPullEngines
import XCTest

/// Section 46, audio (R-4610, D-131).
final class AudioEditTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("AudioEditTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func plan(_ source: String, _ format: AudioOutput, kept: [TimeRange] = [TimeRange(start: 0, end: 10)]) -> AudioEditPlan {
        AudioEditPlan(source: URL(fileURLWithPath: "/m/\(source)"), output: URL(fileURLWithPath: "/m/out.\(format.fileExtension)"),
                      format: format, kept: kept)
    }

    func testCopyingOnlyWhenNothingButCuts() {
        XCTAssertTrue(plan("a.mp3", .mp3).copiesStreams)
        XCTAssertTrue(plan("a.m4a", .aac).copiesStreams)
        XCTAssertFalse(plan("a.mp3", .aac).copiesStreams, "another format is encoded")
        XCTAssertFalse(plan("a.flac", .flac).copiesStreams, "lossless formats are cut to the sample by encoding again")
        var faded = plan("a.mp3", .mp3)
        faded.fadeIn = 1
        XCTAssertFalse(faded.copiesStreams)
        var louder = plan("a.mp3", .mp3)
        louder.normalize = true
        XCTAssertFalse(louder.copiesStreams)
        XCTAssertEqual(AudioOutput.like("OGG"), .aac)
        XCTAssertEqual(AudioOutput.like("aif"), .aiff)
    }

    func testArgumentsAndFilters() {
        var cut = plan("song's.mp3", .mp3, kept: [TimeRange(start: 1, end: 3), TimeRange(start: 5, end: 8)])
        cut.tags.title = "New Title"
        let list = AudioEdit.concatList(cut)
        XCTAssertTrue(list.contains("file '/m/song'\\''s.mp3'"), list)
        XCTAssertTrue(list.contains("inpoint 1.000000\noutpoint 3.000000"))
        let copy = AudioEdit.arguments(cut, list: URL(fileURLWithPath: "/tmp/l.ffconcat"))
        XCTAssertTrue(copy.contains("concat"))
        XCTAssertEqual(copy.firstIndex(of: "-c:a").map { copy[$0 + 1] }, "copy")
        XCTAssertTrue(copy.contains("title=New Title"))
        XCTAssertEqual(copy.firstIndex(of: "-map_metadata").map { copy[$0 + 1] }, "1", "tags from the original file")

        var encode = plan("a.wav", .mp3, kept: [TimeRange(start: 1, end: 3), TimeRange(start: 5, end: 8)])
        encode.fadeIn = 0.5
        encode.fadeOut = 1
        encode.volume = 1.5
        encode.normalize = true
        let graph = AudioEdit.filterGraph(encode)
        XCTAssertTrue(graph.contains("atrim=start=1.000000:end=3.000000"))
        XCTAssertTrue(graph.contains("concat=n=2:v=0:a=1"))
        XCTAssertTrue(graph.contains("afade=t=out:st=4.000:d=1.000"), graph)
        XCTAssertTrue(graph.contains("volume=1.500"))
        XCTAssertTrue(graph.hasSuffix("loudnorm=I=-16:TP=-1.5:LRA=11,aresample=44100,asetnsamples=n=4096:p=0[out]"), graph)
        let args = AudioEdit.arguments(encode, list: nil)
        XCTAssertEqual(args.firstIndex(of: "-c:a").map { args[$0 + 1] }, "libmp3lame")
        XCTAssertTrue(args.contains("-write_id3v1"))

        var art = plan("a.m4a", .alac)
        art.tags.artworkPath = "/m/cover.jpg"
        let withArt = AudioEdit.arguments(art, list: nil)
        XCTAssertTrue(withArt.contains("attached_pic"))
        XCTAssertEqual(withArt.last, "/m/out.m4a")
        XCTAssertEqual(withArt.firstIndex(of: "-f").map { withArt[$0 + 1] }, "ipod")
        var wav = plan("a.mp3", .wav)
        wav.tags.artworkPath = "/m/cover.jpg"
        XCTAssertFalse(AudioEdit.arguments(wav, list: nil).contains("attached_pic"), "WAV holds no picture")

        XCTAssertEqual(AudioEdit.peaks([0, 0.5, -1, 0.25, 0.1, -0.2], buckets: 3), [0.5, 1, 0.2])
        XCTAssertEqual(AudioEdit.peaks([], buckets: 3), [])
    }

    func testWholeFilesTagsDepthAndEnds() {
        // Nothing cut: the file itself, no trimming to a length that may be off (audit C1-M1, C1-m6).
        var whole = AudioEditPlan(source: URL(fileURLWithPath: "/m/a.mp3"), output: URL(fileURLWithPath: "/m/o.mp3"),
                                  recipe: EditRecipe(source: EditSource(path: "/m/a.mp3", kind: .audio)),
                                  format: AudioSourceFormat(duration: 60, codec: "mp3"))
        whole.tags.title = "T"
        XCTAssertTrue(whole.kept.isEmpty)
        let copy = AudioEdit.arguments(whole, list: nil)
        XCTAssertFalse(copy.contains("concat"))
        XCTAssertEqual(copy.firstIndex(of: "-c:a").map { copy[$0 + 1] }, "copy")
        XCTAssertFalse(copy.contains("-map_chapters"), "chapters kept when nothing is cut")
        whole.fadeIn = 1
        XCTAssertFalse(AudioEdit.filterGraph(whole).contains("atrim"))
        // A part reaching the end runs to the true end.
        var tail = plan("a.mp3", .mp3, kept: [TimeRange(start: 5, end: 60)])
        tail.sourceFormat = AudioSourceFormat(duration: 60)
        XCTAssertFalse(AudioEdit.concatList(tail).contains("outpoint"))
        XCTAssertFalse(AudioEdit.filterGraph(tail).contains(":end="))
        XCTAssertTrue(AudioEdit.arguments(tail, list: URL(fileURLWithPath: "/tmp/l")).contains("-map_chapters"))
        // Ogg keeps its tags on the stream; AIFF writes ID3 for all of them; 24-bit stays 24-bit; ALAC stays lossless.
        XCTAssertTrue(AudioEdit.arguments(plan("a.opus", .aac), list: nil).contains("-map_metadata:g"))
        XCTAssertTrue(AudioEdit.arguments(plan("a.wav", .aiff), list: nil).contains("-write_id3v2"))
        var deep = plan("a.wav", .wav)
        deep.sourceFormat = AudioSourceFormat(duration: 10, bits: 24)
        XCTAssertEqual(AudioEdit.arguments(deep, list: nil).firstIndex(of: "-c:a").map { AudioEdit.arguments(deep, list: nil)[$0 + 1] },
                       "pcm_s24le")
        XCTAssertEqual(AudioOutput.like("m4a", codec: "alac"), .alac)
        var lossless = plan("a.m4a", .aac)
        lossless.sourceFormat = AudioSourceFormat(duration: 10, codec: "alac")
        XCTAssertFalse(lossless.copiesStreams, "Apple Lossless is not copied as AAC")
        XCTAssertTrue(AudioEdit.filterGraph(plan("a.wav", .aac)).contains("aformat=sample_rates=48000"))
    }

    func testRoundTwoArguments() {
        // New artwork on a whole-file copy: the picture is input 1 (audit C2-2).
        var art = AudioEditPlan(source: URL(fileURLWithPath: "/m/a.mp3"), output: URL(fileURLWithPath: "/m/o.mp3"),
                                recipe: EditRecipe(source: EditSource(path: "/m/a.mp3", kind: .audio)),
                                format: AudioSourceFormat(duration: 10, codec: "mp3"))
        art.tags.artworkPath = "/m/cover.jpg"
        let args = AudioEdit.arguments(art, list: nil)
        XCTAssertTrue(args.contains("1:v:0"), "\(args)")
        // Floating-point PCM stays floating point; an Ogg FLAC stays FLAC.
        var float = plan("a.wav", .wav)
        float.sourceFormat = AudioSourceFormat(duration: 10, bits: 32, codec: "pcm_f32le")
        XCTAssertTrue(AudioEdit.arguments(float, list: nil).contains("pcm_f32le"))
        XCTAssertEqual(AudioOutput.like("oga", codec: "flac"), .flac)
    }

    func testRoundThreeArguments() {
        func encoder(_ ext: String, _ format: AudioOutput, bits: Int, codec: String) -> String? {
            var made = plan(ext, format)
            made.sourceFormat = AudioSourceFormat(duration: 10, bits: bits, codec: codec)
            let args = AudioEdit.arguments(made, list: nil)
            return args.firstIndex(of: "-c:a").map { args[$0 + 1] }
        }
        // The source's depth is kept, 32-bit and 64-bit float included (C3-7).
        XCTAssertEqual(encoder("a.wav", .wav, bits: 32, codec: "pcm_s32le"), "pcm_s32le")
        XCTAssertEqual(encoder("a.wav", .aiff, bits: 32, codec: "pcm_s32le"), "pcm_s32be")
        XCTAssertEqual(encoder("a.wav", .wav, bits: 64, codec: "pcm_f64le"), "pcm_f64le")
        XCTAssertEqual(encoder("a.wav", .wav, bits: 24, codec: "pcm_s24le"), "pcm_s24le")
        XCTAssertEqual(encoder("a.wav", .wav, bits: 16, codec: "pcm_s16le"), "pcm_s16le")
        // AIFF keeps artwork; WAV holds neither artwork nor an album artist (C3-3).
        XCTAssertTrue(AudioOutput.aiff.holdsArtwork)
        XCTAssertFalse(AudioOutput.wav.holdsArtwork)
        XCTAssertFalse(AudioOutput.wav.holdsAlbumArtist)
        var art = plan("a.aiff", .aiff)
        art.tags.artworkPath = "/m/cover.jpg"
        XCTAssertTrue(AudioEdit.arguments(art, list: nil).contains("attached_pic"))
        // Only cover art goes with the sound, never another picture track (C4-3).
        let kept = AudioEdit.arguments(plan("a.m4a", .aac), list: nil)
        XCTAssertTrue(kept.contains("0:v:disp:attached_pic?"), "\(kept)")
        // A BMP or GIF cover is turned into PNG; a JPEG one is copied as it is (C5-1).
        var bitmap = plan("a.mp3", .aac)
        bitmap.sourceFormat = AudioSourceFormat(duration: 10, codec: "mp3", artworkCodec: "bmp")
        let turned = AudioEdit.arguments(bitmap, list: nil)
        XCTAssertEqual(turned.firstIndex(of: "-c:v").map { turned[$0 + 1] }, "png")
        bitmap.sourceFormat?.artworkCodec = "mjpeg"
        let copied = AudioEdit.arguments(bitmap, list: nil)
        XCTAssertEqual(copied.firstIndex(of: "-c:v").map { copied[$0 + 1] }, "copy")
    }

    /// The real engine: a tone cut losslessly, faded, normalised and converted (skipped when ffmpeg is not built).
    func testTheBundledEngineEditsAudio() async throws {
        let ffmpeg = FFmpeg(ffmpeg: TestEngines.ffmpegFolder.appendingPathComponent("ffmpeg"),
                            ffprobe: TestEngines.ffmpegFolder.appendingPathComponent("ffprobe"))
        try XCTSkipUnless(ffmpeg.isAvailable, "ffmpeg is not built")
        // A 6 s tone, quiet.
        let wav = folder.appendingPathComponent("tone.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let file = try AVAudioFile(forWriting: wav, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100,
                                                               AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                                               AVLinearPCMIsFloatKey: false])
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 6)!
        buffer.frameLength = 44100 * 6
        for i in 0 ..< Int(buffer.frameLength) {
            buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 44100) * 0.1)
        }
        try file.write(from: buffer)

        // To MP3 (needs LAME), tagged.
        let mp3 = folder.appendingPathComponent("tone.mp3")
        var toMP3 = AudioEditPlan(source: wav, output: mp3, format: .mp3, kept: [TimeRange(start: 0, end: 6)])
        toMP3.tags.title = "Tone"
        toMP3.tags.artist = "Tester"
        try await ffmpeg.editAudio(toMP3)
        let read = await ffmpeg.audioTags(mp3)
        let tags = try XCTUnwrap(read)
        XCTAssertEqual(tags.tags.title, "Tone")
        XCTAssertEqual(tags.tags.codec, "MP3")
        XCTAssertEqual(try XCTUnwrap(tags.duration), 6, accuracy: 0.1)

        // A VBR MP3 without a Xing header: its length is measured, not guessed from the bit rate (audit C2-1).
        let noXing = folder.appendingPathComponent("noxing.mp3")
        _ = try await FFmpeg.run(ffmpeg.ffmpeg, ["-hide_banner", "-nostdin", "-v", "error", "-y", "-i", wav.path, "-c:a", "libmp3lame",
                                                 "-q:a", "6", "-write_xing", "0", noXing.path])
        let measured = await ffmpeg.audioFormat(noXing)
        XCTAssertEqual(try XCTUnwrap(measured?.duration), 6, accuracy: 0.1)

        // Cut losslessly: the kept frames are copied (the same audio packets as the original's).
        let cut = folder.appendingPathComponent("cut.mp3")
        let cutPlan = AudioEditPlan(source: mp3, output: cut, format: .mp3, kept: [TimeRange(start: 1, end: 3)])
        XCTAssertTrue(cutPlan.copiesStreams)
        try await ffmpeg.editAudio(cutPlan)
        let cutRead = await ffmpeg.audioTags(cut)
        let cutTags = try XCTUnwrap(cutRead)
        XCTAssertEqual(try XCTUnwrap(cutTags.duration), 2, accuracy: 0.1)
        XCTAssertEqual(cutTags.tags.title, "Tone", "tags kept")

        // Faded, normalised, as FLAC and M4A: louder and decodable.
        // From WAV and from MP3 (decoded as floats; loudness normalisation hands on one long frame).
        let cases: [(URL, AudioOutput)] = [(wav, .flac), (wav, .aac), (wav, .alac), (wav, .aiff), (mp3, .flac), (mp3, .alac), (mp3, .mp3)]
        for (source, output) in cases {
            let url = folder.appendingPathComponent("out-\(source.pathExtension)-\(output.rawValue).\(output.fileExtension)")
            var edit = AudioEditPlan(source: source, output: url, format: output, kept: [TimeRange(start: 0, end: 6)])
            edit.fadeIn = 1
            edit.normalize = true
            do {
                try await ffmpeg.editAudio(edit)
            } catch {
                XCTFail("\(output): \(error.localizedDescription) \(AudioEdit.arguments(edit, list: nil).joined(separator: " "))")
                continue
            }
            let peaks: [Float]
            do {
                peaks = try await ffmpeg.waveform(url, buckets: 12)
            } catch {
                XCTFail("waveform \(output): \(String(reflecting: error)) exists \(FileManager.default.fileExists(atPath: url.path))")
                continue
            }
            XCTAssertEqual(peaks.count, 12, "\(output)")
            XCTAssertLessThan(peaks[0], peaks[6], "\(output) fades in")
            XCTAssertGreaterThan(peaks[6], 0.2, "\(output) normalised up from 0.1")
        }
        let original = try await ffmpeg.waveform(wav, buckets: 12)
        XCTAssertEqual(try XCTUnwrap(original.max()), 0.1, accuracy: 0.02)
    }
}
