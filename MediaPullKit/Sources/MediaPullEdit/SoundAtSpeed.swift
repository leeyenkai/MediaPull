@preconcurrency import AVFoundation
import Foundation
import MediaPullCore

/// The sound of a video export at another speed, rendered offline before the export (D-130, audit 2026-11-21-10, C10-1).
/// The export session's own time-stretch runs late by an amount that varies and drops the end of the sound; here the
/// stretch runs at its own pace, its known delay is trimmed, and the result is exactly the length the picture is.
enum SoundAtSpeed {
    /// The parts kept of `asset`'s sound, as at normal speed (silence where the sound has none), stretched to `speed` with
    /// its pitch kept, in a temporary file; nil when the parts kept have no sound.
    static func render(_ asset: AVURLAsset, recipe: EditRecipe, speed: Double) async throws -> URL? {
        var plain = recipe
        var time = plain.timeline ?? EditTimeline()
        time.speed = 1
        time.fadeIn = 0
        time.fadeOut = 0
        time.volume = 1
        plain.timeline = time
        let unscaled = try await VideoComposer.build(asset, recipe: plain)
        let tracks = try await unscaled.composition.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return nil }
        guard let source = try await read(unscaled.composition, tracks: tracks) else { return nil }
        let stretched = try stretch(source, speed: speed)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MediaPull-sound-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: stretched.format.settings)
        try file.write(from: stretched)
        return url
    }

    /// The composition's sound from its start to its end, every sample at its time (silence between parts).
    static func read(_ composition: AVComposition, tracks: [AVAssetTrack]) async throws -> AVAudioPCMBuffer? {
        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? VideoComposer.Failure.notWritten("the sound could not be read") }
        let duration = try await composition.load(.duration).seconds
        var buffer: AVAudioPCMBuffer?
        while let sample = output.copyNextSampleBuffer() {
            guard let description = sample.formatDescription, let block = sample.dataBuffer else { continue }
            let input = AVAudioFormat(cmAudioFormatDescription: description)
            let channels = Int(input.channelCount), rate = input.sampleRate
            if buffer == nil {
                guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels)),
                      let made = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, duration * rate + rate)))
                else { return nil }
                made.frameLength = made.frameCapacity
                buffer = made
            }
            guard let buffer, let planes = buffer.floatChannelData else { continue }
            let frames = CMSampleBufferGetNumSamples(sample)
            var interleaved = [Float](repeating: 0, count: frames * channels)
            _ = interleaved.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: min(bytes.count, CMBlockBufferGetDataLength(block)),
                                           destination: bytes.baseAddress!)
            }
            let start = Int((sample.presentationTimeStamp.seconds * rate).rounded())
            for frame in 0 ..< frames where start + frame >= 0 && start + frame < Int(buffer.frameCapacity) {
                for channel in 0 ..< channels {
                    planes[channel][start + frame] = interleaved[frame * channels + channel]
                }
            }
        }
        if let buffer { buffer.frameLength = AVAudioFrameCount(min(Double(buffer.frameCapacity), duration * buffer.format.sampleRate)) }
        return buffer
    }

    /// `source` at `speed`, its pitch kept, rendered offline; exactly `source`'s length divided by the speed.
    static func stretch(_ source: AVAudioPCMBuffer, speed: Double) throws -> AVAudioPCMBuffer {
        let format = source.format
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        pitch.rate = Float(speed)
        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        defer { engine.stop() }
        player.scheduleBuffer(source, completionHandler: nil)
        player.play()
        let wanted = Int((Double(source.frameLength) / speed).rounded())
        // The time-pitch unit's own delay, at the output: rendered and dropped from the start.
        let delay = Int((pitch.auAudioUnit.latency * format.sampleRate).rounded())
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, wanted))),
              let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
              let into = output.floatChannelData else { throw VideoComposer.Failure.notWritten("the sound could not be sped up") }
        var rendered = 0, kept = 0
        while kept < wanted {
            let ask = AVAudioFrameCount(min(4096, wanted + delay - rendered))
            guard ask > 0 else { break }
            let status = try engine.renderOffline(ask, to: chunk)
            guard status == .success, let from = chunk.floatChannelData else { break }
            for frame in 0 ..< Int(chunk.frameLength) where rendered + frame >= delay && kept < wanted {
                for channel in 0 ..< Int(format.channelCount) {
                    into[channel][kept] = from[channel][frame]
                }
                kept += 1
            }
            rendered += Int(chunk.frameLength)
        }
        output.frameLength = AVAudioFrameCount(kept)
        return output
    }
}
