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
        // Read by labels into the encoder's order only when every channel is a speaker of its own (D-130, rounds 13 and
        // 14, C13-1, C14-1): a sound with an LFE the encoder's layout of that count has no place for goes into the
        // smallest AAC layout that has one. Anything else (discrete, unknown, ambisonic, a narration or a mix channel,
        // a label twice) keeps every channel by its number, as the system's own exporter does.
        let own = input.channelLayout.flatMap { $0.channelCount == channels ? $0 : nil }
        let layout: AVAudioChannelLayout?
        if let own, let labels = speakers(of: own) {
            let lfe = labels.contains(kAudioChannelLabel_LFEScreen) || labels.contains(kAudioChannelLabel_LFE2)
            let tag: AudioChannelLayoutTag? = if lfe, channels == 3 || channels == 5 {
                labels.contains(kAudioChannelLabel_CenterSurround) ? kAudioChannelLayoutTag_AAC_6_1 : kAudioChannelLayoutTag_AAC_5_1
            } else {
                encoderLayouts[channels]
            }
            layout = tag.flatMap { AVAudioChannelLayout(layoutTag: $0) } ?? own
        } else if let own, let labels = labels(of: own), Set(labels).count == labels.count {
            layout = own
        } else {
            // A label twice (four Mono channels): read by number, never summed.
            layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)
        }
        return layout.map { AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: true, channelLayout: $0) }
    }

    /// Temporary files an export, a waveform or a cut left when MediaPull quit part way (round 12, C12-4).
    public static func removeLeftovers() {
        let folder = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        // Only files a day old: a second MediaPull running (a self-test) never takes a running export's files.
        let dayAgo = Date(timeIntervalSinceNow: -86400)
        for name in names where ["MediaPull-sound-", "MediaPull-wave-", "MediaPull-cut-"].contains(where: name.hasPrefix) {
            let url = folder.appendingPathComponent(name)
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            guard (modified ?? .distantPast) < dayAgo else { continue }
            try? FileManager.default.removeItem(at: url) // lint:allow app-data own temporary files
        }
    }

    /// The speaker of each channel of `layout`, or nil when any channel is not a speaker of its own: discrete, unknown,
    /// ambisonic, a mix or narration channel (Lt, Rt, mono, hearing impaired), or a speaker named twice.
    static func speakers(of layout: AVAudioChannelLayout) -> [AudioChannelLabel]? {
        guard let labels = labels(of: layout) else { return nil }
        // A named layout the system cannot describe is a layout of speakers: its channels are placed by the mix.
        if labels.isEmpty { return unplaced(layout.layout.pointee.mChannelLayoutTag) ? nil : [] }
        // Speakers are labels 1 to 18 (fronts, centre, LFE, surrounds, centres, heights), 33 to 37 (rear surrounds, wides,
        // a second LFE), 44 (centre surround direct) and 49 to 66 (the tops, sides and bottoms of immersive layouts); the
        // rest are mixes, narration, haptics, coordinates, ambisonics, discrete and unknown channels.
        let speaker = { (label: AudioChannelLabel) in
            (1 ... 18).contains(label) || (33 ... 37).contains(label) || label == 44 || (49 ... 66).contains(label)
        }
        guard labels.count == Int(layout.channelCount), labels.allSatisfy(speaker), Set(labels).count == labels.count else {
            return nil
        }
        return labels
    }

    /// The label of each channel of `layout` as the system describes it; empty when it cannot, nil when it is not read.
    static func labels(of layout: AVAudioChannelLayout) -> [AudioChannelLabel]? {
        var tag = layout.layout.pointee.mChannelLayoutTag
        var labels: [AudioChannelLabel] = []
        func read(_ described: UnsafePointer<AudioChannelLayout>) {
            let count = Int(described.pointee.mNumberChannelDescriptions)
            guard count > 0, let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions) else { return }
            let descriptions = (UnsafeRawPointer(described) + offset).assumingMemoryBound(to: AudioChannelDescription.self)
            labels = (0 ..< count).map { descriptions[$0].mChannelLabel }
        }
        if tag == kAudioChannelLayoutTag_UseChannelDescriptions {
            read(layout.layout)
        } else {
            // A named layout or a bitmap is turned into its channel descriptions by the system.
            var bitmap = layout.layout.pointee.mChannelBitmap.rawValue
            let byBitmap = tag == kAudioChannelLayoutTag_UseChannelBitmap
            let property = byBitmap ? kAudioFormatProperty_ChannelLayoutForBitmap : kAudioFormatProperty_ChannelLayoutForTag
            var size: UInt32 = 0
            let specifierSize = UInt32(MemoryLayout<UInt32>.size)
            let info = byBitmap ? AudioFormatGetPropertyInfo(property, specifierSize, &bitmap, &size)
                : AudioFormatGetPropertyInfo(property, specifierSize, &tag, &size)
            guard info == noErr, size > 0 else { return [] }
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
            defer { raw.deallocate() }
            let got = byBitmap ? AudioFormatGetProperty(property, specifierSize, &bitmap, &size, raw)
                : AudioFormatGetProperty(property, specifierSize, &tag, &size, raw)
            guard got == noErr else { return [] }
            read(raw.assumingMemoryBound(to: AudioChannelLayout.self))
        }
        return labels
    }

    /// Layout families whose channels are numbers or components, never speakers.
    static func unplaced(_ tag: AudioChannelLayoutTag) -> Bool {
        let family = tag & 0xFFFF_0000
        return [kAudioChannelLayoutTag_DiscreteInOrder, kAudioChannelLayoutTag_Unknown, kAudioChannelLayoutTag_HOA_ACN_SN3D,
                kAudioChannelLayoutTag_HOA_ACN_N3D, kAudioChannelLayoutTag_Ambisonic_B_Format].contains { $0 & 0xFFFF_0000 == family }
    }

    /// A channel layout as the reader's settings take it, with all its channel descriptions.
    static func data(of layout: AVAudioChannelLayout) -> Data {
        let count = Int(layout.layout.pointee.mNumberChannelDescriptions)
        let size = MemoryLayout<AudioChannelLayout>.size + max(0, count - 1) * MemoryLayout<AudioChannelDescription>.size
        return Data(bytes: layout.layout, count: size)
    }
}
