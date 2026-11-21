@preconcurrency import AVFoundation
import CoreImage
import CryptoKit
import Foundation
import MediaPullCore

/// Video edits (R-4609, D-130): the recipe's cuts and speed as a composition, and its picture (geometry, adjustments,
/// look, frame, layers, fades) as a Core Image handler on every frame. The same build plays on the canvas and is exported.
/// Cuts, turns, flips and muting alone are written without re-encoding.
public enum VideoComposer {
    public enum Failure: Error, LocalizedError {
        case noVideo, notWritten(String)

        public var errorDescription: String? {
            switch self {
            case .noVideo: "This file has no video to edit."
            case let .notWritten(reason): "The edited video could not be written: \(reason)"
            }
        }
    }

    public struct Built: @unchecked Sendable {
        public let composition: AVMutableComposition
        public let videoComposition: AVVideoComposition?
        public let audioMix: AVAudioMix?
        public let renderSize: CGSize
        public let lossless: Bool
        public let speed: Double
    }

    /// Whether the recipe only cuts, turns, flips or mutes: then nothing is re-encoded (D-130). `size`: the picture as
    /// shown; a size setting that would not make it smaller changes nothing either (audit 2026-11-21-3, C3-8).
    public static func isLossless(_ recipe: EditRecipe, size: CGSize? = nil) -> Bool {
        let time = recipe.timeline ?? EditTimeline()
        // The picture as turned, which is what the size must fit (audit 2026-11-21-4, C4-1).
        let turned = size.map { CGRect(origin: .zero, size: $0).applying(turn(recipe.geometry, size: $0)).standardized.size }
        let sized = recipe.export.size == .original || turned.map { recipe.export.size.pixels(for: $0) == $0 } == true
        return time.cutsOnly && recipe.adjust == Adjustments() && recipe.look == nil && recipe.frame == nil
            && recipe.layers.allSatisfy(\.hidden) && recipe.geometry.crop == nil && recipe.geometry.straighten == 0 && sized
    }

    /// The container an export is written in: the one chosen, else like the original (a MOV stays MOV).
    public static func container(for source: URL, recipe: EditRecipe) -> ExportSettings.VideoContainer {
        recipe.export.videoContainer ?? (["mov", "qt"].contains(source.pathExtension.lowercased()) ? .mov : .mp4)
    }

    static func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

