import MediaPullCore
import MediaPullLibrary
import MediaPullMedia
import SwiftUI

/// The Preview pane (SPEC section 10a): the selected extracted item or library file, its details,
/// and the editor in place.
struct PreviewPane: View {
    @Bindable var model: WindowModel
    private var app: AppModel { .shared }

    var body: some View {
        VStack(spacing: 0) {
            PaneTitleBar(title: title, pane: .preview, model: model) {
                if model.editorRequest == nil, let subject = model.previewSubject, canEdit(subject) {
                    Button {
                        switch subject {
                        case let .item(id): model.edit(id)
                        case let .file(url): model.openEditor(EditorRequest(subject: .file(url)))
                        }
                    } label: {
                        Image(systemName: "crop.rotate")
                    }
                    .buttonStyle(.borderless)
                    .help("Crop, rotate, flip or rename (⌘E)")
                }
            }
            Divider()
            content
        }
    }

    private var title: String {
        if model.editorRequest != nil { return "Edit" }
        switch model.previewSubject {
        case let .file(url): return url.lastPathComponent
        case let .item(id): return model.itemsByID[id].flatMap { $0.best.flatMap { URLNormalizer.baseName(of: $0.url) } } ?? "Preview"
        case nil: return "Preview"
        }
    }

    private func canEdit(_ subject: PreviewSubject) -> Bool {
        switch subject {
        case let .item(id): model.itemsByID[id] != nil
        case let .file(url): FileManager.default.fileExists(atPath: url.path)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let request = model.editorRequest {
            if model.isVideo(request.subject) {
                VideoEditorView(request: request, window: model) { model.editorRequest = nil }
                    .id(request.id)
            } else {
                EditorView(request: request, window: model) { model.editorRequest = nil }
                    .id(request.id)
            }
        } else {
            switch model.previewSubject {
            case let .item(id):
                if let item = model.itemsByID[id] {
                    AdaptiveSplit {
                        ItemMediaPreview(model: model, item: item).id(item.id)
                    } details: {
                        ItemDetails(model: model, item: item)
                    }
                } else {
                    PreviewPlaceholder(text: "This item is no longer in the list.")
                }
            case let .file(url):
                AdaptiveSplit {
                    FileMediaPreview(file: url).id(url)
                } details: {
                    FileDetails(model: model, file: url).id(url)
                }
            case nil:
                PreviewPlaceholder(text: model.selection.count > 1 ? "\(model.selection.count) items selected"
                    : "Select an item or a saved file to preview it.")
            }
        }
    }
}

/// A pane's title row with its arrange menu.
struct PaneTitleBar<Accessory: View>: View {
    var title: String
    var pane: PaneID
    var model: WindowModel
    @ViewBuilder var accessory: () -> Accessory
    private var app: AppModel { .shared }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            accessory()
            PaneMenu(pane: pane, window: model)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(app.preferences.theme.headerBackground)
    }
}

/// Media beside its details when the pane is wide, above them when it is tall.
struct AdaptiveSplit<Media: View, Details: View>: View {
    @ViewBuilder var media: () -> Media
    @ViewBuilder var details: () -> Details

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width > proxy.size.height * 1.25, proxy.size.width > 520 {
                HStack(spacing: 0) {
                    media().frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    details().frame(width: min(340, proxy.size.width * 0.42))
                }
            } else {
                VStack(spacing: 0) {
                    media().frame(maxWidth: .infinity).frame(height: max(140, proxy.size.height * 0.56))
                    Divider()
                    details()
                }
            }
        }
    }
}

struct PreviewPlaceholder: View {
    var text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A checkerboard-free dark stage that keeps media readable in both appearances.
struct MediaStage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.82))
            content().padding(10)
        }
        .clipped()
    }
}

/// An extracted item: its grid thumbnail at once, then the full image or the video on request.
struct ItemMediaPreview: View {
    @Bindable var model: WindowModel
    var item: MediaItem
    @State private var image: CGImage?
    @State private var file: URL?
    @State private var loadingVideo = false
    @State private var failed = false

    private var isVideo: Bool { item.kind == .video || item.kind == .stream || item.kind == .audio }

