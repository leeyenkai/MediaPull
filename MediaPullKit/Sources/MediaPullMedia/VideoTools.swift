import AVFoundation
import CoreGraphics
import Foundation

public enum VideoToolsError: LocalizedError {
    case unreadable
    case cannotTrim(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable: "This video could not be opened."
        case let .cannotTrim(reason): "The video could not be trimmed: \(reason)"
        }
    }
}

/// Frame grabs and trimming for local video files (SPEC section 34). Trimming never re-encodes: the
/// samples are copied and the cut points are kept exact with an edit list.
public enum VideoTools {
    public static func duration(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.isNumeric else { return nil }
        return duration.seconds
    }

    /// The frame shown at `seconds`, at the video's full resolution with its rotation applied.
    public static func frame(of url: URL, at seconds: Double) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = .zero
        do {
            return try await generator.image(at: CMTime(seconds: max(0, seconds), preferredTimescale: 60000)).image
        } catch {
            throw VideoToolsError.unreadable
        }
    }

    /// Writes the part of `url` between `start` and `end` seconds to `output` (MP4 or MOV, matching the source).
    public static func trim(_ url: URL, from start: Double, to end: Double, output: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard end > start,
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough)
        else { throw VideoToolsError.cannotTrim("the selection is empty") }
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000),
                                        end: CMTime(seconds: end, preferredTimescale: 60000))
        session.shouldOptimizeForNetworkUse = true
        let type: AVFileType = output.pathExtension.lowercased() == "mov" ? .mov : .mp4
        try? FileManager.default.removeItem(at: output)
        do {
            try await session.export(to: output, as: type)
        } catch {
            throw VideoToolsError.cannotTrim(error.localizedDescription)
        }
    }
}
