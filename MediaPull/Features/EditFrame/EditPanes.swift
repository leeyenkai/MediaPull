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
                        Button {
                            edit.show(folder: folder.deletingLastPathComponent())
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Enclosing folder")
                        .help("Show the enclosing folder")
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
        }
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

/// The Canvas pane (R-4601): the file as edited, Before/After, the crop while cropping and the layers' boxes while
/// placing text and shapes.
struct EditCanvasPane: View {
    @Bindable var model: WindowModel
    @Bindable var edit: EditModel

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: edit.current?.lastPathComponent ?? "Canvas", pane: .editCanvas, model: model) {
                if edit.session != nil {
                    Toggle("Before", isOn: $edit.showingBefore)
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .help("Show the photo as it was, without the edits")
                }
            }
            Divider()
            GeometryReader { proxy in
                ZStack {
                    Color(nsColor: .underPageBackgroundColor)
                    canvas(in: proxy.size)
                }
                .onAppear { edit.canvasSize = proxy.size }
                .onChange(of: proxy.size) { _, size in edit.canvasSize = size }
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
            if let message = edit.message
                ?? edit.missingFonts.first.map({ "“\($0)” is not on this Mac; the system font is drawn instead." })
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
        } else if edit.kind != .image {
            VStack(spacing: 8) {
                Image(systemName: edit.kind == .audio ? "waveform" : "film")
                    .font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                Text("Editing videos and audio comes next.").font(.callout).foregroundStyle(.secondary)
            }
        } else if edit.tab == .crop, !edit.showingBefore, let image = edit.cropImage {
            let frame = fittedRect(CGSize(width: image.width, height: image.height), in: bounds).offsetBy(dx: 16, dy: 16)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                EditCropOverlay(model: edit, frame: frame)
            }
            .frame(width: size.width, height: size.height)
        } else if let image = edit.preview {
            let frame = fittedRect(CGSize(width: image.width, height: image.height), in: bounds).offsetBy(dx: 16, dy: 16)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .shadow(color: .black.opacity(0.25), radius: 6)
                    .accessibilityLabel("The edited photo")
                if edit.tab == .text, !edit.showingBefore {
                    EditLayerOverlay(model: edit, frame: frame)
                }
            }
            .frame(width: size.width, height: size.height)
        } else {
            ProgressView().controlSize(.small)
        }
    }
}
