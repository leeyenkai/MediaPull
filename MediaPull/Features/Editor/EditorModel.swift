import AppKit
import Foundation
import MediaPullCore
import MediaPullLibrary
import MediaPullMedia
import MediaPullNet
import Observation

/// What the Preview pane shows.
enum PreviewSubject: Hashable {
    case item(String)
    case file(URL)
}

/// What the editor was opened for.
struct EditorRequest: Identifiable {
    enum Subject: Equatable {
        /// A file in a library folder: edits replace it (the original goes to the Trash) or make a copy.
        case file(URL)
        /// An extracted item that is not saved yet: edits apply when it is saved.
        case item(String)
    }

    let id = UUID()
    var subject: Subject
}

enum CropAspect: String, CaseIterable, Identifiable {
    case free, original, square, portrait45, portrait34, landscape169, portrait916

    var id: String { rawValue }

    var label: String {
        switch self {
        case .free: "Free"
        case .original: "Original"
        case .square: "Square"
        case .portrait45: "4:5"
        case .portrait34: "3:4"
        case .landscape169: "16:9"
        case .portrait916: "9:16"
        }
    }

    /// Width divided by height in pixels, or nil for free cropping.
    func ratio(for image: CGImage) -> CGFloat? {
        switch self {
        case .free: nil
        case .original: CGFloat(image.width) / CGFloat(max(image.height, 1))
        case .square: 1
        case .portrait45: 4.0 / 5.0
        case .portrait34: 3.0 / 4.0
        case .landscape169: 16.0 / 9.0
        case .portrait916: 9.0 / 16.0
        }
    }
}

/// Crop, rotate, flip and rename (SPEC section 32).
/// An editor that can hold changes not yet saved.
@MainActor
protocol UnsavedEditing: AnyObject {
    var hasUnsavedChanges: Bool { get }
}

@Observable
final class EditorModel: UnsavedEditing {
    let request: EditorRequest
    weak var window: WindowModel?
    var original: CGImage?
    var working: CGImage?
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    var aspect: CropAspect = .free
    var name = ""
    var originalName = ""
    var fileExtension = ""
    var isImage = true
    var isLoading = true
    var message: String?
    var isSaving = false
    var hasUnsavedChanges: Bool { hasImageEdits || hasNameChange }
    private(set) var turns = 0
    private(set) var flipped = false
    /// The rotations and flips made, in order, so a JPEG that was only turned is saved without re-encoding.
    private var reorientation = ImageEditing.Reorientation()
    private var sourceFile: URL?
    /// The file opened, so Save never acts on another file that took its name since (an Undo, a rename; audit 18, B18-M2).
    private var openedIdentity: String?

    /// Why Save or Rename did nothing: the opened file is gone, or another file has its name now (audit 19, A19-m3).
    static func changedMessage(_ url: URL) -> String {
        FileManager.default.fileExists(atPath: url.path)
            ? "“\(url.lastPathComponent)” is another file now (it was renamed or moved since it was opened), so nothing was changed."
            : "“\(url.lastPathComponent)” is no longer there (it was moved or deleted since it was opened), so nothing was changed."
    }
    private var format: MediaFormat = .jpeg

    init(request: EditorRequest, window: WindowModel?) {
        self.request = request
        self.window = window
    }

    var app: AppModel { .shared }

    var hasImageEdits: Bool {
        turns % 4 != 0 || flipped || crop.width < 0.999 || crop.height < 0.999
    }

