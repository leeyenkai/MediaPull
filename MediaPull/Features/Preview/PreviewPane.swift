import AppKit
import MediaPullAnalysis
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
                if model.canEditPreview {
                    Button {
                        model.editPreview()
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

/// Audio the system cannot play (Ogg, Opus) is decoded into a temporary copy when previewed; anything else plays as it is.
enum AudioPreview {
    static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MediaPull-audio-preview", isDirectory: true)

    static func playable(_ url: URL) async -> URL? {
        guard [.ogg, .opus].contains(MediaFormat.fromExtension(url.pathExtension)) else { return url }
        guard let ffmpeg = AppModel.shared.ffmpeg else { return nil }
        let folder = folder
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            // Keyed by the file's size and date too, so another file later at this path is not played as this one.
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let stamp = "\(values?.fileSize ?? 0)-\(Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0))"
            let output = folder.appendingPathComponent(ShortHash.of(url.path + "|" + stamp) + ".m4a")
            if let size = (try? FileManager.default.attributesOfItem(atPath: output.path))?[.size] as? NSNumber, size.intValue > 0 {
                return output
            }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            Self.prune(folder)
            // Written under another name and renamed when whole, so a copy still being made is never played.
            let partial = folder.appendingPathComponent(UUID().uuidString + ".m4a")
            guard (try? await ffmpeg.playableCopy(of: url, to: partial)) != nil else { return nil }
            // lint:allow app-data silent-write a preview copy in the temporary folder; made again when missing
            try? FileManager.default.moveItem(at: partial, to: output)
            try? FileManager.default.removeItem(at: partial)
            return FileManager.default.fileExists(atPath: output.path) ? output : nil
        }.value
    }

    /// Copies not used for a week go.
    nonisolated static func prune(_ folder: URL) {
        // lint:allow main-io called from a detached task
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentAccessDateKey])) ?? []
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        for file in files where ((try? file.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate ?? .distantPast) < cutoff {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// A saved file in a library folder.
struct FileMediaPreview: View {
    var file: URL
    @State private var image: CGImage?
    @State private var kind: MediaKind?
    @State private var loaded = false
    @State private var playable: URL?

    var body: some View {
        MediaStage {
            switch kind {
            case .video:
                PlayerView(file: file)
            case .audio:
                // Ogg and Opus play from a copy decoded for the preview (R-4205).
                if let playable {
                    PlayerView(file: playable)
                } else {
                    ProgressView().controlSize(.small)
                }
            case .animatedImage:
                AnimatedImageView(file: file)
            default:
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .allowedDynamicRange(.high)
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
                let format = Sniffer.resolve(Sniffer.sniff(MediaConverter.head(of: url)).format, fileExtension: url.pathExtension)
                switch format?.kind {
                case .video, .audio: return (format?.kind, nil)
                default:
                    // lint:allow main-io inside a detached task
                    if format == .gif, ImageProbe.frameCount(from: (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data()) > 1 {
                        return (.animatedImage, nil)
                    }
                    // HEIF image sequences play; HEIC is shown in high dynamic range where it has it (R-4204).
                    if format == .heic, ImageConversion.isSequence(url) { return (.animatedImage, nil) }
                    return (.image, Thumbnailer.image(at: url, maxPixel: 2400, hdr: format == .heic))
                }
            }.value
            kind = result.0
            image = result.1
            loaded = true
            if kind == .audio { playable = await AudioPreview.playable(url) }
        }
    }
}

/// Facts about a saved file, with its metadata file when there is one.
struct FileDetails: View {
    @Bindable var model: WindowModel
    var file: URL
    /// Where its copies come from and how one is shown: the Library's unless an Organise pane passes its own (D-114).
    var duplicates: DuplicateScan?
    var reveal: ((URL) -> Void)?
    @State private var rows: [(String, String)] = []
    @State private var caption: String?
    /// What the file itself records (D-110, R-1009b).
    @State private var recorded: RecordedDetails?
    @State private var mapExpanded = false
    private var preferences: Preferences { AppModel.shared.preferences }

    var body: some View {
        ZStack {
            details
            if mapExpanded, let recorded, let latitude = recorded.details.latitude, let longitude = recorded.details.longitude {
                // Expanded: the map fills the pane until Collapse.
                LocationMap(latitude: latitude, longitude: longitude, title: file.lastPathComponent, span: 0.2)
                    .overlay(alignment: .topTrailing) {
                        Button("Collapse") { mapExpanded = false }
                            .controlSize(.small)
                            .padding(8)
                    }
            }
        }
        .onChange(of: file) { mapExpanded = false }
        .onChange(of: preferences.showMaps) { if !preferences.showMaps { mapExpanded = false } }
    }

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                InfoGrid(rows: rows)
                if let recorded { recordedSections(recorded) }
                MetadataEditSection(model: model, file: file)
                if let scan = duplicates ?? model.library.duplicateScan as DuplicateScan?, let group = scan.group(for: file),
                   let report = scan.report
                {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Copies and look-alikes")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(group.members.filter { $0 != file.standardizedFileURL }, id: \.self) { other in
                            let identical = report.areIdentical(file, other)
                            Button {
                                if let reveal { reveal(other) } else { model.library.reveal(other) }
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
                            .help("Show this copy")
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
                    Button("Open in Edit/Frame") { model.openInEdit([file]) }
                }
                .controlSize(.small)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: file) {
            let url = file
            // Never another file's details: cleared first, and each result kept only while this file is still shown (R1-m11).
            recorded = nil
            let result = await Task.detached(priority: .utility) { FileFacts.read(url) }.value
            guard !Task.isCancelled, url == file else { return }
            rows = result.rows
            caption = result.caption
            let read = await RecordedDetails.read(url)
            guard !Task.isCancelled, url == file else { return }
            recorded = read
        }
    }

    @ViewBuilder
    private func recordedSections(_ recorded: RecordedDetails) -> some View {
        ForEach(recorded.sections, id: \.title) { section in
            VStack(alignment: .leading, spacing: 4) {
                Text(section.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                InfoGrid(rows: section.rows)
            }
        }
        if let latitude = recorded.details.latitude, let longitude = recorded.details.longitude {
            VStack(alignment: .leading, spacing: 6) {
                Text("Location").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                InfoGrid(rows: recorded.locationRows)
                HStack {
                    Button("Copy Coordinates") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(RecordedDetails.coordinates(latitude, longitude), forType: .string)
                    }
                    if preferences.showMaps {
                        Button("Expand Map") { mapExpanded = true }
                    } else {
                        Button("Show Map") { preferences.showMaps = true }
                            .help("Loads map images of this area from Apple's map servers. Settings can turn maps off again.")
                    }
                }
                .controlSize(.small)
                if preferences.showMaps, !mapExpanded {
                    LocationMap(latitude: latitude, longitude: longitude, title: file.lastPathComponent)
                        .frame(height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }
}

/// What a file records about how it was made, in rows for the details (D-110, R-1009b). Read off the main actor.
struct RecordedDetails: Sendable {
    struct Section: Sendable {
        var title: String
        var rows: [(String, String)]
    }

    var details: MediaDetails
    var sections: [Section]
    var locationRows: [(String, String)]

    static func read(_ url: URL) async -> RecordedDetails {
        let details = await MediaDetailsReader.details(for: url)
        let place = await Task.detached(priority: .utility) { () -> String? in
            guard let lat = details.latitude, let lon = details.longitude else { return nil }
            guard let places = AnalysisService.places else { return "Place data is not in this build of MediaPull" }
            return places.place(latitude: lat, longitude: lon)?.display
        }.value
        return RecordedDetails(details: details, place: place)
    }

    init(details: MediaDetails, place: String?) {
        self.details = details
        var camera: [(String, String)] = []
        if let name = details.camera { camera.append(("Model", name)) }
        if let lens = details.lens { camera.append(("Lens", lens)) }
        if let focal = details.focalLength {
            let mm = focal.formatted(.number.precision(.fractionLength(0 ... 1)))
            camera.append(("Focal length", details.focalLength35.map { "\(mm) mm (\($0) mm equivalent)" } ?? "\(mm) mm"))
        }
        if let aperture = details.aperture {
            camera.append(("Aperture", "ƒ/" + aperture.formatted(.number.precision(.fractionLength(0 ... 1)))))
        }
        if let exposure = details.exposure { camera.append(("Shutter", Self.shutter(exposure))) }
        if let iso = details.iso { camera.append(("ISO", "\(iso)")) }
        if let flash = details.flashFired { camera.append(("Flash", flash ? "Fired" : "Off")) }
        var taken: [(String, String)] = []
        if let date = details.taken {
            // In the time zone the file records, so a photo taken at 18:30 in Tokyo says 18:30 wherever the Mac is (R1-m10).
            var style = Date.FormatStyle(date: .abbreviated, time: .standard)
            if let zone = details.takenOffset.flatMap(Self.timeZone) { style.timeZone = zone }
            taken.append(("Taken", date.formatted(style) + (details.takenOffset.map { " (UTC\($0))" } ?? "")))
        }
        if let software = details.software { taken.append(("Software", software)) }
        if let profile = details.colorProfile { taken.append(("Colour", profile)) }
        var video: [(String, String)] = []
        if let audio = details.audio {
            // An audio file's own section (R-4205).
            let fields: [(String, String?)] = [
                ("Title", audio.title), ("Artist", audio.artist), ("Album", audio.album), ("Album artist", audio.albumArtist),
                ("Year", audio.year.map(String.init)), ("Genre", audio.genre), ("Track", audio.track.map(String.init)),
            ]
            video += fields.compactMap { label, value in value.map { (label, $0) } }
            if let rate = audio.bitrate { video.append(("Bit rate", "\(rate / 1000) kbps")) }
        }
        if let duration = details.duration {
            video.append(("Length", Duration.seconds(duration).formatted(.time(pattern: .hourMinuteSecond))))
        }
        if let codec = details.codec { video.append(("Codec", codec)) }
        if let rate = details.frameRate {
            video.append(("Frame rate", rate.formatted(.number.precision(.fractionLength(0 ... 2))) + " fps"))
        }
        sections = [
            Section(title: "Camera", rows: camera), Section(title: "Taken", rows: taken),
            Section(title: details.audio == nil ? "Video" : "Audio", rows: video),
        ].filter { !$0.rows.isEmpty }
        var location: [(String, String)] = []
        if let lat = details.latitude, let lon = details.longitude {
            location.append(("Coordinates", Self.coordinates(lat, lon)))
            if let altitude = details.altitude {
                location.append(("Altitude", altitude.formatted(.number.precision(.fractionLength(0))) + " m"))
            }
            location.append(("Near", place ?? "No place within 50 km in the bundled place data"))
        }
        locationRows = location
    }

    /// "+09:00" or "-05:30" as a time zone.
    static func timeZone(_ offset: String) -> TimeZone? {
        let parts = offset.dropFirst().split(separator: ":").compactMap { Int($0) }
        guard let sign = offset.first, "+-".contains(sign), parts.count == 2, parts[0] <= 14, parts[1] < 60 else { return nil }
        return TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (parts[0] * 3600 + parts[1] * 60))
    }

    static func coordinates(_ lat: Double, _ lon: Double) -> String {
        String(format: "%.5f, %.5f", lat, lon)
    }

    /// 1/120 s for fast exposures, seconds for slow ones.
    static func shutter(_ seconds: Double) -> String {
        guard seconds < 1 else { return seconds.formatted(.number.precision(.fractionLength(0 ... 1))) + " s" }
        // Formatted, never converted to Int, so an odd value cannot trap (R1-m12).
        return "1/" + (1 / max(seconds, 1e-9)).formatted(.number.precision(.fractionLength(0)).grouping(.never)) + " s"
    }
}

/// Reads a file's size, dimensions and sidecar fields off the main actor.
nonisolated enum FileFacts {
    static func read(_ url: URL) -> (rows: [(String, String)], caption: String?) {
        var rows: [(String, String)] = []
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let format = Sniffer.resolve(Sniffer.sniff(MediaConverter.head(of: url)).format, fileExtension: url.pathExtension)
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
