import Foundation
import MediaPullCore
import MediaPullEngines
import MediaPullLibrary
import MediaPullNet
import SwiftUI

/// Audio in Edit/Frame (R-4610, D-131): the waveform, cuts, fades, volume and loudness, the format, tags and artwork.
extension EditModel {
    /// The waveform's peaks and the file's own tags, read with the bundled ffmpeg off the main actor.
    func loadWaveform() {
        waveformTask?.cancel()
        waveform = []
        waveformFailed = false
        currentTags = nil
        audioSource = nil
        audioLengthKnown = false
        guard let current, kind == .audio else { return }
        guard let ffmpeg = AppModel.shared.ffmpeg else {
            waveformFailed = true
            audioLengthKnown = true
            loadPlayer()
            return
        }
        // One at a time: moving through files stops the decode of the one left (cancelling ends its ffmpeg).
        waveformTask = Task { [weak self] in
            // The true length first, not the system's guess, which can be short or long (VBR MP3, ADTS AAC, Opus): cuts
            // and the player wait for it (audit 2026-11-21-3, C3-2).
            let source = await ffmpeg.audioFormat(current)
            guard let self, !Task.isCancelled, self.current == current else { return }
            audioSource = source
            if let length = source?.duration, length > 0 { mediaDuration = length }
            audioLengthKnown = true
            loadPlayer()
            let read = await ffmpeg.audioTags(current)
            let peaks = try? await ffmpeg.waveform(current, buckets: 1200)
            guard !Task.isCancelled, self.current == current else { return }
            waveform = peaks ?? []
            waveformFailed = peaks?.isEmpty ?? true
            currentTags = read?.tags
        }
    }

    /// Plays only the selected part (R-4610).
    func playSelection() {
        guard let selection = audioSelection else { return }
        player.play(from: selection.start, to: selection.end)
    }

    /// Keeps only the selected part.
    func keepSelection() {
        guard let selection = audioSelection else { return }
        let kept = keptRanges.compactMap { part -> TimeRange? in
            let start = max(part.start, selection.start), end = min(part.end, selection.end)
            return end - start > 0.01 ? TimeRange(start: start, end: end) : nil
        }
        guard !kept.isEmpty else { return }
        applyKept(kept)
        audioSelection = nil
    }

    /// Cuts the selected part out.
    func removeSelection() {
        guard let selection = audioSelection else { return }
        var kept: [TimeRange] = []
        for part in keptRanges {
            if part.end <= selection.start || part.start >= selection.end {
                kept.append(part)
                continue
            }
            if part.start < selection.start { kept.append(TimeRange(start: part.start, end: selection.start)) }
            if part.end > selection.end { kept.append(TimeRange(start: selection.end, end: part.end)) }
        }
        guard !kept.isEmpty else {
            message = "At least one part has to stay."
            return
        }
        applyKept(kept)
        audioSelection = nil
    }

    private func applyKept(_ kept: [TimeRange]) {
        setTimeline { time in
            let whole = kept.count == 1 && kept[0].start <= 0.001 && abs(kept[0].end - mediaDuration) <= 0.001
            time.kept = whole ? [] : kept
        }
    }

    func setTags(_ body: (inout AudioTagEdit) -> Void) {
        change { recipe in
            var tags = recipe.tags ?? AudioTagEdit()
            body(&tags)
            recipe.tags = tags == AudioTagEdit() ? nil : tags
        }
    }

