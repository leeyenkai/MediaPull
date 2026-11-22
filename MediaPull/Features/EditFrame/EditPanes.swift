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
                EditSelectionBar(edit: edit)
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

/// Under the Media pane while files are selected (R-4611, D-132): Paste Settings, with what it carries, and Export
/// Selected, on screen instead of in a menu.
struct EditSelectionBar: View {
    @Bindable var edit: EditModel
    private var preferences: Preferences { AppModel.shared.preferences }

    private var groups: Set<SettingGroup> { Set(SettingGroup.allCases.filter { preferences.pasteGroups.contains($0.rawValue) }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(edit.selectedFiles.count) selected").font(.callout.weight(.semibold))
                Spacer()
                Button("Export Selected") { edit.exportSelected() }
                    .controlSize(.small)
                    .disabled(edit.exporting)
                    .help("Export every selected file with the open file's export settings, as one job")
            }
            if let copied = edit.copiedSettings {
                FlowLayout(spacing: 4) {
                    ForEach(SettingGroup.allCases) { group in
                        Toggle(group.label, isOn: Binding(
                            get: { preferences.pasteGroups.contains(group.rawValue) },
                            set: { on in
                                if on {
                                    preferences.pasteGroups.insert(group.rawValue)
                                } else {
                                    preferences.pasteGroups.remove(group.rawValue)
                                }
                            }
                        ))
                        .toggleStyle(.button)
                        .controlSize(.small)
                    }
                }
                HStack {
                    Text("From “\(URL(fileURLWithPath: copied.source.path).lastPathComponent)”")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button("Paste Settings") { edit.pasteSettings(groups, to: edit.selectedFiles) }
                        .controlSize(.small)
                        .disabled(groups.isEmpty)
                        .help("Put the copied settings on the selected files (⌘Z takes them back)")
                }
            } else {
                Text("Copy Settings, at the foot of the Inspector, copies a file's edits to paste onto these.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
    }
}

/// The Canvas pane (R-4601): the file as edited, Before/After, the crop while cropping and the layers on top. The file's
/// name is in the title bar, so the header shows the size written, the zoom and Before (D-132).
struct EditCanvasPane: View {
    @Bindable var model: WindowModel
    @Bindable var edit: EditModel
    @FocusState private var focused: Bool

    /// The edited picture is on the canvas (not a video's player). Read from `preview`, which views follow; the session
    /// itself is not observed.
    private var showsPicture: Bool {
        edit.preview != nil && edit.loadError == nil && !(edit.kind == .video && (edit.tab == .trim || edit.playingResult))
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Canvas", pane: .editCanvas, model: model) {
                if showsPicture, let pixels = edit.outputPixels, pixels.width > 0, edit.kind == .image {
                    Text("\(Int(pixels.width)) × \(Int(pixels.height))")
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
                    Toggle("Before", isOn: $edit.showingBefore)
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .help("Show the photo as it was, without the edits (\\)")
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
            GeometryReader { proxy in
                ZStack {
                    PaneSurface.stage.color
                    canvas(in: proxy.size)
                }
                .onAppear { edit.canvasSize = proxy.size }
                .onChange(of: proxy.size) { _, size in edit.canvasSize = size }
            }
            .focusable(model.section == .edit)
            .focusEffectDisabled()
            .focused($focused)
            // A key on the canvas, never a window shortcut that would fire while typing in a text layer (D-132).
            .onKeyPress("\\") {
                guard showsPicture else { return .ignored }
                edit.showingBefore.toggle()
                return .handled
            }
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
        let bounds = CGSize(width: max(size.width - 32, 10), height: max(size.height - 32, 10))
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
            zoomed(image: image, bounds: bounds, size: size) { frame in
                EditCropOverlay(model: edit, frame: frame)
            }
        } else if let image = edit.preview {
            zoomed(image: image, bounds: bounds, size: size) { frame in
                if !edit.showingBefore, [.text, .adjust, .frame].contains(edit.tab), !(edit.recipe?.layers.isEmpty ?? true) {
                    EditLayerOverlay(model: edit, frame: frame, editing: edit.tab == .text)
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    /// The picture at the zoom chosen, with its overlay: fitted when 1, in a scroll view centred when larger.
    @ViewBuilder
    private func zoomed(image: CGImage, bounds: CGSize, size: CGSize, @ViewBuilder overlay: (CGRect) -> some View) -> some View {
        let fitted = fittedRect(CGSize(width: image.width, height: image.height), in: bounds)
        let picture = CGSize(width: fitted.width * edit.zoom, height: fitted.height * edit.zoom)
        let content = CGSize(width: max(size.width, picture.width + 32), height: max(size.height, picture.height + 32))
        let frame = CGRect(x: (content.width - picture.width) / 2, y: (content.height - picture.height) / 2,
                           width: picture.width, height: picture.height)
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
        } else {
            stage
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
