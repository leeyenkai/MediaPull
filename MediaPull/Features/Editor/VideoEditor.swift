import Foundation
import MediaPullCore
import MediaPullLibrary
import MediaPullMedia
import MediaPullNet
import Observation
import SwiftUI

/// Saves a full-resolution frame and trims videos without re-encoding (SPEC section 34).
@Observable
final class VideoEditorModel: UnsavedEditing {
    let request: EditorRequest
    weak var window: WindowModel?
    var stage: VideoStage?
    var name = ""
    var originalName = ""
    var fileExtension = "mp4"
    var duration: Double = 0
    var selection: ClosedRange<Double>?
    var message: String?
    var isError = false
    var isWorking = false
    var isLoading = true
    private(set) var sourceFile: URL?
    /// The file opened, so Save never acts on another file that took its name since (an Undo, a rename; audit 18, B18-M2).
    private var openedIdentity: String?

    /// Why Save or Rename did nothing: the opened file is gone, or another file has its name now (audit 19, A19-m3).
    static func changedMessage(_ url: URL) -> String {
        FileManager.default.fileExists(atPath: url.path)
            ? "“\(url.lastPathComponent)” is another file now (it was renamed or moved since it was opened), so nothing was changed."
            : "“\(url.lastPathComponent)” is no longer there (it was moved or deleted since it was opened), so nothing was changed."
    }

    init(request: EditorRequest, window: WindowModel?) {
        self.request = request
        self.window = window
    }

    var app: AppModel { .shared }
    var isLibraryFile: Bool { if case .file = request.subject { true } else { false } }
    var hasNameChange: Bool { name.trimmingCharacters(in: .whitespacesAndNewlines) != originalName }
    var hasUnsavedChanges: Bool { hasNameChange || selection != nil }

    private var cleanName: String {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileNaming.sanitize(text.isEmpty ? originalName : text, maxBytes: 200)
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        switch request.subject {
        case let .file(url):
            sourceFile = url
            openedIdentity = AccountFolderRecord.number(of: url)
            originalName = url.deletingPathExtension().lastPathComponent
            fileExtension = url.pathExtension
        case let .item(id):
            guard let window, let item = window.itemsByID[id] else {
                fail("This item is no longer in the list.")
                return
            }
            originalName = window.customNames[id] ?? item.best.flatMap { URLNormalizer.baseName(of: $0.url) } ?? "video"
            if item.kind == .stream || (item.best?.requiresEngine ?? false) {
                fail("Streams are put together when they are saved. Save this video first, then edit it from the Library.")
                name = originalName
                return
            }
            sourceFile = await window.previewFile(for: item)
            if sourceFile == nil { fail("The video could not be downloaded for editing.") }
            fileExtension = sourceFile?.pathExtension.lowercased() == "mov" ? "mov" : "mp4"
        }
        name = originalName
        guard let sourceFile else { return }
        duration = await VideoTools.duration(of: sourceFile) ?? 0
        guard duration > 0 else {
            fail("This video could not be opened for editing.")
            return
        }
        stage = VideoStage(file: sourceFile)
    }

    private func fail(_ text: String) {
        message = text
        isError = true
    }

    private func report(_ text: String) {
        message = text
        isError = false
    }

    static func timestamp(_ seconds: Double, forFileName: Bool = false) -> String {
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let rest = total - Double(minutes * 60)
        return forFileName ? String(format: "%02dm%06.3fs", minutes, rest).replacingOccurrences(of: ".", with: "-")
            : String(format: "%d:%06.3f", minutes, rest)
    }

    // MARK: Frames