    /// Writes the edited audio with the bundled ffmpeg (stream copy where only cuts are asked for), then places it.
    @concurrent
    nonisolated static func exportAudio(_ url: URL, recipe: EditRecipe, into folder: URL,
                                        progress: @escaping @Sendable (Double) -> Void) async -> Result<URL, Error>
    {
        guard let ffmpeg = await MainActor.run(body: { AppModel.shared.ffmpeg }) else {
            return .failure(FFmpegError.missing)
        }
        do {
            let fm = FileManager.default
            let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
            defer { try? fm.removeItem(at: staging) }
            // The true length and the codec and depth, read by ffprobe.
            var source = await ffmpeg.audioFormat(url) ?? AudioSourceFormat(duration: 0)
            if source.duration == 0 { source.duration = await duration(of: url) }
            let format = recipe.export.audioFormat ?? .like(url.pathExtension, codec: source.codec)
            let stem = url.deletingPathExtension().lastPathComponent
            let staged = staging.appendingPathComponent(FileNaming.fileName(stem: "\(stem)-edited", ext: format.fileExtension))
            progress(0.05)
            try await ffmpeg.editAudio(AudioEditPlan(source: url, output: staged, recipe: recipe, format: source))
            progress(0.95)
            let metadata = try await Task.detached(priority: .userInitiated) { () throws -> Data? in
                let values: [String: FileOps.MetadataValue] = ["edited": .bool(true), "sha256": .string(try FileHasher.sha256(of: staged))]
                return try FileOps.metadata(of: url, applying: .init(values: values, dropping: ["duration"], isCopy: true))
            }.value
            let wanted = folder.appendingPathComponent(FileNaming.fileName(stem: "\(stem)-edited", ext: format.fileExtension))
            let placed = try await FileOps.place(staged, as: wanted, with: metadata.map(FileOps.Companion.data) ?? .none)
            progress(1)
            if let problem = placed.metadataProblem {
                return .failure(ExportedWithProblem(url: placed.url, errorDescription: "Exported “\(placed.url.lastPathComponent)”, "
                    + "but its metadata file could not be written: \(problem)"))
            }
            return .success(placed.url)
        } catch {
            return .failure(error)
        }
    }
}