    var hasNameChange: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines) != originalName
    }

    var outputSize: PixelSize? {
        guard let working else { return nil }
        return PixelSize(width: Int((crop.width * CGFloat(working.width)).rounded()),
                         height: Int((crop.height * CGFloat(working.height)).rounded()))
    }

    var title: String {
        switch request.subject {
        case let .file(url): url.lastPathComponent
        case .item: "Extracted item"
        }
    }

    // MARK: Loading

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
                message = "This item is no longer in the list."
                return
            }
            originalName = window.customNames[id] ?? item.best.flatMap { URLNormalizer.baseName(of: $0.url) } ?? "media"
            fileExtension = window.predictedFormat(item).fileExtension
            isImage = item.kind == .image || item.kind == .animatedImage
            if isImage {
                sourceFile = await window.previewFile(for: item)
                if sourceFile == nil { message = "The image could not be downloaded for editing." }
            }
        }
        name = originalName
        guard let sourceFile else { return }
        let file = sourceFile
        // Sniffing, counting frames and choosing the output format read the file, so they run off the main actor.
        // Animated images of any format are rename-only: editing would keep just the first frame (R-3202).
        let format = await Task.detached(priority: .userInitiated) { () -> MediaFormat? in
            let sniffed = Sniffer.sniff(MediaConverter.head(of: file)).format ?? MediaFormat.fromExtension(file.pathExtension)
            guard sniffed?.kind == .image || sniffed?.kind == .animatedImage, sniffed != .gif else { return nil }
            let analysis = ImageConversion.analyze(file)
            if analysis?.isAnimated ?? false { return nil }
            if sniffed == .jpeg { return .jpeg }
            if sniffed?.isLosslessImage ?? false { return .png }
            return analysis.map { ImageConversion.stillTarget(for: $0) == .jpeg ? .jpeg : .png } ?? .png
        }.value
        guard isImage, let format else {
            isImage = false
            return
        }
        self.format = format
        if case .item = request.subject { fileExtension = format.fileExtension }
        let image = await Task.detached(priority: .userInitiated) { ImageEditing.loadOriented(file) }.value
        original = image
        working = image
        if image == nil { message = "This image could not be opened for editing." }
    }

    // MARK: Edits

    /// Full-resolution redraws run off the main actor, one after another so they apply in order.
    @ObservationIgnored private var editChain: Task<Void, Never>?
    /// Bumped by Reset: redraws started before it, still running or queued, must not bring their edit back.
    @ObservationIgnored private var generation = 0

    private func transform(_ operation: @escaping @Sendable (CGImage) -> CGImage?, then: (() -> Void)? = nil) {
        let previous = editChain
        let started = generation
        editChain = Task { [weak self] in
            await previous?.value
            guard let current = self?.working, self?.generation == started else { return }
            let image = await Task.detached(priority: .userInitiated) { operation(current) }.value
            guard let self, self.generation == started else { return }
            self.working = image
            then?()
        }
    }

    /// Waits for any rotate or flip still being drawn.
    func settled() async {
        await editChain?.value
    }

    func rotate(clockwise: Bool) {
        guard working != nil else { return }
        let quarter = clockwise ? 1 : -1
        // The aspect crop depends on the rotated size, so it is applied again once the new image is drawn.
        transform {
            ImageEditing.rotated($0, quarterTurns: quarter)
        } then: { [weak self] in
            self?.applyAspect()
        }
        turns += quarter
        reorientation.rotate(clockwise: clockwise)
        crop = clockwise ? CGRect(x: 1 - crop.maxY, y: crop.minX, width: crop.height, height: crop.width)
            : CGRect(x: crop.minY, y: 1 - crop.maxX, width: crop.height, height: crop.width)
        applyAspect()
    }

    func flip() {
        guard working != nil else { return }
        transform { ImageEditing.flippedHorizontally($0) }
        flipped.toggle()
        reorientation.flip()
        crop = CGRect(x: 1 - crop.maxX, y: crop.minY, width: crop.width, height: crop.height)
    }

    func reset() {
        generation += 1
        editChain = nil
        working = original
        turns = 0
        reorientation = ImageEditing.Reorientation()
        flipped = false
        aspect = .free
        crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    /// Fits the largest centred crop with the chosen aspect ratio.
    func applyAspect() {
        guard let working, let ratio = aspect.ratio(for: working) else { return }
        let unitRatio = ratio * CGFloat(working.height) / CGFloat(working.width)
        var width: CGFloat = 1
        var height = width / unitRatio
        if height > 1 {
            height = 1
            width = unitRatio
        }
        crop = CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }

    func rendered() -> CGImage? {
        guard let working else { return nil }
        return ImageEditing.cropped(working, to: crop)
    }

    // MARK: Saving

    /// An extracted item keeps the new name for when it is saved, with no other change.
    func keepNameOnly() {
        guard case let .item(id) = request.subject, hasNameChange else { return }
        window?.customNames[id] = cleanName
    }

    private var cleanName: String {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileNaming.sanitize(text.isEmpty ? originalName : text, maxBytes: 200)
    }

    /// Writes the edited image to a new file in a cache folder, after any pending rotate or flip, off the main actor.
    private func writeEdited() async throws -> URL {
        await editChain?.value
        guard let working else { throw ImageConversionError.cannotWrite }
        try FileManager.default.createDirectory(at: WindowModel.editsCache, withIntermediateDirectories: true)
        let output = WindowModel.editsCache.appendingPathComponent(UUID().uuidString + "." + format.fileExtension)
        let (crop, format, source, reorientation) = (crop, format, sourceFile, reorientation)
        let uncropped = crop.width >= 0.999 && crop.height >= 0.999
        try await Task.detached(priority: .userInitiated) {
            // Only turned or flipped: a JPEG keeps its exact image data and gets a new orientation tag (lossless).
            if uncropped, format == .jpeg, let source {
                try ImageEditing.writeReoriented(source, by: reorientation, to: output)
                return
            }
            guard let image = ImageEditing.cropped(working, to: crop) else { throw ImageConversionError.cannotWrite }
            try ImageEditing.write(image, format: format, metadataFrom: source, to: output)
        }.value
        return output
    }

    /// Library file: replace it (the original goes to the Trash) or save a copy next to it.
    func saveFile(asCopy: Bool) async -> URL? {
        guard case let .file(url) = request.subject, !isSaving else { return nil }
        guard openedIdentity == nil || AccountFolderRecord.number(of: url) == openedIdentity else {
            message = Self.changedMessage(url)
            return nil
        }
        isSaving = true
        defer { isSaving = false }
        let folder = url.deletingLastPathComponent()
        do {
            if !hasImageEdits {
                guard hasNameChange || asCopy else { return url }
                if !asCopy {
                    // A new name only: one journaled rename, so ⌘Z takes it back and the metadata file moves with it (R-3806).
                    let plan = FolderOperations.rename(url, to: FileNaming.fileName(stem: cleanName, ext: fileExtension))
                    guard !plan.isEmpty else { return url }
                    let entry = await AppModel.shared.applyChange(plan)
                    // A rename that changed nothing (the file went away, say) leaves nothing for ⌘Z (audit 5, B5-m5).
                    if !entry.steps.isEmpty { window?.registerUndo(entry) }
                    if let failure = entry.failures.first {
                        message = failure
                        return nil
                    }
                    return plan.moves.first?.destination ?? url
                }
                // Save as Copy with no edits: a copy that no longer identifies the item (D-105), at a free name (D-107).
                let wanted = folder.appendingPathComponent(FileNaming.fileName(stem: "\(cleanName) copy", ext: fileExtension))
                let placed = try await FileOps.copy(url, as: wanted)
                if let problem = placed.metadataProblem { message = "Saved, but the metadata file could not be written: \(problem)" }
                return placed.url
            }
            let edited = try await writeEdited()
            let stem = asCopy ? (hasNameChange ? cleanName : "\(cleanName) edited") : cleanName
            let wanted = folder.appendingPathComponent(FileNaming.fileName(stem: stem, ext: format.fileExtension))
            // The edit's metadata: the original's, with the new size and checksum (R-3202); a copy drops the identity keys.
            let metadata = try await Task.detached(priority: .userInitiated) { () throws -> Data? in
                var values: [String: FileOps.MetadataValue] = ["edited": .bool(true), "sha256": .string(try FileHasher.sha256(of: edited))]
                if let size = ImageConversion.analyze(edited) {
                    values["width"] = .int(size.width)
                    values["height"] = .int(size.height)
                }
                return try FileOps.metadata(of: url, applying: .init(values: values, isCopy: asCopy))
            }.value
            if asCopy {
                let placed = try await FileOps.place(edited, as: wanted, with: metadata.map(FileOps.Companion.data) ?? .none)
                if let problem = placed.metadataProblem { message = "Saved, but the metadata file could not be written: \(problem)" }
                return placed.url
            }
            // The original and its metadata file go to the Trash as one change ⌘Z takes back (D-34, D-107).
            let replaced = try await AppModel.shared.replaceFile(url, identity: openedIdentity, with: edited, named: wanted,
                                                                 metadata: metadata, title: "Edit “\(url.lastPathComponent)”")
            window?.registerUndo(replaced.entry)
            return replaced.url
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    /// Extracted item: remember the name, and save the edited image if there are edits.
    func saveItem(to folder: URL?) async -> Bool {
        guard case let .item(id) = request.subject, !isSaving, let window, let item = window.itemsByID[id] else { return false }
        isSaving = true
        defer { isSaving = false }
        // A name typed with edits names the edited copy only, never the original (audit 8, C8-M1).
        if !hasImageEdits {
            if hasNameChange { window.customNames[id] = cleanName } else if name.isEmpty { window.customNames[id] = nil }
        }
        guard let destination = folder ?? window.saveFolder else {
            message = "Choose a library folder first."
            return false
        }
        var toSave = item
        if hasImageEdits {
            do {
                let edited = try await writeEdited()
                var variant = MediaVariant(id: edited.absoluteString, url: edited, format: format, origin: item.best?.origin ?? .img)
                variant.pixelSize = outputSize
                // A copy of its own (audit 7, C7-M2), named after the original, not after the temporary file.
                toSave = item.madeCopy(variant)
                window.customNames[toSave.id] = cleanName
            } catch {
                message = error.localizedDescription
                return false
            }
        }
        app.save([toSave], from: window, to: destination)
        return true
    }
}
