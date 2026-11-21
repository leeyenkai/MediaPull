@preconcurrency import AVFoundation
import Foundation
import MediaPullCore
import MediaPullEdit
import MediaPullLibrary
import MediaPullMedia
import MediaPullNet

/// Video and audio in Edit/Frame (R-4609, R-4610): the timeline, playing, frame grabs and export.
extension EditModel {
    nonisolated static func duration(of url: URL) async -> Double {
        let seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        return seconds.isFinite ? max(0, seconds) : 0
    }

    var timeline: EditTimeline { recipe?.timeline ?? EditTimeline() }

    /// The original on the Trim tab (the timeline is cut from it), the result elsewhere when asked for.
    func loadPlayer() {
        guard let current else { return }
        playingResult = false
        guard kind == .audio else {
            player.load(current)
            return
        }
        // Ogg and Opus play from a copy the system can play (R-4205), as does a file whose length the system guesses wrong:
        // its player could not reach past the guess (audit 2026-11-21-3, C3-2, C3-10).
        let measured = audioSource?.duration
        preparingPlayback = true
        Task { [weak self] in
            let playable = await AudioPreview.playable(current, measured: measured)
            guard let self, self.current == current else { return }
            preparingPlayback = false
            guard let playable else {
                message = "This audio could not be prepared for playing."
                return
            }
            player.load(playable)
        }
    }

    /// Plays the video as it will be exported.
    func playResult() {
        guard let current, let recipe, kind == .video else { return }
        flushSave()
        let at = player.time
        Task { [weak self] in
            let item: AVPlayerItem
            do {
                item = try await VideoComposer.playerItem(AVURLAsset(url: current), recipe: recipe)
            } catch {
                // With the reason, as R-4609 asks (C5-4), and only while this file is still open (C6-6).
                guard let self, self.current == current else { return }
                if case let .notWritten(reason) = error as? VideoComposer.Failure {
                    message = "The edited video cannot be played: \(reason)"
                } else {
                    message = error.localizedDescription
                }
                return
            }
            // Still this file, still in view: never sound with no control on screen.
            guard let self, self.current == current, window?.section == .edit else { return }
            playingResult = true
            player.load(item, at: min(timeline.resultTime(of: at, duration: mediaDuration), timeline.resultDuration(of: mediaDuration)))
            player.player.play()
        }
    }

    /// The parts kept, as shown on the timeline.
    var keptRanges: [TimeRange] { timeline.keptRanges(duration: mediaDuration) }

    private func setKept(_ ranges: [TimeRange]) {
        change { recipe in
            var time = recipe.timeline ?? EditTimeline()
            let whole = ranges.count == 1 && ranges[0].start <= 0.001 && abs(ranges[0].end - mediaDuration) <= 0.001
            time.kept = whole ? [] : ranges
            recipe.timeline = time == EditTimeline() ? nil : time
        }
    }

    /// Everything before the playhead goes.
    func trimStart(at seconds: Double) {
        let kept = keptRanges.compactMap { $0.end > seconds ? TimeRange(start: max($0.start, seconds), end: $0.end) : nil }
        guard !kept.isEmpty else { return }
        setKept(kept)
    }

    /// Everything after the playhead goes.
    func trimEnd(at seconds: Double) {
        let kept = keptRanges.compactMap { $0.start < seconds ? TimeRange(start: $0.start, end: min($0.end, seconds)) : nil }
        guard !kept.isEmpty else { return }
        setKept(kept)
    }

    /// A cut at the playhead, so either side can be removed.
    func split(at seconds: Double) {
        var kept: [TimeRange] = []
        for range in keptRanges {
            if range.start + 0.05 < seconds, seconds < range.end - 0.05 {
                kept += [TimeRange(start: range.start, end: seconds), TimeRange(start: seconds, end: range.end)]
            } else {
                kept.append(range)
            }
        }
        // Kept as separate parts (merging would join them again), so the person can remove one.
        change { recipe in
            var time = recipe.timeline ?? EditTimeline()
            time.kept = kept
            recipe.timeline = time
        }
    }