    var body: some View {
        MediaStage {
            if let file, isVideo {
                PlayerView(file: file)
            } else if let file, item.kind == .animatedImage {
                AnimatedImageView(file: file)
            } else if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .overlay { if isVideo { playButton } }
            } else if failed {
                Label("No preview", systemImage: "eye.slash").foregroundStyle(.secondary)
            } else if isVideo {
                playButton
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .onTapGesture(count: 2) { model.quickLook([item]) }
        .task(id: item.id) { await load() }
    }

    @ViewBuilder
    private var playButton: some View {
        if item.best?.requiresEngine ?? false || item.kind == .stream {
            Text("Streams can be played once saved.")
                .font(.callout)
                .padding(8)
                .background(.regularMaterial, in: Capsule())
        } else if loadingVideo {
            ProgressView().controlSize(.regular)
        } else {
            Button { Task { await playVideo() } } label: {
                Image(systemName: "play.circle.fill").font(.system(size: 48)).symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .help("Download and play")
        }
    }

    private func load() async {
        image = await model.gridThumbnail(item.id, maxPixel: 900)
        guard !isVideo else { return }
        guard let local = await model.previewFile(for: item) else {
            if image == nil { failed = true }
            return
        }
        if item.kind == .animatedImage {
            file = local
            return
        }
        if let large = await Task.detached(priority: .userInitiated, operation: { Thumbnailer.image(at: local, maxPixel: 2400) }).value {
            image = large
        }
    }

    private func playVideo() async {
        loadingVideo = true
        defer { loadingVideo = false }
        file = await model.previewFile(for: item)
        if file == nil { failed = true }
    }
}

/// A saved file in a library folder.
struct FileMediaPreview: View {
    var file: URL
    @State private var image: CGImage?
    @State private var kind: MediaKind?
    @State private var loaded = false

    var body: some View {
        MediaStage {
            switch kind {
            case .video, .audio:
                PlayerView(file: file)
            case .animatedImage:
                AnimatedImageView(file: file)
            default:
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else if loaded {
                    Label("No preview", systemImage: "eye.slash").foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .task(id: file) {
            let url = file
            let result = await Task.detached(priority: .userInitiated) { () -> (MediaKind?, CGImage?) in
                let format = Sniffer.sniff(MediaConverter.head(of: url)).format ?? MediaFormat.fromExtension(url.pathExtension)
                switch format?.kind {
                case .video, .audio: return (format?.kind, nil)
                default:
                    // lint:allow main-io inside a detached task
                    if format == .gif, ImageProbe.frameCount(from: (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data()) > 1 {
                        return (.animatedImage, nil)
                    }
                    return (.image, Thumbnailer.image(at: url, maxPixel: 2400))
                }
            }.value
            kind = result.0
            image = result.1
            loaded = true
        }
    }
}

/// Facts about a saved file, with its metadata file when there is one.
struct FileDetails: View {
    @Bindable var model: WindowModel
    var file: URL
    @State private var rows: [(String, String)] = []
    @State private var caption: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                InfoGrid(rows: rows)
                if let group = model.library.duplicateGroup(for: file), let report = model.library.duplicates {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Copies and look-alikes")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(group.members.filter { $0 != file.standardizedFileURL }, id: \.self) { other in
                            let identical = report.areIdentical(file, other)
                            Button {
                                model.library.reveal(other)
                            } label: {
                                Label(String(other.path.dropFirst(report.root.standardizedFileURL.path.count))
                                    .trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                                    systemImage: identical ? "doc.on.doc.fill" : "square.on.square")
                            }
                            .foregroundStyle(identical ? Color.orange : Color.purple)
                            .buttonStyle(.link)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help("Show this copy in the Library")
                        }
                    }
                }
                if let caption {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Caption").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(caption).font(.callout).textSelection(.enabled)
                    }
                }
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    Button("Open") { NSWorkspace.shared.open(file) }
                    Button("Quick Look") { QuickLook.shared.show([file]) }
                }
                .controlSize(.small)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: file) {
            let url = file
            let result = await Task.detached(priority: .utility) { FileFacts.read(url) }.value
            rows = result.rows
            caption = result.caption
        }
    }
}

/// Reads a file's size, dimensions and sidecar fields off the main actor.
nonisolated enum FileFacts {
    static func read(_ url: URL) -> (rows: [(String, String)], caption: String?) {
        var rows: [(String, String)] = []
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let format = Sniffer.sniff(MediaConverter.head(of: url)).format ?? MediaFormat.fromExtension(url.pathExtension)
        if let format { rows.append(("Format", format.label)) }
        if let analysis = ImageConversion.analyze(url) { rows.append(("Dimensions", "\(analysis.width) × \(analysis.height) px")) }
        if let size = values?.fileSize {
            rows.append(("File size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))
        }
        if let date = values?.contentModificationDate { rows.append(("Date", date.formatted(date: .abbreviated, time: .shortened))) }
        rows.append(("Folder", url.deletingLastPathComponent().lastPathComponent))
        var caption: String?
        let sidecar = Sidecar.sidecarURL(for: url)
        // lint:allow main-io one metadata file of a few kilobytes
        if let data = try? Data(contentsOf: sidecar), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let user = object["username"] as? String, !user.isEmpty { rows.append(("Account", user)) }
            if let kind = object["subcategory"] as? String { rows.append(("Section", kind.capitalized)) }
            if let link = (object["post_url"] ?? object["page_url"] ?? object["source_url"]) as? String { rows.append(("Source", link)) }
            if let edited = object["edited"] as? Bool, edited { rows.append(("Edited", "Yes")) }
            caption = (object["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            rows.append(("Metadata", sidecar.lastPathComponent))
        }
        return (rows, caption)
    }
}