    /// Saves the frame being shown as a lossless PNG at the video's full resolution.
    func saveFrame() async {
        guard let sourceFile, let stage else { return }
        // A still of the video on screen, never of another that took its name (audit 20, A20-m3).
        if case let .file(url) = request.subject, openedIdentity != nil, AccountFolderRecord.number(of: url) != openedIdentity {
            fail(Self.changedMessage(url))
            return
        }
        let time = stage.currentTime
        isWorking = true
        defer { isWorking = false }
        do {
            let image = try await VideoTools.frame(of: sourceFile, at: time)
            try FileManager.default.createDirectory(at: WindowModel.editsCache, withIntermediateDirectories: true)
            let still = WindowModel.editsCache.appendingPathComponent(UUID().uuidString + ".png")
            let size = PixelSize(width: image.width, height: image.height)
            try await Task.detached(priority: .userInitiated) {
                try ImageEditing.write(image, format: .png, metadataFrom: nil, to: still)
            }.value
            let stem = "\(cleanName)_frame_\(Self.timestamp(time, forFileName: true))"
            switch request.subject {
            case let .file(url):
                let wanted = url.deletingLastPathComponent().appendingPathComponent(FileNaming.fileName(stem: stem, ext: "png"))
                // A new file at a free name, with a copy of the video's metadata file that is not part of its post (R-3404).
                let metadata = try await Self.metadata(from: url, for: still, values: [
                    "width": .int(size.width), "height": .int(size.height), "edited": .bool(true),
                    "frame_time": .double((time * 1000).rounded() / 1000),
                ], dropping: ["num", "count", "duration"], isCopy: true)
                let placed = try await FileOps.place(still, as: wanted, with: metadata.map(FileOps.Companion.data) ?? .none)
                let target = placed.url, problem = placed.metadataProblem
                finishLibraryChange()
                report("Saved the frame at \(Self.timestamp(time)) as \(target.lastPathComponent)."
                    + (problem.map { " The metadata file could not be written: \($0)" } ?? ""))
            case let .item(id):
                guard let window, let video = window.itemsByID[id] else { return }
                var variant = MediaVariant(id: still.absoluteString, url: still, format: .png, origin: video.best?.origin ?? .video)
                variant.pixelSize = size
                // A separate item: the video keeps its own name, saved state and preview.
                let frame = video.madeCopy(variant, kind: .image, suffix: "frame-\(Int((time * 1000).rounded()))")
                window.customNames[frame.id] = stem
                guard let destination = window.saveFolder else {
                    fail("Choose a library folder first.")
                    return
                }
                _ = app.save([frame], from: window, to: destination, title: "Saving a video frame")
                report("Saving the frame at \(Self.timestamp(time)) (\(size.width) × \(size.height)) to your library.")
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    // MARK: Trimming

    func clearSelection() {
        selection = nil
        stage?.clearTrim()
    }

    func chooseTrim() async {
        guard let stage else { return }
        if let range = await stage.trim(duration: duration) {
            selection = range.lowerBound <= 0.001 && range.upperBound >= duration - 0.001 ? nil : range
        }
    }

    /// Writes the selected part next to the original (a copy) or in its place (the original goes to the Trash).
    func saveTrim(replacing: Bool) async {
        guard let sourceFile, let selection else { return }
        if case let .file(url) = request.subject, openedIdentity != nil, AccountFolderRecord.number(of: url) != openedIdentity {
            fail(Self.changedMessage(url))
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try FileManager.default.createDirectory(at: WindowModel.editsCache, withIntermediateDirectories: true)
            let trimmed = WindowModel.editsCache.appendingPathComponent(UUID().uuidString + "." + fileExtension)
            try await VideoTools.trim(sourceFile, from: selection.lowerBound, to: selection.upperBound, output: trimmed)
            let length = await VideoTools.duration(of: trimmed) ?? (selection.upperBound - selection.lowerBound)
            switch request.subject {
            case let .file(url):
                let folder = url.deletingLastPathComponent()
                let stem = replacing ? cleanName : (hasNameChange ? cleanName : "\(cleanName)_trimmed")
                let wanted = folder.appendingPathComponent(FileNaming.fileName(stem: stem, ext: url.pathExtension))
                let metadata = try await Self.metadata(from: url, for: trimmed, values: [
                    "duration": .double((length * 1000).rounded() / 1000), "edited": .bool(true),
                    "trimmed_from": .doubles([(selection.lowerBound * 1000).rounded() / 1000,
                                              (selection.upperBound * 1000).rounded() / 1000]),
                ], dropping: [], isCopy: !replacing)
                let target: URL
                if replacing {
                    // The original and its metadata file go to the Trash as one change ⌘Z takes back (D-107).
                    let replaced = try await app.replaceFile(url, identity: openedIdentity, with: trimmed, named: wanted,
                                                             metadata: metadata, title: "Trim “\(url.lastPathComponent)”")
                    window?.registerUndo(replaced.entry)
                    target = replaced.url
                } else {
                    let placed = try await FileOps.place(trimmed, as: wanted, with: metadata.map(FileOps.Companion.data) ?? .none)
                    target = placed.url
                    if let problem = placed.metadataProblem { report("Saved, but the metadata file could not be written: \(problem)") }
                }
                finishLibraryChange()
                window?.editorRequest = nil
                window?.previewSubject = .file(target)
            case let .item(id):
                guard let window, let video = window.itemsByID[id] else { return }
                var variant = MediaVariant(id: trimmed.absoluteString, url: trimmed, format: fileExtension == "mov" ? .mov : .mp4,
                                           origin: video.best?.origin ?? .video)
                variant.duration = length
                variant.pixelSize = video.best?.pixelSize
                // A copy of its own (audit 7, C7-M2), named after the video, not after the temporary file.
                let item = video.madeCopy(variant, suffix: "trimmed")
                window.customNames[item.id] = cleanName
                guard let destination = window.saveFolder else {
                    fail("Choose a library folder first.")
                    return
                }
                _ = app.save([item], from: window, to: destination, title: "Saving a trimmed video")
                window.editorRequest = nil
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Renames a library video and its metadata file, as one journaled change ⌘Z takes back (R-3806).
    func rename() {
        guard case let .file(url) = request.subject, hasNameChange else { return }
        // Never another file that took the opened file's name (audit 19, C19-m4).
        if openedIdentity != nil, AccountFolderRecord.number(of: url) != openedIdentity {
            fail(Self.changedMessage(url))
            return
        }
        let plan = FolderOperations.rename(url, to: FileNaming.fileName(stem: cleanName, ext: url.pathExtension))
        guard !plan.isEmpty else {
            window?.editorRequest = nil
            return
        }
        Task {
            let entry = await app.applyChange(plan)
            // A rename that changed nothing leaves nothing for ⌘Z (audit 5, B5-m5).
            if !entry.steps.isEmpty { window?.registerUndo(entry) }
            if let failure = entry.failures.first {
                fail(failure)
                return
            }
            finishLibraryChange()
            window?.editorRequest = nil
            window?.previewSubject = .file(plan.moves.first?.destination ?? url)
        }
    }

    func keepNameOnly() {
        guard case let .item(id) = request.subject, hasNameChange else { return }
        window?.customNames[id] = cleanName
        window?.editorRequest = nil
    }

    /// Every window's Library and folder tree reload once on this (LibraryPane watches it).
    private func finishLibraryChange() {
        app.libraryRevision += 1
    }

    /// The source video's metadata with `values` and the new file's checksum (a whole video can be gigabytes: never on the
    /// main actor); nil when the video has no metadata file. A copy drops the keys that identify the item (D-105).
    static func metadata(from source: URL, for file: URL, values: [String: FileOps.MetadataValue], dropping: [String],
                         isCopy: Bool) async throws -> Data?
    {
        try await Task.detached(priority: .userInitiated) { () throws -> Data? in
            var values = values
            values["sha256"] = .string(try FileHasher.sha256(of: file))
            return try FileOps.metadata(of: source, applying: .init(values: values, dropping: dropping, isCopy: isCopy))
        }.value
    }
}

/// The video editor inside the Preview pane.
struct VideoEditorView: View {
    @State private var model: VideoEditorModel
    private let onClose: () -> Void

    init(request: EditorRequest, window: WindowModel?, onClose: @escaping () -> Void) {
        _model = State(initialValue: VideoEditorModel(request: request, window: window))
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("Name").foregroundStyle(.secondary)
                TextField("File name", text: $model.name)
                    .textFieldStyle(.roundedBorder)
                Text(".\(model.fileExtension)").foregroundStyle(.secondary).monospaced()
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.85))
                if let stage = model.stage {
                    VideoStageView(stage: stage)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if model.isLoading {
                    ProgressView()
                } else {
                    Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 160, maxHeight: .infinity)
            if model.stage != nil {
                HStack(spacing: 8) {
                    Button { Task { await model.saveFrame() } } label: {
                        Label("Save Frame", systemImage: "camera.viewfinder")
                    }
                    .help("Save the frame being shown as a full-resolution PNG")
                    Button { Task { await model.chooseTrim() } } label: {
                        Label("Trim", systemImage: "timeline.selection")
                    }
                    .help("Choose the part to keep with the trim bar")
                    Spacer(minLength: 0)
                    if let selection = model.selection {
                        Text("""
                            Keep \(VideoEditorModel.timestamp(selection.lowerBound)) to \(VideoEditorModel.timestamp(selection.upperBound))
                            """)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button("Clear") { model.clearSelection() }
                    } else {
                        Text("Length \(VideoEditorModel.timestamp(model.duration))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .controlSize(.small)
            }
            if let message = model.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(model.isError ? .orange : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if model.isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { close() }
                actions
            }
            .controlSize(.small)
        }
        .padding(12)
        .disabled(model.isWorking)
        .task {
            model.window?.activeEditor = model
            await model.load()
        }
        .onDisappear { model.stage?.stop() }
    }

    private var hint: String {
        model.isLibraryFile
            ? """
                Frames are saved next to the video. Trimming copies the video data without re-encoding; Replace moves the original to the \
                Trash.
                """
            : "Frames and trimmed videos are saved to your library. Trimming copies the video data without re-encoding."
    }

    @ViewBuilder
    private var actions: some View {
        if model.isLibraryFile {
            Button("Rename") { model.rename() }
                .disabled(!model.hasNameChange || model.selection != nil)
            Button("Save Trimmed Copy") { Task { await model.saveTrim(replacing: false) } }
                .disabled(model.selection == nil)
            Button("Replace Original") { Task { await model.saveTrim(replacing: true) } }
                .buttonStyle(.borderedProminent)
                .disabled(model.selection == nil)
        } else {
            Button("Keep Name Only") { model.keepNameOnly() }
                .disabled(!model.hasNameChange || model.selection != nil)
            Button("Save Trimmed to “\(model.window?.saveFolderName ?? "Library")”") { Task { await model.saveTrim(replacing: false) } }
                .buttonStyle(.borderedProminent)
                .disabled(model.selection == nil)
        }
    }

    private func close() {
        model.stage?.stop()
        onClose()
    }
}