    func removePart(_ part: TimeRange) {
        let kept = keptRanges.filter { $0 != part }
        guard !kept.isEmpty else {
            message = "At least one part has to stay."
            return
        }
        setKept(kept)
    }

    func resetCuts() {
        change { recipe in
            recipe.timeline?.kept = []
            if recipe.timeline == EditTimeline() { recipe.timeline = nil }
        }
    }

    /// A binding helper for the timeline's settings.
    func setTimeline(_ body: (inout EditTimeline) -> Void) {
        change { recipe in
            var time = recipe.timeline ?? EditTimeline()
            body(&time)
            recipe.timeline = time == EditTimeline() ? nil : time
        }
    }

    /// Saves the original's frame at the playhead as a PNG beside it (R-3402's naming), lossless.
    func saveFrame() {
        guard let current, kind == .video else { return }
        let at = player.time
        let folder = exportFolder ?? current.deletingLastPathComponent()
        Task { [weak self] in
            guard let frame = await VideoComposer.frame(current, at: at) else {
                self?.message = "That frame could not be read."
                return
            }
            let minutes = Int(at) / 60, rest = at - Double(minutes * 60)
            let stem = String(format: "%@_frame_%02dm%02d-%03ds", current.deletingPathExtension().lastPathComponent, minutes,
                              Int(rest), Int((rest - Double(Int(rest))) * 1000))
            // Within the name budget, however long the video's name.
            let name = FileNaming.fileName(stem: stem, ext: "png")
            do {
                // Staged and written off the main actor (C4-5).
                let placed = try await Task.detached(priority: .userInitiated) { () async throws -> URL in
                    let fm = FileManager.default
                    let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
                    defer { try? fm.removeItem(at: staging) }
                    let staged = staging.appendingPathComponent(name)
                    try ImageEditing.write(frame, format: .png, metadataFrom: nil, to: staged)
                    return try await FileOps.place(staged, as: folder.appendingPathComponent(name), with: .none).url
                }.value
                self?.message = "Saved “\(placed.lastPathComponent)”."
                AppModel.shared.fileChangeRevision += 1
            } catch {
                self?.message = error.localizedDescription
            }
        }
    }

    // MARK: Export

    /// Writes the edited video (re-encoded only when the picture changes, D-130), then places it at a free name.
    /// Off the main actor: staging folders on a slow disk never hold up the window (audit 2026-11-21-4, C4-5).
    @concurrent
    nonisolated static func exportVideo(_ url: URL, recipe: EditRecipe, into folder: URL,
                                        progress: @escaping @Sendable (Double) -> Void) async -> Result<URL, Error>
    {
        do {
            let fm = FileManager.default
            let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
            defer { try? fm.removeItem(at: staging) }
            let ext = VideoComposer.container(for: url, recipe: recipe).rawValue
            let stem = url.deletingPathExtension().lastPathComponent
            let staged = staging.appendingPathComponent(FileNaming.fileName(stem: "\(stem)-edited", ext: ext))
            let built = try await VideoComposer.export(url, recipe: recipe, to: staged, progress: progress)
            let size = built.renderSize
            let metadata = try await Task.detached(priority: .userInitiated) { () throws -> Data? in
                let values: [String: FileOps.MetadataValue] = [
                    "edited": .bool(true), "sha256": .string(try FileHasher.sha256(of: staged)),
                    "width": .int(Int(size.width)), "height": .int(Int(size.height)),
                ]
                // As for photos: the size it has now, and no place when the location is left out (audit C3-5).
                let place = recipe.export.keepLocation ? [] : ["location_name", "location_id", "location", "latitude", "longitude"]
                return try FileOps.metadata(of: url, applying: .init(values: values, dropping: ["duration"] + place, isCopy: true))
            }.value
            let wanted = folder.appendingPathComponent(FileNaming.fileName(stem: "\(stem)-edited", ext: ext))
            let placed = try await FileOps.place(staged, as: wanted, with: metadata.map(FileOps.Companion.data) ?? .none)
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