    /// A turn and flip of a picture shown at `size`, in AVFoundation's coordinates (origin top left).
    /// Turned first, then flipped in the turned size, as the photo renderer does, so a lossless export matches the canvas.
    public static func turn(_ geometry: EditGeometry, size: CGSize) -> CGAffineTransform {
        let (w, h) = (size.width, size.height)
        let quarters = ((geometry.quarterTurns % 4) + 4) % 4
        let rotation: CGAffineTransform = switch quarters {
        case 1: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case 2: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 3: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        default: .identity
        }
        guard geometry.flipped else { return rotation }
        let turnedWidth = quarters % 2 == 0 ? w : h
        return rotation.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: turnedWidth, ty: 0))
    }

    /// The composition, picture handler and sound for `recipe`. Off the main actor: it loads tracks and draws the layers.
    @concurrent
    public static func build(_ asset: AVURLAsset, recipe: EditRecipe) async throws -> Built {
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let duration = try await asset.load(.duration).seconds
        let natural = try await video.load(.naturalSize)
        let preferred = try await video.load(.preferredTransform)
        let fps = try await video.load(.nominalFrameRate)
        let timeline = recipe.timeline ?? EditTimeline()
        let display = CGRect(origin: .zero, size: natural).applying(preferred).standardized.size
        let lossless = isLossless(recipe, size: display)

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.noVideo
        }
        var audioTrack = audio != nil && timeline.volume > 0
            ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        // Each track only where it has media: the file's length is its longest track, and a picture that ends before the
        // sound (or starts after it) has no frames there (audit 2026-11-21-3, C3-1).
        let videoRange = await mediaRange(of: video)
        let audioRange: CMTimeRange? = if let audio { await mediaRange(of: audio) } else { nil }
        /// Where the inserted part lies on the composition's timeline, or nil when the track has nothing there.
        func insert(_ part: CMTimeRange, of source: AVAssetTrack, within range: CMTimeRange, into track: AVMutableCompositionTrack,
                    at cursor: CMTime) throws -> CMTimeRange?
        {
            let clamped = part.intersection(range)
            guard clamped.duration > .zero else { return nil }
            let at = cursor + (clamped.start - part.start)
            try track.insertTimeRange(clamped, of: source, at: at)
            return CMTimeRange(start: at, duration: clamped.duration)
        }
        var cursor = CMTime.zero
        // Where the picture and the sound each start and end: where the sound outlasts the picture the last picture stays
        // (R-4609), and each fade runs over its own media, never over silence or black (C5-2, audit 2026-11-21-6, C6-4).
        var picture: CMTimeRange?
        var sound: CMTimeRange?
        for range in timeline.keptRanges(duration: duration) {
            let part = CMTimeRange(start: seconds(range.start), end: seconds(range.end))
            if let placed = try insert(part, of: video, within: videoRange, into: videoTrack, at: cursor) {
                picture = picture.map { $0.union(placed) } ?? placed
            }
            if let audio, let audioTrack, let audioRange,
               let placed = try insert(part, of: audio, within: audioRange, into: audioTrack, at: cursor)
            {
                sound = sound.map { $0.union(placed) } ?? placed
            }
            // CMTime has no +=.
            cursor = cursor + part.duration // swiftlint:disable:this shorthand_operator
        }
        let speed = min(max(timeline.speed, 0.25), 4)
        if speed != 1 {
            composition.scaleTimeRange(CMTimeRange(start: .zero, duration: cursor),
                                       toDuration: CMTime(seconds: cursor.seconds / speed, preferredTimescale: 600))
        }
        guard let picture else { throw Failure.notWritten("the parts kept have no picture") }
        // No part kept has sound: no sound track, which an exporter cannot write empty (C6-2).
        if sound == nil, let empty = audioTrack {
            composition.removeTrack(empty)
            audioTrack = nil
        }
        let (pictureStart, pictureEnd) = (picture.start.seconds / speed, picture.end.seconds / speed)
        // Fades longer together than their media are shortened alike, so they meet and never overlap (C6-1).
        func fades(over length: Double) -> (in: Double, out: Double) {
            let total = timeline.fadeIn + timeline.fadeOut
            let scale = total > length && total > 0 ? max(0, length) / total : 1
            return (timeline.fadeIn * scale, timeline.fadeOut * scale)
        }

        let audioMix: AVAudioMix? = {
            guard let audioTrack, let sound, timeline.volume != 1 || timeline.fadeIn > 0 || timeline.fadeOut > 0 else { return nil }
            let (start, end) = (sound.start.seconds / speed, sound.end.seconds / speed)
            let (fadeIn, fadeOut) = fades(over: end - start)
            let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
            let level = Float(min(max(timeline.volume, 0), 1))
            parameters.setVolume(fadeIn > 0 ? 0 : level, at: .zero)
            // In whole ticks, the fade-out starting no earlier than the fade-in ends: two ramps that meet must never
            // overlap by a rounding (audit 2026-11-21-7, C7-1).
            let fadeInRange = CMTimeRange(start: seconds(start), duration: seconds(fadeIn))
            if fadeIn > 0 {
                parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: level, timeRange: fadeInRange)
            }
            if fadeOut > 0 {
                let outStart = max(seconds(end - fadeOut), fadeIn > 0 ? fadeInRange.end : .zero)
                parameters.setVolumeRamp(fromStartVolume: level, toEndVolume: 0,
                                         timeRange: CMTimeRange(start: outStart, end: max(outStart, seconds(end))))
            }
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            return mix
        }()

        if lossless {
            videoTrack.preferredTransform = preferred.concatenating(turn(recipe.geometry, size: display))
            let size = CGRect(origin: .zero, size: display).applying(turn(recipe.geometry, size: display)).standardized.size
            return Built(composition: composition, videoComposition: nil, audioMix: audioMix, renderSize: size, lossless: true,
                         speed: speed)
        }

        // The picture's size after the recipe, fitted to the export size, in even pixels as encoders want.
        let probe = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: display))
        let edited = PhotoRenderer.render(probe, recipe: recipe).extent.size
        let fitted = recipe.export.size.pixels(for: edited)
        let renderSize = CGSize(width: max(2, (fitted.width / 2).rounded() * 2), height: max(2, (fitted.height / 2).rounded() * 2))
        let overlay = recipe.layers.isEmpty ? nil : LayerRenderer.image(recipe.layers, canvas: renderSize).map { CIImage(cgImage: $0) }
        let (fadeIn, fadeOut) = fades(over: pictureEnd - pictureStart)
        let plain = { var copy = recipe; copy.layers = []; return copy }()
        videoTrack.preferredTransform = preferred
        let frame = CGRect(origin: .zero, size: renderSize)
        let black = CIImage(color: .black).cropped(to: frame)
        let videoComposition = try await AVMutableVideoComposition.videoComposition(with: composition) { request in
            let source = request.sourceImage
            // No picture at this time (sound past the picture's end): a black frame, never nothing.
            guard !source.extent.isEmpty, !source.extent.isInfinite else {
                request.finish(with: black, context: nil)
                return
            }
            let upright = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
            var image = PhotoRenderer.render(upright, recipe: plain)
            let extent = image.extent
            if extent.width > 0, extent.height > 0 {
                image = image.transformed(by: CGAffineTransform(scaleX: renderSize.width / extent.width,
                                                                y: renderSize.height / extent.height))
            }
            if let overlay { image = overlay.composited(over: image) }
            let time = request.compositionTime.seconds
            let level = min(1, fadeIn > 0 ? max(0, time - pictureStart) / fadeIn : 1,
                            fadeOut > 0 ? max(0, pictureEnd - time) / fadeOut : 1)
            if level < 1 {
                let dim = CIFilter(name: "CIColorMatrix")
                dim?.setValue(image, forKey: kCIInputImageKey)
                for (key, vector) in [("inputRVector", CIVector(x: level, y: 0, z: 0, w: 0)),
                                      ("inputGVector", CIVector(x: 0, y: level, z: 0, w: 0)),
                                      ("inputBVector", CIVector(x: 0, y: 0, z: level, w: 0))]
                {
                    dim?.setValue(vector, forKey: key)
                }
                image = dim?.outputImage ?? image
            }
            let result = image.cropped(to: frame)
            request.finish(with: result.extent.isEmpty ? black : result.composited(over: black), context: nil)
        }
        videoComposition.renderSize = renderSize
        let rate = fps > 0 ? Double(fps) : 30
        // Up to 240 fps, so slow-motion clips keep every frame.
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, min(240, rate.rounded()))))
        return Built(composition: composition, videoComposition: videoComposition, audioMix: audioMix, renderSize: renderSize,
                     lossless: false, speed: speed)
    }

    /// The original's metadata to keep, with what `metadata` leaves out of an MP4: the capture date of the movie header and
    /// a location in user data (as Android phones write it), so an edited copy keeps its date (audit 2026-11-21-3, C3-6).
    static func keptMetadata(_ asset: AVURLAsset) async -> [AVMetadataItem] {
        var kept = (try? await asset.load(.metadata)) ?? []
        let identifiers = Set(kept.compactMap(\.identifier))
        if let formats = try? await asset.load(.availableMetadataFormats), formats.contains(.quickTimeUserData) {
            let userData = (try? await asset.loadMetadata(for: .quickTimeUserData)) ?? []
            kept += userData.filter { item in
                guard let identifier = item.identifier, !identifiers.contains(identifier) else { return false }
                return identifier == .quickTimeUserDataLocationISO6709
            }
        }
        if !kept.contains(where: { $0.commonKey == .commonKeyCreationDate }), let date = try? await asset.load(.creationDate),
           let value = try? await date.load(.value)
        {
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierCreationDate
            item.value = value
            kept.append(item)
        }
        return kept
    }

    /// Where a track has media: its time range without the empty edits a file stores a late start as (a track's own
    /// `timeRange` counts them; audit 2026-11-21-8, C8-1, C8-2).
    static func mediaRange(of track: AVAssetTrack) async -> CMTimeRange {
        let whole = (try? await track.load(.timeRange)) ?? .zero
        let filled = ((try? await track.load(.segments)) ?? []).filter { !$0.isEmpty }.map(\.timeMapping.target)
        guard let first = filled.first else { return whole }
        return filled.dropFirst().reduce(first) { $0.union($1) }
    }

    /// A player item for the canvas: the result as it will be exported.
    @MainActor
    public static func playerItem(_ asset: AVURLAsset, recipe: EditRecipe) async throws -> AVPlayerItem {
        let built = try await build(asset, recipe: recipe)
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        if built.speed != 1 { item.audioTimePitchAlgorithm = .spectral }
        return item
    }

    /// Writes the edited video to `output` (`.mp4` or `.mov`), reporting progress; cancelling the task stops it.
    @concurrent
    public static func export(_ source: URL, recipe: EditRecipe, to output: URL,
                              progress: @escaping @Sendable (Double) -> Void) async throws -> Built
    {
        let built = try await build(AVURLAsset(url: source), recipe: recipe)
        let preset = built.lossless ? AVAssetExportPresetPassthrough
            : recipe.export.videoCodec == .h264 ? AVAssetExportPresetHighestQuality : AVAssetExportPresetHEVCHighestQuality
        guard let session = AVAssetExportSession(asset: built.composition, presetName: preset) else {
            throw Failure.notWritten("no exporter for this video")
        }
        // The original's metadata (date, location, camera) is kept, as for photos; the location only when asked.
        let kept = await keptMetadata(AVURLAsset(url: source))
        session.metadata = recipe.export.keepLocation ? kept : kept.filter { item in
            let identifier = item.identifier?.rawValue.lowercased() ?? ""
            return !identifier.contains("location") && !identifier.contains("iso6709") && !identifier.contains("%a9xyz")
                && !identifier.contains("©xyz") && !identifier.contains("loci")
        }
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        if built.speed != 1 { session.audioTimePitchAlgorithm = .spectral }
        let type: AVFileType = output.pathExtension.lowercased() == "mov" ? .mov : .mp4
        // A video MP4 cannot hold (ProRes, say) is refused with the reason rather than failing part way.
        if await !session.compatibleFileTypes.contains(type) {
            throw Failure.notWritten("this video cannot be kept as \(type == .mp4 ? "MP4" : "MOV"); choose the other file type")
        }
        // The session only reports its state here; it is not otherwise touched from this task.
        nonisolated(unsafe) let watched = session
        let watcher = Task {
            for await state in watched.states(updateInterval: 0.25) {
                if case let .exporting(progress: current) = state { progress(current.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        do {
            try await session.export(to: output, as: type)
        } catch {
            try? FileManager.default.removeItem(at: output)
            if error is CancellationError { throw error }
            throw Failure.notWritten(error.localizedDescription)
        }
        progress(1)
        return built
    }

    /// A digest of the compressed video samples as stored, to prove a file was not re-encoded.
    public static func sampleDigest(_ url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first, let reader = try? AVAssetReader(asset: asset) else {
            return nil
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { return nil }
        var hasher = SHA256()
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            data.withUnsafeMutableBytes { bytes in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
            }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A frame of the original at `seconds`, upright, for the canvas.
    public static func frame(_ url: URL, at seconds: Double) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // Past the picture's end (the sound goes on), the last picture is the one shown, so it is the one saved (C5-3).
        // Before a picture that starts late, its first picture (C8-3).
        var time = seconds
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            let range = await mediaRange(of: track)
            let rate = Double((try? await track.load(.nominalFrameRate)) ?? 30)
            time = max(range.start.seconds, min(time, range.end.seconds - 1 / max(rate, 1)))
        }
        return try? await generator.image(at: CMTime(seconds: max(0, time), preferredTimescale: 600)).image
    }
}
