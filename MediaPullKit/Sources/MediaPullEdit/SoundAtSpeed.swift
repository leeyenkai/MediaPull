@preconcurrency import AVFoundation
import Foundation
import MediaPullCore

/// The sound of a video export at another speed, rendered before the export (D-130, audit 2026-11-21-10, C10-1; round 11,
/// C11-1 to C11-5). The export session's own time-stretch runs late by an amount that varies and drops the end of the
/// sound; read through a mix output over the same scaled composition, the stretch is on time, keeps every channel and
/// its pitch, and sounds as Play Result does. It is written buffer by buffer, so memory stays small whatever the length.
public enum SoundAtSpeed {
    /// The parts kept of `asset`'s sound at the recipe's speed, pitch kept, in a temporary file as long as the picture at
    /// most; nil when the parts kept have no sound. Cancelling stops it, and nothing is left behind when it throws; a file
    /// left by a quit part way is removed at the next launch (`removeLeftovers`).
    static func render(_ asset: AVURLAsset, recipe: EditRecipe,
                       progress: @Sendable (Double) -> Void = { _ in }) async throws -> URL?
    {
        var plain = recipe
        var time = plain.timeline ?? EditTimeline()
        time.fadeIn = 0
        time.fadeOut = 0
        time.volume = 1
        plain.timeline = time
        let composition = try await VideoComposer.build(asset, recipe: plain).composition
        let tracks = try await composition.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty, let source = try await asset.loadTracks(withMediaType: .audio).first,
              let description = try await source.load(.formatDescriptions).first,
              let format = format(of: AVAudioFormat(cmAudioFormatDescription: description))
        else { return nil }
        let rate = format.sampleRate
        let channels = Int(format.channelCount)
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: channels, AVSampleRateKey: rate,
        ]
        if channels > 2, let layout = format.channelLayout { settings[AVChannelLayoutKey] = data(of: layout) }
        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.audioTimePitchAlgorithm = .spectral
        reader.add(output)
        let wanted = Int64((try await composition.load(.duration).seconds * rate).rounded())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MediaPull-sound-\(UUID().uuidString).caf")
        var kept = false
        defer { if !kept { try? FileManager.default.removeItem(at: url) } }
        // Closed before the file is handed on or removed.
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32,
                                                 interleaved: true)
        guard reader.startReading() else { throw reader.error ?? VideoComposer.Failure.notWritten("the sound could not be read") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        let frameBytes = channels * MemoryLayout<Float>.size
        var written: Int64 = 0
        func write(_ frames: Int64, from block: CMBlockBuffer?, at offset: Int) throws {
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData
            else { throw VideoComposer.Failure.notWritten("the sound could not be sped up") }
            buffer.frameLength = AVAudioFrameCount(frames)
            if let block {
                guard CMBlockBufferCopyDataBytes(block, atOffset: offset, dataLength: Int(frames) * frameBytes,
                                                 destination: destination) == kCMBlockBufferNoErr
                else { throw VideoComposer.Failure.notWritten("the sound could not be read") }
            } else {
                memset(destination, 0, Int(frames) * frameBytes)
            }
            try file?.write(from: buffer)
            written += frames
        }
        while written < wanted, let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = sample.dataBuffer else { continue }
            let frames = Int64(min(CMSampleBufferGetNumSamples(sample), CMBlockBufferGetDataLength(block) / frameBytes))
            // Every sample at its time: silence up to where a buffer starts, never a sample twice.
            let start = Int64((sample.presentationTimeStamp.seconds * rate).rounded())
            while written < min(start, wanted) { try write(min(65536, min(start, wanted) - written), from: nil, at: 0) }
            let skip = max(0, written - start)
            let count = min(frames - skip, wanted - written)
            if count > 0 { try write(count, from: block, at: Int(skip) * frameBytes) }
            progress(Double(written) / Double(max(1, wanted)))
        }
        try Task.checkCancellation()
        if reader.status == .failed { throw reader.error ?? VideoComposer.Failure.notWritten("the sound could not be read") }
        file = nil
        guard written > 0 else { return nil }
        kept = true
        return url
    }

    /// How many channels the sound of `asset` has (its first sound track, the one an export keeps).
    static func channels(of asset: AVURLAsset) async throws -> Int {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first,
              let description = try await track.load(.formatDescriptions).first else { return 0 }
        return Int(AVAudioFormat(cmAudioFormatDescription: description).channelCount)
    }

    /// The order an AAC encoder takes surround channels in, by count; read in it by their labels, every channel lands
    /// where it was (audit 2026-11-21-12, C12-1). Four channels (quad, ambisonics) keep their own layout.
    static let encoderLayouts: [AVAudioChannelCount: AudioChannelLayoutTag] = [
        3: kAudioChannelLayoutTag_AAC_3_0, 5: kAudioChannelLayoutTag_AAC_5_0, 6: kAudioChannelLayoutTag_AAC_5_1,
        7: kAudioChannelLayoutTag_AAC_6_1, 8: kAudioChannelLayoutTag_AAC_7_1,
    ]

    /// Float samples at the sound's own rate and channels; more than two in the encoder's order (5.1) or their own
    /// layout (quad, ambisonics). A low rate is read at 48 kHz: the stretch at 8 kHz loses the last tenth of a second at 4x.
    static func format(of input: AVAudioFormat) -> AVAudioFormat? {
        let rate = input.sampleRate >= 32000 ? input.sampleRate : 48000
        let channels = max(1, input.channelCount)
        if channels <= 2 {
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: true)
        }
        let layout = encoderLayouts[channels].flatMap { AVAudioChannelLayout(layoutTag: $0) }
            ?? input.channelLayout.flatMap { $0.channelCount == channels ? $0 : nil }
            ?? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)
        return layout.map { AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: true, channelLayout: $0) }
    }

    /// Temporary files an export, a waveform or a cut left when MediaPull quit part way (round 12, C12-4).
    public static func removeLeftovers() {
        let folder = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where ["MediaPull-sound-", "MediaPull-wave-", "MediaPull-cut-"].contains(where: name.hasPrefix) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) // lint:allow app-data own temporary files
        }
    }

    /// A channel layout as the reader's settings take it, with all its channel descriptions.
    static func data(of layout: AVAudioChannelLayout) -> Data {
        let count = Int(layout.layout.pointee.mNumberChannelDescriptions)
        let size = MemoryLayout<AudioChannelLayout>.size + max(0, count - 1) * MemoryLayout<AudioChannelDescription>.size
        return Data(bytes: layout.layout, count: size)
    }
}
