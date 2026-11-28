import AppKit
import MediaPullCore
import SwiftUI
import UniformTypeIdentifiers

/// The Media pane (R-4601): a folder's photos, videos and audio; files with edits are marked.
struct EditMediaPane: View {
    @Bindable var model: WindowModel
    @Bindable var edit: EditModel

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Media", pane: .editMedia, model: model) {
                Button("Choose Folder…", action: chooseFolder).controlSize(.small)
            }
            Divider()
            if let folder = edit.folder {
                HStack(spacing: 6) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(folder.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if folder.deletingLastPathComponent().path != folder.path {
                        QuietIconButton(title: "Enclosing Folder", symbol: "chevron.up", help: "Show the enclosing folder") {
                            edit.show(folder: folder.deletingLastPathComponent())
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                Divider()
                ZStack {
                    MediaGrid(sections: edit.gridSections, selection: edit.selection, cellSize: edit.cellSize, revision: edit.revision,
                              owner: edit)
                    if edit.loadingFolder {
                        ProgressView().controlSize(.small)
                    } else if edit.entries.isEmpty {
                        Text("No photos, videos or audio here.").font(.callout).foregroundStyle(.secondary).allowsHitTesting(false)
                    }
                }
            } else {
                Text("Choose a folder, or drag photos here.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if edit.selectedFiles.count >= 2 || (edit.copiedSettings != nil && !edit.selectedFiles.isEmpty) {
                Divider()
                EditSelectionBar(edit: edit, preferences: AppModel.shared.preferences)
            }
        }
        .background(PaneSurface.list.color)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Show"
        panel.directoryURL = edit.folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        edit.show(folder: url)
    }
}

/// Under the Media pane while files are selected (R-4611, D-132, D-134): the open file's edits (or settings copied
/// earlier) applied to the other selected files, choosing what goes, and Export Selected.
struct EditSelectionBar: View {
    @Bindable var edit: EditModel
    @Bindable var preferences: Preferences

    private var groups: Set<SettingGroup> { Set(SettingGroup.allCases.filter { preferences.pasteGroups.contains($0.rawValue) }) }

    var body: some View {
        let targets = edit.batchTargets
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(edit.selectedFiles.count) selected").font(.callout.weight(.semibold))
                Spacer()
                Button("Export Selected") { edit.exportSelected() }
                    .controlSize(.small)
                    .disabled(edit.exporting)
                    .help("Export every selected file with its own edits and the open file's export settings, as one job")
            }
            if let source = edit.batchSource {
                HStack(spacing: 4) {
                    Text("Edits of “\(URL(fileURLWithPath: source.source.path).lastPathComponent)”")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if edit.copiedSettings != nil {
                        Text("copied").font(.caption).foregroundStyle(.tertiary)
                        Spacer(minLength: 4)
                        Button("Use Open File") { edit.copiedSettings = nil }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Forget the copied settings and apply the open file's edits instead")
                    }
                }
                FlowLayout(spacing: 4) {
                    ForEach(SettingGroup.allCases) { group in
                        ValueChip(title: group.label, selected: groups.contains(group)) { toggle(group) }
                            .help(help(group, in: source))
                    }
                }
                HStack {
                    Text("Crops stay each file's own.")
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1).layoutPriority(-1)
                    Spacer(minLength: 4)
                    Button(targets.count == 1 ? "Apply to 1 File" : "Apply to \(targets.count) Files") {
                        edit.applyToSelection(groups)
                    }
                    .controlSize(.small)
                    .disabled(groups.isEmpty || targets.isEmpty)
                    .help("Give the other selected files these edits (⌘Z takes them back)")
                }
            } else {
                Text("Edit the open file, then apply its frame, look, adjustments or text to the other selected files here.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
    }

    private func toggle(_ group: SettingGroup) {
        if preferences.pasteGroups.contains(group.rawValue) {
            preferences.pasteGroups.remove(group.rawValue)
        } else {
            preferences.pasteGroups.insert(group.rawValue)
        }
    }

    /// Says when applying a part the source does not have takes it away from the others.
    private func help(_ group: SettingGroup, in source: EditRecipe) -> String {
        let empty = switch group {
        case .look: source.look == nil
        case .adjustments: source.adjust == Adjustments()
        case .frame: source.frame == nil
        case .layers: source.layers.isEmpty
        }
        return empty ? "\(group.label): the source has none, so applying it removes the others' \(group.label.lowercased())"
            : "Apply the source's \(group.label.lowercased())"
    }
}

/// The Canvas pane (R-4601): the file as edited, Before/After, the crop while cropping and the layers on top. The file's
/// name is in the title bar, so the header shows the size written, the zoom and Before (D-132).
struct EditCanvasPane: View {
    @Bindable var model: WindowModel
    @Bindable var edit: EditModel
    @FocusState private var focused: Bool
    /// How far a zoomed canvas is scrolled, so the rulers follow it.
    @State private var scroll: CGPoint = .zero
    private var preferences: Preferences { AppModel.shared.preferences }

    /// The edited picture is on the canvas (not a video's player). Read from `preview`, which views follow; the session
    /// itself is not observed.
    private var showsPicture: Bool {
        edit.preview != nil && edit.loadError == nil && !(edit.kind == .video && (edit.tab == .trim || edit.playingResult))
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Canvas", pane: .editCanvas, model: model) {
                if showsPicture, let pixels = edit.outputPixels, pixels.width > 0, edit.kind == .image {
                    Text(verbatim: "\(Int(pixels.width)) × \(Int(pixels.height))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("The size Export writes, in pixels")
                }
                if showsPicture {
                    HStack(spacing: 2) {
                        ForEach([1.0, 2.0, 4.0], id: \.self) { zoom in
                            ValueChip(title: zoom == 1 ? "Fit" : "\(Int(zoom))×", selected: edit.zoom == zoom) { edit.zoom = zoom }
                        }
                    }
                    .help("Zoom the canvas")
                    HoldChip(title: "Before/After", held: $edit.showingBefore)
                        .help("Hold to see the photo as it was, without the edits; release to see them again (or hold \\)")
                }
                if edit.kind == .video {
                    Button(edit.playingResult ? "Show Original" : "Play Result") {
                        if edit.playingResult { edit.loadPlayer() } else { edit.playResult() }
                    }
                    .controlSize(.small)
                    .help("Play the video as it will be exported, or go back to the original to cut it")
                }
            }
            Divider()
            VStack(spacing: 0) {
                if showsRulers {
                    HStack(spacing: 0) {
                        PaneSurface.tools.color.frame(width: CanvasRuler.thickness, height: CanvasRuler.thickness)
                        ruler(.horizontal)
                    }
                }
                HStack(spacing: 0) {
                    if showsRulers { ruler(.vertical) }
                    GeometryReader { proxy in
                        ZStack {
                            PaneSurface.stage.color
                            canvas(in: proxy.size)
                            if edit.showingBefore, showsPicture {
                                Text("Before")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(.black.opacity(0.55), in: Capsule())
                                    .padding(8)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                    .allowsHitTesting(false)
                            }
                        }
                        .onAppear { edit.canvasSize = proxy.size }
                        .onChange(of: proxy.size) { _, size in edit.canvasSize = size }
                    }
                }
            }
            .focusable(model.section == .edit)
            .focusEffectDisabled()
            .focused($focused)
            // A key on the canvas, never a window shortcut that would fire while typing in a text layer (D-132).
            // Held to compare, like the button (D-134); a repeat keeps it shown.
            .onKeyPress("\\", phases: [.down, .repeat, .up]) { press in
                guard showsPicture || press.phase == .up else { return .ignored }
                edit.showingBefore = press.phase != .up
                return .handled
            }
            // A key let go elsewhere never leaves the original showing.
            .onChange(of: focused) { _, now in if !now { edit.showingBefore = false } }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                Task {
                    var urls: [URL] = []
                    for provider in providers {
                        let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier)
                        if let url = item as? URL {
                            urls.append(url)
                        } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                            urls.append(url)
                        }
                    }
                    await MainActor.run { model.openInEdit(urls) }
                }
                return true
            }
            if showsPicture {
                Divider()
                EditGuideBar(edit: edit, preferences: preferences)
            }
            if edit.kind == .video, showsPicture {
                Divider()
                StillStrip(edit: edit)
            }
            if let message = edit.message
                ?? edit.missingFonts.first
                ?? edit.missingPictures.first.map({
                    "The picture “\($0)” is no longer there or cannot be drawn. Export waits until it is back or the layer is "
                        + "removed."
                })
            {
                Divider()
                Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func canvas(in size: CGSize) -> some View {
        if edit.current == nil {
            Text("Choose a photo in Media, or drag one here.").font(.callout).foregroundStyle(.secondary)
        } else if let error = edit.loadError {
            Text(error).font(.callout).foregroundStyle(.secondary)
        } else if edit.kind == .audio {
            EditAudioCanvas(edit: edit)
        } else if edit.kind == .video, edit.tab == .trim || edit.playingResult {
            VStack(spacing: 10) {
                EditPlayerView(player: edit.player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(edit.playingResult ? "The edited video" : "The original video")
                if !edit.playingResult {
                    EditTimelineView(edit: edit).padding(.horizontal, 12)
                    HStack {
                        Text(EditTimelineView.clock(edit.player.time)).font(.caption.monospacedDigit())
                        Spacer()
                        Text("Result \(EditTimelineView.clock(edit.timeline.resultDuration(of: edit.mediaDuration)))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                }
            }
            .padding(.vertical, 12)
        } else if edit.tab == .crop, !edit.showingBefore, let image = edit.cropImage {
            zoomed(image: image, size: size) { frame in
                GuideGrid(grid: preferences.editGrid, frame: frame)
                EditCropOverlay(model: edit, frame: frame)
            }
        } else if let image = edit.preview {
            zoomed(image: image, size: size) { frame in
                if !edit.showingBefore {
                    GuideGrid(grid: preferences.editGrid, frame: frame)
                    if [.text, .adjust, .frame].contains(edit.tab),
                       !(edit.recipe?.layers.isEmpty ?? true) || (edit.tab == .frame && edit.framePlacement?.canMove == true)
                    {
                        EditLayerOverlay(model: edit, frame: frame, editing: edit.tab == .text)
                    }
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    /// Where the picture is on the stage of `size` at the zoom chosen, and the size of what scrolls when zoomed.
    private func stage(image: CGImage, size: CGSize) -> (frame: CGRect, content: CGSize) {
        let bounds = CGSize(width: max(size.width - 32, 10), height: max(size.height - 32, 10))
        let fitted = fittedRect(CGSize(width: image.width, height: image.height), in: bounds)
        let picture = CGSize(width: fitted.width * edit.zoom, height: fitted.height * edit.zoom)
        let content = CGSize(width: max(size.width, picture.width + 32), height: max(size.height, picture.height + 32))
        return (CGRect(x: (content.width - picture.width) / 2, y: (content.height - picture.height) / 2,
                       width: picture.width, height: picture.height), content)
    }

    /// The picture at the zoom chosen, with its overlay: fitted when 1, in a scroll view centred when larger.
    @ViewBuilder
    private func zoomed(image: CGImage, size: CGSize, @ViewBuilder overlay: (CGRect) -> some View) -> some View {
        let (frame, content) = stage(image: image, size: size)
        let stage = ZStack(alignment: .topLeading) {
            Image(decorative: image, scale: 1).resizable().interpolation(.high)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .shadow(color: .black.opacity(0.25), radius: 6)
                .accessibilityLabel(edit.showingBefore ? "The photo as it was" : "The edited photo")
            overlay(frame)
        }
        .frame(width: content.width, height: content.height)
        if edit.zoom > 1 {
            ScrollView([.horizontal, .vertical]) { stage }
                .defaultScrollAnchor(.center)
                .onScrollGeometryChange(for: CGPoint.self, of: { $0.contentOffset }, action: { _, offset in scroll = offset })
        } else {
            stage
        }
    }

    // MARK: Rulers (R-4613)

    /// The picture the stage shows: the uncropped one while cropping.
    private var stageImage: CGImage? {
        edit.tab == .crop && !edit.showingBefore ? edit.cropImage : edit.preview
    }

    private var showsRulers: Bool { showsPicture && preferences.editRulers && stageImage != nil }

    /// The canvas's size in the pixels the rulers count: what Export writes, the picture's own while cropping, the
    /// original's for Before.
    private var rulerPixels: CGSize? {
        if edit.showingBefore { return edit.originalPixels }
        if edit.tab == .crop, let crop = edit.cropPixels {
            let unit = edit.recipe?.geometry.crop ?? .whole
            return CGSize(width: crop.width / max(unit.width, 0.0001), height: crop.height / max(unit.height, 0.0001))
        }
        return edit.outputPixels
    }

    /// The selected layer's, the photo's or the crop's span, in units of the canvas.
    private var highlighted: CGRect? {
        guard !edit.showingBefore else { return nil }
        switch edit.tab {
        case .crop:
            let crop = edit.recipe?.geometry.crop ?? .whole
            return CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)
        case .frame:
            return edit.framePlacement?.photo
        case .text:
            guard let layer = edit.recipe?.layers.first(where: { $0.id == edit.selectedLayer && !$0.hidden }) else { return nil }
            return turnedBounds(layer)
        default:
            return nil
        }
    }

    /// A turned layer's upright box in units: turned in points, as it is drawn, since the canvas is rarely square.
    private func turnedBounds(_ layer: Layer) -> CGRect {
        guard layer.rotation != 0, let image = stageImage else {
            return CGRect(x: layer.x - layer.width / 2, y: layer.y - layer.height / 2, width: layer.width, height: layer.height)
        }
        let size = CGSize(width: image.width, height: image.height)
        let box = CanvasSnap.bounds(centre: CGPoint(x: layer.x * size.width, y: layer.y * size.height),
                                    size: CGSize(width: layer.width * size.width, height: layer.height * size.height),
                                    degrees: layer.rotation)
        return CGRect(x: box.minX / size.width, y: box.minY / size.height, width: box.width / size.width, height: box.height / size.height)
    }

    @ViewBuilder
    private func ruler(_ axis: CanvasRuler.Axis) -> some View {
        if let image = stageImage {
            let frame = stage(image: image, size: edit.canvasSize).frame
            let offset = edit.zoom > 1 ? scroll : .zero
            let horizontal = axis == .horizontal
            let start = horizontal ? frame.minX - offset.x : frame.minY - offset.y
            let length = horizontal ? frame.width : frame.height
            let pixels = rulerPixels ?? CGSize(width: image.width, height: image.height)
            let span = highlighted.map { unit -> ClosedRange<CGFloat> in
                let low = start + (horizontal ? unit.minX : unit.minY) * length
                return low ... max(low, start + (horizontal ? unit.maxX : unit.maxY) * length)
            }
            CanvasRuler(axis: axis, start: start, length: length, pixels: horizontal ? pixels.width : pixels.height, highlight: span)
        }
    }
}

/// Under a video's still on the Adjust, Crop, Frame and Text tabs: which frame is shown, and that Play Result shows
/// the edited video (D-132).
private struct StillStrip: View {
    @Bindable var edit: EditModel

    var body: some View {
        HStack(spacing: 8) {
            Text("Still from \(EditTimelineView.clock(edit.stillTime))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .fixedSize()
            Slider(value: Binding(get: { edit.stillTime }, set: { edit.showStill(at: $0) }), in: 0 ... max(edit.mediaDuration, 0.1))
                .controlSize(.mini)
                .accessibilityLabel("Frame shown")
                .help("Choose which frame of the video to judge the look and the frame on; Export uses the whole video")
            Text("Play Result shows the edited video.").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .layoutPriority(-1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}
