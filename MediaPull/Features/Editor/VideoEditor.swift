import Foundation
import MediaPullCore
import MediaPullLibrary
import MediaPullMedia
import MediaPullNet
import Observation
import SwiftUI

/// Saves a full-resolution frame and trims videos without re-encoding (SPEC section 34).
@Observable
final class VideoEditorModel {
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

    init(request: EditorRequest, window: WindowModel?) {
        self.request = request
        self.window = window
    }

    var app: AppModel { .shared }
    var isLibraryFile: Bool { if case .file = request.subject { true } else { false } }
    var hasNameChange: Bool { name.trimmingCharacters(in: .whitespacesAndNewlines) != originalName }

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
                let target = LibraryModel.uniqueURL(url.deletingLastPathComponent().appendingPathComponent(FileNaming.fileName(stem: stem, ext: "png")))
                try FileManager.default.moveItem(at: still, to: target)
                Self.writeSidecar(from: url, to: target, changes: [
                    "width": size.width, "height": size.height, "sha256": (try? FileHasher.sha256(of: target)) ?? "",
                    "edited": true, "frame_time": (time * 1000).rounded() / 1000,
                ], dropping: ["num", "count", "duration"])
                finishLibraryChange()
                report("Saved the frame at \(Self.timestamp(time)) as \(target.lastPathComponent).")
            case let .item(id):
                guard let window, var item = window.itemsByID[id] else { return }
                var variant = MediaVariant(id: still.absoluteString, url: still, format: .png, origin: item.best?.origin ?? .video)
                variant.pixelSize = size
                item.kind = .image
                item.variants = [variant]
                item.bestID = variant.id
                window.customNames[id] = stem
                guard let destination = window.saveFolder else {
                    fail("Choose a library folder first.")
                    return
                }
                _ = app.save([item], from: window, to: destination, title: "Saving a video frame")
                report("Saving the frame at \(Self.timestamp(time)) (\(size.width) × \(size.height)) to your library.")
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    // MARK: Trimming

    func chooseTrim() async {
        guard let stage else { return }
        if let range = await stage.trim(duration: duration) {
            selection = range.lowerBound <= 0.001 && range.upperBound >= duration - 0.001 ? nil : range
        }
    }

    /// Writes the selected part next to the original (a copy) or in its place (the original goes to the Trash).
    func saveTrim(replacing: Bool) async {
        guard let sourceFile, let selection else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try FileManager.default.createDirectory(at: WindowModel.editsCache, withIntermediateDirectories: true)
            let trimmed = WindowModel.editsCache.appendingPathComponent(UUID().uuidString + "." + fileExtension)
            try await VideoTools.trim(sourceFile, from: selection.lowerBound, to: selection.upperBound, output: trimmed)
            let length = await VideoTools.duration(of: trimmed) ?? (selection.upperBound - selection.lowerBound)
            switch request.subject {
            case let .file(url):
                let manager = FileManager.default
                let folder = url.deletingLastPathComponent()
                var target: URL
                if replacing {
                    target = folder.appendingPathComponent(FileNaming.fileName(stem: cleanName, ext: url.pathExtension))
                    try manager.trashItem(at: url, resultingItemURL: nil)
                    target = LibraryModel.uniqueURL(target)
                } else {
                    let stem = hasNameChange ? cleanName : "\(cleanName)_trimmed"
                    target = LibraryModel.uniqueURL(folder.appendingPathComponent(FileNaming.fileName(stem: stem, ext: url.pathExtension)))
                }
                try manager.moveItem(at: trimmed, to: target)
                Self.writeSidecar(from: url, to: target, changes: [
                    "duration": (length * 1000).rounded() / 1000, "sha256": (try? FileHasher.sha256(of: target)) ?? "", "edited": true,
                    "trimmed_from": [(selection.lowerBound * 1000).rounded() / 1000, (selection.upperBound * 1000).rounded() / 1000],
                ], dropping: [], trashSource: replacing)
                finishLibraryChange()
                window?.editorRequest = nil
                window?.previewSubject = .file(target)
            case let .item(id):
                guard let window, var item = window.itemsByID[id] else { return }
                var variant = MediaVariant(id: trimmed.absoluteString, url: trimmed, format: fileExtension == "mov" ? .mov : .mp4,
                                           origin: item.best?.origin ?? .video)
                variant.duration = length
                variant.pixelSize = item.best?.pixelSize
                item.variants = [variant]
                item.bestID = variant.id
                if hasNameChange { window.customNames[id] = cleanName }
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

    /// Renames a library video and its metadata file.
    func rename() {
        guard case let .file(url) = request.subject, hasNameChange else { return }
        let target = LibraryModel.uniqueURL(url.deletingLastPathComponent().appendingPathComponent(FileNaming.fileName(stem: cleanName, ext: url.pathExtension)))
        do {
            try FileManager.default.moveItem(at: url, to: target)
            let sidecar = Sidecar.sidecarURL(for: url)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try? FileManager.default.moveItem(at: sidecar, to: Sidecar.sidecarURL(for: target))
            }
            finishLibraryChange()
            window?.editorRequest = nil
            window?.previewSubject = .file(target)
        } catch {
            fail(error.localizedDescription)
        }
    }

    func keepNameOnly() {
        guard case let .item(id) = request.subject, hasNameChange else { return }
        window?.customNames[id] = cleanName
        window?.editorRequest = nil
    }

    private func finishLibraryChange() {
        window?.library.reload()
        window?.library.refreshTree()
        app.libraryRevision += 1
    }

    /// Copies the video's metadata file for a derived file, with updated fields (SPEC R-3404).
    static func writeSidecar(from source: URL, to target: URL, changes: [String: Any], dropping: [String], trashSource: Bool = false) {
        let oldSidecar = Sidecar.sidecarURL(for: source)
        guard let data = try? Data(contentsOf: oldSidecar),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        for key in dropping {
            object[key] = nil
        }
        for (key, value) in changes {
            object[key] = value
        }
        if let output = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? output.write(to: Sidecar.sidecarURL(for: target), options: .atomic)
        }
        if trashSource { try? FileManager.default.trashItem(at: oldSidecar, resultingItemURL: nil) }
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
                        Text("Keep \(VideoEditorModel.timestamp(selection.lowerBound)) to \(VideoEditorModel.timestamp(selection.upperBound))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button("Clear") { model.selection = nil }
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
        .task { await model.load() }
        .onDisappear { model.stage?.stop() }
    }

    private var hint: String {
        model.isLibraryFile
            ? "Frames are saved next to the video. Trimming copies the video data without re-encoding; Replace moves the original to the Trash."
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
