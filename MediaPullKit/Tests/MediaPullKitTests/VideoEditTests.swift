@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
@testable import MediaPullCore
@testable import MediaPullEdit
@testable import MediaPullEngines
import XCTest

/// Section 46, video (R-4609, D-130).
final class VideoEditTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("VideoEditTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A 4 s, 640 × 360, 25 fps H.264 clip with a key frame every second and a tone, shown turned when `portrait`.
    /// `soundLonger`: seconds of sound past the picture's end, as some cameras and edits leave.
    func clip(portrait: Bool = false, soundLonger: Double = 0) async throws -> URL {
        let video = folder.appendingPathComponent("video-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: video, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 25],
        ])
        if portrait { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 640,
            kCVPixelBufferHeightKey as String: 360,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0 ..< 100 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            guard let pixels = buffer else { continue }
            CVPixelBufferLockBaseAddress(pixels, [])
            if let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: 640, height: 360, bitsPerComponent: 8,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            {
                context.setFillColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
                context.setFillColor(red: 0.95, green: 0.6, blue: 0.3, alpha: 1)
                context.fill(CGRect(x: 40 + frame * 5, y: 120, width: 120, height: 120))
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 25))
        }
        input.markAsFinished()
        await writer.finishWriting()
        // A 4 s tone, then the two joined into one file without re-encoding.
        let tone = folder.appendingPathComponent("tone-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let file = try AVAudioFile(forWriting: tone, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 5)!
        buffer.frameLength = 44100 * 5
        for i in 0 ..< Int(buffer.frameLength) {
            buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 44100) * 0.3)
        }
        try file.write(from: buffer)
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: tone)
        let videoTrack = try await videoAsset.loadTracks(withMediaType: .video)[0]
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 4, preferredTimescale: 600))
        let v = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try v.insertTimeRange(range, of: videoTrack, at: .zero)
        v.preferredTransform = try await videoTrack.load(.preferredTransform)
        let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let sound = CMTimeRange(start: .zero, duration: CMTime(seconds: 4 + soundLonger, preferredTimescale: 600))
        try a.insertTimeRange(sound, of: try await audioAsset.loadTracks(withMediaType: .audio)[0], at: .zero)
        let output = folder.appendingPathComponent("clip-\(UUID().uuidString).mov")
        let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        try await session.export(to: output, as: .mov)
        return output
    }

    func recipe(_ url: URL) -> EditRecipe {
        EditRecipe(source: EditSource(path: url.path, kind: .video))
    }

    func facts(_ url: URL) async throws -> (duration: Double, size: CGSize, audio: Bool, codec: FourCharCode?) {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let size = CGRect(origin: .zero, size: natural).applying(transform).standardized.size
        let formats = try await track.load(.formatDescriptions)
        return (try await asset.load(.duration).seconds, size, !(try await asset.loadTracks(withMediaType: .audio)).isEmpty,
                formats.first.map { CMFormatDescriptionGetMediaSubType($0) })
    }

    func testTimelineMath() {
        var time = EditTimeline()
        XCTAssertEqual(time.keptRanges(duration: 10), [TimeRange(start: 0, end: 10)])
        time.kept = [TimeRange(start: 6, end: 12), TimeRange(start: 1, end: 3), TimeRange(start: 2.5, end: 4)]
        XCTAssertEqual(time.keptRanges(duration: 10), [TimeRange(start: 1, end: 4), TimeRange(start: 6, end: 10)])
        XCTAssertEqual(time.resultDuration(of: 10), 7, accuracy: 1e-9)
        time.speed = 2
        XCTAssertEqual(time.resultDuration(of: 10), 3.5, accuracy: 1e-9)
        XCTAssertFalse(time.cutsOnly)
        XCTAssertTrue(EditTimeline().cutsOnly)
        var mute = EditTimeline()
        mute.volume = 0
        XCTAssertTrue(mute.cutsOnly)
        XCTAssertTrue(VideoComposer.isLossless(EditRecipe(source: EditSource(path: "/x.mov", kind: .video))))
        var looked = EditRecipe(source: EditSource(path: "/x.mov", kind: .video))
        looked.look = Look(name: .mono)
        XCTAssertFalse(VideoComposer.isLossless(looked))
    }

    /// A lossless turn and flip puts a corner where the canvas does (audit C1-m1).
    func testALosslessTurnAndFlipMatchTheCanvas() {
        let size = CGSize(width: 200, height: 100)
        for turns in 0 ..< 4 {
            for flipped in [false, true] {
                var geometry = EditGeometry()
                geometry.quarterTurns = turns
                geometry.flipped = flipped
                // The top-left corner (origin top left) of the source, through the video transform.
                let video = CGPoint(x: 1.5, y: 1.5).applying(VideoComposer.turn(geometry, size: size))
                // The same corner through the photo renderer: a 200 × 100 picture with one red pixel at the top left.
                let picture = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
                let dot = CIImage(color: .red).cropped(to: CGRect(x: 1, y: 98, width: 1, height: 1))
                let turned = PhotoRenderer.geometry(dot.composited(over: picture), geometry)
                let bitmap = PhotoRenderer.cgImage(turned, exact: true)!
                var found = CGPoint(x: -1, y: -1)
                for y in 0 ..< bitmap.height {
                    for x in 0 ..< bitmap.width where pixel(bitmap, x, y).r > 200 {
                        found = CGPoint(x: x, y: y)
                    }
                }
                XCTAssertEqual(Int(video.x.rounded(.down)), Int(found.x), "turns \(turns) flipped \(flipped)")
                XCTAssertEqual(Int(video.y.rounded(.down)), Int(found.y), "turns \(turns) flipped \(flipped)")
            }
        }
    }

    func testTurningAndCuttingAreNotReEncoded() async throws {
        let source = try await clip()
        var edit = recipe(source)
        edit.geometry.quarterTurns = 1
        let turned = folder.appendingPathComponent("turned.mov")
        let built = try await VideoComposer.export(source, recipe: edit, to: turned) { _ in }
        XCTAssertTrue(built.lossless)
        let sourceDigest = await VideoComposer.sampleDigest(source)
        let turnedDigest = await VideoComposer.sampleDigest(turned)
        XCTAssertEqual(sourceDigest, turnedDigest, "the same compressed frames")
        let turnedFacts = try await facts(turned)
        XCTAssertEqual(turnedFacts.size, CGSize(width: 360, height: 640))

        var cut = recipe(source)
        var time = EditTimeline()
        time.kept = [TimeRange(start: 1, end: 3)]
        time.volume = 0
        cut.timeline = time
        let cutURL = folder.appendingPathComponent("cut.mov")
        let cutBuilt = try await VideoComposer.export(source, recipe: cut, to: cutURL) { _ in }
        XCTAssertTrue(cutBuilt.lossless)
        let cutFacts = try await facts(cutURL)
        XCTAssertEqual(cutFacts.duration, 2, accuracy: 0.05)
        XCTAssertFalse(cutFacts.audio, "muted")
        XCTAssertEqual(cutFacts.codec, kCMVideoCodecType_H264)
    }

    func testALookAFrameAndSpeedAreRendered() async throws {
        let source = try await clip()
        var edit = recipe(source)
        edit.look = Look(name: .mono)
        edit.geometry.aspect = .portrait916
        edit.geometry.crop = UnitRect.centred(ratio: 9.0 / 16, in: CGSize(width: 640, height: 360))
        var frame = Frame()
        frame.bottom = 0.2
        edit.frame = frame
        var title = TextStyle(text: "Title")
        title.color = .black
        var layer = Layer(kind: .text(title))
        layer.y = 0.92
        edit.layers = [layer]
        var time = EditTimeline()
        time.speed = 2
        time.fadeIn = 0.5
        edit.timeline = time
        let output = folder.appendingPathComponent("framed.mp4")
        let built = try await VideoComposer.export(source, recipe: edit, to: output) { _ in }
        XCTAssertFalse(built.lossless)
        let result = try await facts(output)
        XCTAssertEqual(result.duration, 2, accuracy: 0.15, "twice as fast")
        XCTAssertEqual(result.size, built.renderSize)
        XCTAssertLessThan(result.size.width, result.size.height, "a tall frame")
        XCTAssertEqual(result.codec, kCMVideoCodecType_HEVC)
        // The white border at a corner, half way through; the first frame faded from black.
        let middleFrame = await VideoComposer.frame(output, at: 1)
        let middle = try XCTUnwrap(middleFrame)
        let corner = pixel(middle, 2, 2)
        XCTAssertGreaterThan(corner.r, 220)
        let firstFrame = await VideoComposer.frame(output, at: 0)
        let first = try XCTUnwrap(firstFrame)
        XCTAssertLessThan(pixel(first, 2, 2).r, 60, "faded in from black")
    }

    func testAPortraitClipStaysUpright() async throws {
        let source = try await clip(portrait: true)
        var edit = recipe(source)
        edit.adjust.exposure = 0.3
        let output = folder.appendingPathComponent("portrait.mp4")
        let built = try await VideoComposer.export(source, recipe: edit, to: output) { _ in }
        let result = try await facts(output)
        XCTAssertEqual(built.renderSize, CGSize(width: 360, height: 640))
        XCTAssertEqual(result.size, CGSize(width: 360, height: 640))
    }

    func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    // MARK: Audit round 3

    func testSoundPastThePictureNeverStopsAnExport() async throws {
        let source = try await clip(soundLonger: 0.6)
        // Exposure alone, then cuts with fades and speed: every frame without a picture is black (C3-1).
        var edit = recipe(source)
        edit.adjust.exposure = 0.3
        let output = folder.appendingPathComponent("longer.mp4")
        let built = try await VideoComposer.export(source, recipe: edit, to: output) { _ in }
        XCTAssertFalse(built.lossless)
        let result = try await facts(output)
        XCTAssertEqual(result.duration, 4.6, accuracy: 0.15)
        var time = EditTimeline()
        time.kept = [TimeRange(start: 0.5, end: 2), TimeRange(start: 3, end: 4.6)]
        time.fadeIn = 0.3
        time.fadeOut = 0.3
        time.speed = 2
        edit.timeline = time
        let cut = folder.appendingPathComponent("cut.mp4")
        _ = try await VideoComposer.export(source, recipe: edit, to: cut) { _ in }
        let cutFacts = try await facts(cut)
        XCTAssertEqual(cutFacts.duration, 1.55, accuracy: 0.15)
    }

    func testAnMP4KeepsItsCaptureDate() async throws {
        let engine = TestEngines.ffmpegFolder.appendingPathComponent("ffmpeg")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: engine.path), "ffmpeg is not built")
        // An MP4 as a phone writes it: the date only in the movie header.
        let clip = try await clip()
        let phone = folder.appendingPathComponent("phone.mp4")
        _ = try await FFmpeg.run(engine, ["-hide_banner", "-v", "error", "-y", "-i", clip.path, "-c", "copy", "-map", "0",
                                          "-metadata", "creation_time=2024-05-01T10:00:00Z", phone.path])
        let before = try await AVURLAsset(url: phone).load(.creationDate)?.load(.dateValue)
        XCTAssertNotNil(before, "the fixture has a date")
        for keep in [true, false] {
            var edit = recipe(phone)
            edit.adjust.exposure = 0.2
            edit.export.keepLocation = keep
            let output = folder.appendingPathComponent("phone-\(keep).mp4")
            _ = try await VideoComposer.export(phone, recipe: edit, to: output) { _ in }
            let asset = AVURLAsset(url: output)
            let date = try await asset.load(.creationDate)?.load(.dateValue)
            XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, before?.timeIntervalSince1970 ?? 1, accuracy: 1,
                           "the capture date is kept (C3-6)")
        }
    }

    func testRoundFourDecisions() {
        // A turned portrait clip with a size that fits only once turned is re-encoded (C4-1).
        var turned = recipe(URL(fileURLWithPath: "/x/a.mp4"))
        turned.geometry.quarterTurns = 1
        turned.export.size = .post45
        XCTAssertFalse(VideoComposer.isLossless(turned, size: CGSize(width: 1080, height: 1350)))
        XCTAssertTrue(VideoComposer.isLossless(turned, size: CGSize(width: 1350, height: 1080)))
        // A QuickTime .qt stays QuickTime (C4-8).
        XCTAssertEqual(VideoComposer.container(for: URL(fileURLWithPath: "/x/a.qt"), recipe: turned), .mov)
    }

    func testRoundFiveSoundFadeAndLastFrame() async throws {
        // The sound ends 1.5 s before the picture: its fade-out ends with the sound (C5-2).
        let short = try await clip(soundLonger: -1.5)
        var edit = recipe(short)
        edit.adjust.exposure = 0.2
        var time = EditTimeline()
        time.fadeOut = 1
        edit.timeline = time
        let output = folder.appendingPathComponent("faded.mov")
        _ = try await VideoComposer.export(short, recipe: edit, to: output) { _ in }
        let tail = try await loudestSample(output, from: 2.35)
        let source = try await loudestSample(short, from: 2.35)
        XCTAssertLessThan(tail, source * 0.5, "faded out at the sound's end (\(tail) of \(source))")
        // Save Frame past the picture's end gives the last picture (C5-3).
        let longer = try await clip(soundLonger: 0.6)
        let last = await VideoComposer.frame(longer, at: 4.5)
        XCTAssertNotNil(last)
    }
}

/// The loudest sample from `start` seconds to the end of the file's sound.
private func loudestSample(_ url: URL, from start: Double) async throws -> Float {
    let asset = AVURLAsset(url: url)
    let track = try await asset.loadTracks(withMediaType: .audio)[0]
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(output)
    reader.startReading()
    var loudest: Float = 0
    while let buffer = output.copyNextSampleBuffer() {
        guard buffer.presentationTimeStamp.seconds >= start, let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
        let length = CMBlockBufferGetDataLength(block)
        var samples = [Float](repeating: 0, count: length / 4)
        _ = samples.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length / 4 * 4, destination: bytes.baseAddress!)
        }
        loudest = max(loudest, samples.map(abs).max() ?? 0)
    }
    return loudest
}