/// The audio canvas: the waveform with the parts kept, the playhead and a selection dragged across it, zoomed for long
/// files (R-4612), and Play.
struct EditAudioCanvas: View {
    @Bindable var edit: EditModel
    @State private var zoom: CGFloat = 1

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 2) {
                Text("Zoom").font(.caption).foregroundStyle(.secondary).padding(.trailing, 4)
                ForEach([1.0, 4.0, 16.0], id: \.self) { level in
                    ValueChip(title: "\(Int(level))×", selected: zoom == level) { zoom = level }
                }
                Spacer()
            }
            if edit.waveformFailed {
                Text(AppModel.shared.ffmpeg == nil ? "The waveform needs ffmpeg, which is not in this copy of MediaPull."
                    : "This file's sound could not be read, so its waveform cannot be shown or exported.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if edit.waveform.isEmpty {
                ProgressView().controlSize(.small).frame(maxHeight: .infinity)
            } else {
                GeometryReader { proxy in
                    let width = proxy.size.width * zoom
                    if zoom > 1 {
                        ScrollViewReader { reader in
                            ScrollView(.horizontal) {
                                ZStack(alignment: .topLeading) {
                                    WaveformView(edit: edit, width: width, height: proxy.size.height)
                                    // Followed while playing, so the playhead stays in view.
                                    Color.clear.frame(width: 1, height: 1)
                                        .padding(.leading, min(width - 1, edit.player.time / max(edit.mediaDuration, 0.001) * width))
                                        .id("playhead")
                                }
                                .frame(width: width, height: proxy.size.height)
                            }
                            .onChange(of: edit.player.time) { _, _ in
                                if edit.player.playing { reader.scrollTo("playhead", anchor: .center) }
                            }
                            .onAppear { reader.scrollTo("playhead", anchor: .center) }
                        }
                    } else {
                        WaveformView(edit: edit, width: width, height: proxy.size.height)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            HStack(spacing: 10) {
                Button {
                    edit.player.togglePlay()
                } label: {
                    Image(systemName: edit.player.playing ? "pause.fill" : "play.fill").frame(width: 18)
                }
                .controlSize(.large)
                .disabled(!edit.audioLengthKnown)
                .help(edit.player.playing ? "Pause" : "Play")
                .accessibilityLabel(edit.player.playing ? "Pause" : "Play")
                Text(EditTimelineView.clock(edit.player.time)).font(.callout.monospacedDigit())
                if let selection = edit.audioSelection {
                    Text("Selected \(EditTimelineView.clock(selection.start)) – \(EditTimelineView.clock(selection.end))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Result \(EditTimelineView.clock(edit.timeline.resultDuration(of: edit.mediaDuration)))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
}

/// The waveform at a given width: the parts kept in colour, the selection and the playhead. A click moves the playhead
/// and clears the selection; a drag selects.
private struct WaveformView: View {
    @Bindable var edit: EditModel
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let duration = max(edit.mediaDuration, 0.001)
        Canvas { context, _ in
            let peaks = edit.waveform
            let step = width / CGFloat(max(peaks.count, 1))
            let kept = edit.keptRanges
            for (index, peak) in peaks.enumerated() {
                let time = Double(index) / Double(peaks.count) * duration
                let inside = kept.contains { $0.start <= time && time < $0.end }
                let bar = max(1, CGFloat(peak) * height * 0.95)
                let rect = CGRect(x: CGFloat(index) * step, y: (height - bar) / 2, width: max(step * 0.8, 0.5), height: bar)
                context.fill(Path(rect), with: .color(inside ? Color.accentColor : Color.secondary.opacity(0.35)))
            }
            if let selection = edit.audioSelection {
                let rect = CGRect(x: selection.start / duration * width, y: 0,
                                  width: (selection.end - selection.start) / duration * width, height: height)
                context.fill(Path(rect), with: .color(.white.opacity(0.18)))
                context.stroke(Path(rect), with: .color(.white.opacity(0.6)), lineWidth: 1)
            }
            let x = min(width - 1, edit.player.time / duration * width)
            context.fill(Path(CGRect(x: x, y: 0, width: 2, height: height)), with: .color(.white))
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            let start = min(max(0, value.startLocation.x / width), 1) * duration
            let now = min(max(0, value.location.x / width), 1) * duration
            if abs(value.translation.width) < 3 {
                edit.player.seek(now)
            } else {
                edit.audioSelection = TimeRange(start: min(start, now), end: max(start, now))
            }
        }.onEnded { value in
            // A click, not a drag: the selection goes (D-132).
            if abs(value.translation.width) < 3 { edit.audioSelection = nil }
        })
        .accessibilityElement()
        .accessibilityLabel("Waveform")
        .accessibilityValue("\(EditTimelineView.clock(edit.player.time)) of \(EditTimelineView.clock(edit.mediaDuration))")
    }
}

/// Cuts, fades, volume and loudness (R-4610).
struct SoundTab: View {
    @Bindable var edit: EditModel

    var body: some View {
        InspectorSection(title: "Cut", key: "sound.cut", changed: !(edit.recipe?.timeline?.kept.isEmpty ?? true),
                         reset: { edit.resetCuts() }) {
            Text("Click the waveform to move the playhead; drag across it to select.").font(.caption).foregroundStyle(.secondary)
            if !edit.audioLengthKnown {
                Text("Measuring the file…").font(.caption).foregroundStyle(.secondary)
            } else if edit.preparingPlayback {
                Text("Preparing to play…").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Play Selection") { edit.playSelection() }
                Button("Keep Selection") { edit.keepSelection() }
                Button("Remove Selection") { edit.removeSelection() }
            }
            .controlSize(.small)
            .disabled(edit.audioSelection == nil || !edit.audioLengthKnown)
            HStack {
                Button("Start Here") { edit.trimStart(at: edit.player.time) }
                Button("End Here") { edit.trimEnd(at: edit.player.time) }
            }
            .controlSize(.small)
            .disabled(!edit.audioLengthKnown)
            // Nothing is cut against the system's guess of the length (audit 2026-11-21-4, C4-4).
            KeptParts(edit: edit, enabled: edit.audioLengthKnown)
        }
        InspectorSection(title: "Fades and Volume", key: "sound.volume",
                         changed: edit.timeline.fadeIn != 0 || edit.timeline.fadeOut != 0 || edit.timeline.volume != 1
                             || edit.timeline.normalize,
                         reset: { edit.setTimeline { $0.fadeIn = 0; $0.fadeOut = 0; $0.volume = 1; $0.normalize = false } }) {
            EditSlider(label: "Fade In",
                       value: Binding(get: { edit.timeline.fadeIn }, set: { value in edit.setTimeline { $0.fadeIn = value } }),
                       range: 0 ... 10, format: { String(format: "%.1f s", $0) }, model: edit)
            EditSlider(label: "Fade Out",
                       value: Binding(get: { edit.timeline.fadeOut }, set: { value in edit.setTimeline { $0.fadeOut = value } }),
                       range: 0 ... 10, format: { String(format: "%.1f s", $0) }, model: edit)
            EditSlider(label: "Volume",
                       value: Binding(get: { edit.timeline.volume * 100 }, set: { value in edit.setTimeline { $0.volume = value / 100 } }),
                       range: 0 ... 400, neutral: 100, format: { String(format: "%.0f%%", $0) }, model: edit)
            Toggle("Even out loudness", isOn: Binding(get: { edit.timeline.normalize },
                                                      set: { on in edit.setTimeline { $0.normalize = on } }))
                .help("Brings the sound to a standard loudness, as streaming services do")
        }
    }
}

/// The format of an audio export (R-4610).
struct AudioFormatSettings: View {
    @Bindable var edit: EditModel

    private var source: AudioOutput { .like(edit.current?.pathExtension ?? "m4a", codec: edit.audioSource?.codec) }

    var body: some View {
        Picker("Format", selection: Binding(
            get: { edit.recipe?.export.audioFormat },
            set: { value in edit.change { $0.export.audioFormat = value } }
        )) {
            Text("Like the Original (\(source.label))").tag(AudioOutput?.none)
            ForEach(AudioOutput.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
        }
        if let recipe = edit.recipe, let url = edit.current {
            let plan = AudioEditPlan(source: url, output: url, recipe: recipe,
                                     format: edit.audioSource ?? AudioSourceFormat(duration: edit.mediaDuration))
            // FLAC and Apple Lossless hold at most 24 bits: a 32-bit source is said (C9-4).
            let deep = [.flac, .alac].contains(plan.format) && (plan.sourceFormat?.bits ?? 0) > 24 && !plan.isFloat
            Text(plan.copiesStreams ? "Only cuts: the sound is copied, not encoded again."
                : "Encoded as \(plan.format.label)\(plan.format == .mp3 ? " (about 190 kbps)" : deep ? " at 24 bits" : "").")
                .font(.caption).foregroundStyle(.secondary)
        }
        let missing = [output.holdsArtwork ? nil : "artwork", output.holdsAlbumArtist ? nil : "an album artist"].compactMap(\.self)
        if !missing.isEmpty {
            Text("\(output.label) files cannot hold \(missing.joined(separator: " or ")).").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var output: AudioOutput { edit.recipe?.export.audioFormat ?? source }
}

/// Tags and artwork written into an audio export (R-4610).
struct AudioTagsTab: View {
    @Bindable var edit: EditModel

    private var source: AudioOutput { .like(edit.current?.pathExtension ?? "m4a", codec: edit.audioSource?.codec) }
    /// The format the export will be written in.
    private var output: AudioOutput { edit.recipe?.export.audioFormat ?? source }

    var body: some View {
        InspectorSection(title: "Tags", key: "tags.tags", changed: (edit.recipe?.tags ?? AudioTagEdit()) != AudioTagEdit(),
                         reset: { edit.change { $0.tags = nil } }) {
            Text("Empty fields keep the file's own tags.").font(.caption).foregroundStyle(.secondary)
            field("Title", \.title, current: edit.currentTags?.title)
            field("Artist", \.artist, current: edit.currentTags?.artist)
            field("Album", \.album, current: edit.currentTags?.album)
            if output.holdsAlbumArtist {
                field("Album Artist", \.albumArtist, current: edit.currentTags?.albumArtist)
            }
            field("Year", \.year, current: edit.currentTags?.year.map { "\($0)" })
            field("Genre", \.genre, current: edit.currentTags?.genre)
            field("Track", \.track, current: edit.currentTags?.track.map { "\($0)" })
        }
        InspectorSection(title: "Artwork", key: "tags.artwork") {
            if !output.holdsArtwork {
                Text("\(output.label) files cannot hold artwork.").font(.caption).foregroundStyle(.secondary)
            } else {
                artwork
            }
        }
    }

    private var artwork: some View {
        HStack {
            Text(edit.recipe?.tags?.artworkPath.map { ($0 as NSString).lastPathComponent }
                ?? (edit.recipe?.tags?.removeArtwork == true ? "None" : "As it is")).font(.callout)
            Spacer()
            Button("Choose…", action: chooseArtwork).controlSize(.small)
            Button("Remove") { edit.setTags { $0.artworkPath = nil; $0.removeArtwork = true } }.controlSize(.small)
        }
    }

    /// A tag field: empty shows the file's own value; typing replaces it; clearing what was typed keeps the file's.
    private func field(_ label: String, _ path: WritableKeyPath<AudioTagEdit, String?>, current: String?) -> some View {
        TextField(label, text: Binding(
            get: { edit.recipe?.tags?[keyPath: path] ?? "" },
            set: { value in edit.setTags { $0[keyPath: path] = value.isEmpty ? nil : value } }
        ), prompt: Text(current ?? label))
    }

    private func chooseArtwork() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png]
        panel.prompt = "Use"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        edit.setTags { $0.artworkPath = url.path; $0.removeArtwork = false }
    }
}
