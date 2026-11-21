import AppKit
import MediaPullCore
import MediaPullEdit
import SwiftUI

/// The Inspector pane (R-4601): the tools for the open file, in tabs.
struct EditInspectorPane: View {
    @Bindable var model: WindowModel
    @Bindable var edit: EditModel

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "", pane: .editInspector, model: model) {
                if !edit.tabs.isEmpty {
                    Picker("Tool", selection: $edit.tab) {
                        ForEach(edit.tabs) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Spacer(minLength: 4)
                if edit.recipe?.isEdited == true {
                    Button("Revert") { edit.revert() }
                        .controlSize(.small)
                        .help("Remove every edit of this file; the original was never changed (⌘Z brings them back)")
                }
            }
            Divider()
            if edit.recipe == nil {
                Text(edit.current == nil ? "Open a photo, video or audio file to edit it." : "Opening…")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch edit.tab {
                        case .trim: TrimTab(edit: edit)
                        case .sound: SoundTab(edit: edit)
                        case .adjust: AdjustTab(edit: edit)
                        case .crop: CropTab(edit: edit)
                        case .frame: FrameTab(edit: edit)
                        case .text: LayersTab(edit: edit)
                        case .export: ExportTab(edit: edit)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// Light, Colour, Effects and Looks (R-4603).
private struct AdjustTab: View {
    @Bindable var edit: EditModel

    var body: some View {
        ForEach(["Light", "Colour", "Effects"], id: \.self) { group in
            VStack(alignment: .leading, spacing: 8) {
                Text(group).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Adjustments.Key.allCases.filter { $0.group == group }, id: \.self) { key in
                    EditSlider(label: key.label, value: Binding(
                        get: { edit.recipe?.adjust[key] ?? 0 },
                        set: { value in edit.change { $0.adjust[key] = value } }
                    ), range: key.range, format: key == .exposure ? { String(format: "%+.2f", $0) } : { String(format: "%.0f", $0) },
                    model: edit)
                }
            }
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Looks").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if edit.recipe?.look != nil {
                    Button("None") { edit.change { $0.look = nil } }.controlSize(.small)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                ForEach(LookName.allCases, id: \.self) { look in
                    Button {
                        edit.change { $0.look = Look(name: look, amount: $0.look?.amount ?? 1) }
                    } label: {
                        VStack(spacing: 3) {
                            Group {
                                if let image = edit.lookPreviews[look] {
                                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                                } else {
                                    Rectangle().fill(.quaternary)
                                }
                            }
                            .frame(width: 72, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(edit.recipe?.look?.name == look ? Color.accentColor : .clear, lineWidth: 2))
                            Text(look.label).font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(look.label) look")
                }
            }
            if edit.recipe?.look != nil {
                EditSlider(label: "Strength", value: Binding(
                    get: { (edit.recipe?.look?.amount ?? 1) * 100 },
                    set: { value in edit.change { $0.look?.amount = value / 100 } }
                ), range: 0 ... 100, neutral: 100, model: edit)
            }
        }
    }
}

/// Shape, straighten, turn and flip (R-4604).
private struct CropTab: View {
    @Bindable var edit: EditModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shape").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Picker("Shape", selection: Binding(get: { edit.recipe?.geometry.aspect ?? .free }, set: { edit.setAspect($0) })) {
                ForEach(EditAspect.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            EditSlider(label: "Straighten", value: Binding(
                get: { edit.recipe?.geometry.straighten ?? 0 },
                set: { value in edit.change { $0.geometry.straighten = value } }
            ), range: -45 ... 45, format: { String(format: "%+.1f°", $0) }, model: edit)
            HStack {
                Button {
                    edit.turn(by: 3)
                } label: { Label("Rotate Left", systemImage: "rotate.left") }
                Button {
                    edit.turn(by: 1)
                } label: { Label("Rotate Right", systemImage: "rotate.right") }
            }
            .controlSize(.small)
            HStack {
                Button {
                    edit.change { $0.geometry.flipped.toggle() }
                } label: { Label("Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                Button("Reset Crop") { edit.change { $0.geometry = EditGeometry() } }
                    .disabled(edit.recipe?.geometry == EditGeometry())
            }
            .controlSize(.small)
            Text("Drag inside the box to move it, or a corner to resize it.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The frame (R-4605).
private struct FrameTab: View {
    @Bindable var edit: EditModel

    private var hasFrame: Bool { edit.recipe?.frame != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Templates").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
                ForEach(EditTemplate.allCases, id: \.self) { template in
                    Button(template.label) { edit.change { template.apply(to: &$0) } }
                        .controlSize(.small)
                        .help("Replaces the frame and the text and shapes")
                }
            }
            Toggle("Frame", isOn: Binding(
                get: { hasFrame },
                set: { on in edit.change { $0.frame = on ? ($0.frame ?? Frame()) : nil } }
            ))
        }
        if hasFrame {
            VStack(alignment: .leading, spacing: 8) {
                Text("Canvas").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("Shape", selection: edit.frameValue(\.shape, fallback: .photo)) {
                    ForEach(Frame.Shape.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if edit.recipe?.frame?.shape != .photo {
                    Toggle("Fill the space", isOn: edit.frameValue(\.fill, fallback: false))
                        .help("The photo fills the space inside the border, trimmed at its edges, as on a poster")
                }
                background
                EditSlider(label: "Border", value: Binding(
                    get: { (edit.recipe?.frame?.left ?? 0) * 100 },
                    set: { value in
                        edit.change { recipe in
                            guard var frame = recipe.frame else { return }
                            let extra = frame.bottom - frame.left
                            (frame.top, frame.left, frame.right) = (value / 100, value / 100, value / 100)
                            frame.bottom = min(0.4, value / 100 + extra)
                            recipe.frame = frame
                        }
                    }
                ), range: 0 ... 40, neutral: 5, model: edit)
                EditSlider(label: "Extra at the Bottom", value: Binding(
                    get: { ((edit.recipe?.frame?.bottom ?? 0) - (edit.recipe?.frame?.left ?? 0)) * 100 },
                    set: { value in
                        edit.change { recipe in
                            guard var frame = recipe.frame else { return }
                            frame.bottom = min(0.4, frame.left + value / 100)
                            recipe.frame = frame
                        }
                    }
                ), range: 0 ... 35, model: edit)
                EditSlider(label: "Rounded Corners", value: Binding(
                    get: { (edit.recipe?.frame?.cornerRadius ?? 0) * 100 },
                    set: { value in edit.change { $0.frame?.cornerRadius = value / 100 } }
                ), range: 0 ... 50, model: edit)
                Toggle("Shadow", isOn: edit.frameValue(\.shadow, fallback: false))
            }
        }
    }

    private enum BackgroundKind: String, CaseIterable { case color, blurred, gradient }

    @ViewBuilder private var background: some View {
        let current: BackgroundKind = switch edit.recipe?.frame?.background {
        case .blurredPhoto: .blurred
        case .gradient: .gradient
        default: .color
        }
        Picker("Background", selection: Binding(get: { current }, set: { kind in
            edit.change { recipe in
                switch kind {
                case .color: recipe.frame?.background = .color(.white)
                case .blurred: recipe.frame?.background = .blurredPhoto
                case .gradient: recipe.frame?.background = .gradient(.white, EditColor(red: 0.85, green: 0.85, blue: 0.88))
                }
            }
        })) {
            Text("Colour").tag(BackgroundKind.color)
            Text("Blurred Photo").tag(BackgroundKind.blurred)
            Text("Gradient").tag(BackgroundKind.gradient)
        }
        switch edit.recipe?.frame?.background {
        case let .color(color):
            ColorPicker("Colour", selection: colorBinding(Binding(get: { color }, set: { new in
                edit.change { $0.frame?.background = .color(new) }
            })), supportsOpacity: false)
        case let .gradient(top, bottom):
            ColorPicker("Top", selection: colorBinding(Binding(get: { top }, set: { new in
                edit.change { $0.frame?.background = .gradient(new, bottom) }
            })), supportsOpacity: false)
            ColorPicker("Bottom", selection: colorBinding(Binding(get: { bottom }, set: { new in
                edit.change { $0.frame?.background = .gradient(top, new) }
            })), supportsOpacity: false)
        default:
            EmptyView()
        }
    }
}

/// Text, shapes and pictures on top (R-4606), with fonts (R-4607).
private struct LayersTab: View {
    @Bindable var edit: EditModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Add Text") { add(.text(TextStyle(text: "Text"))) }
                Menu("Add Shape") {
                    ForEach(LayerShape.Kind.allCases, id: \.self) { kind in
                        Button(kind.label) { add(.shape(LayerShape(kind: kind))) }
                    }
                    Button("Picture…", action: addPicture)
                }
                .fixedSize()
            }
            .controlSize(.small)
            ForEach(Array((edit.recipe?.layers ?? []).enumerated().reversed()), id: \.element.id) { index, layer in
                row(layer, index: index)
            }
        }
        if let binding = edit.layer(edit.selectedLayer) {
            Divider()
            LayerEditor(edit: edit, layer: binding)
        }
    }

    private func row(_ layer: Layer, index: Int) -> some View {
        HStack(spacing: 6) {
            Button {
                edit.change { $0.layers[index].hidden.toggle() }
            } label: {
                Image(systemName: layer.hidden ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(layer.hidden ? "Show \(layer.label)" : "Hide \(layer.label)")
            Text(layer.label).lineLimit(1).font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { edit.selectedLayer = layer.id }
            Button {
                edit.change { $0.layers.swapAt(index, min(index + 1, $0.layers.count - 1)) }
            } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).accessibilityLabel("Bring forward").help("Bring forward")
            Button {
                edit.change { $0.layers.swapAt(index, max(index - 1, 0)) }
            } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).accessibilityLabel("Send backward").help("Send backward")
            Button {
                edit.change { $0.layers.remove(at: index) }
            } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).accessibilityLabel("Remove \(layer.label)").help("Remove")
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 4).fill(edit.selectedLayer == layer.id ? Color.accentColor.opacity(0.15) : .clear))
    }

    private func add(_ kind: Layer.Kind) {
        var layer = Layer(kind: kind)
        if case .shape = kind { layer.height = 0.3 }
        edit.change { $0.layers.append(layer) }
        edit.selectedLayer = layer.id
    }

    private func addPicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var layer = Layer(kind: .image(path: url.path))
        layer.width = 0.25
        layer.height = 0.25
        edit.change { $0.layers.append(layer) }
        edit.selectedLayer = layer.id
    }
}

/// The selected layer's settings.
private struct LayerEditor: View {
    @Bindable var edit: EditModel
    @Binding var layer: Layer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch layer.kind {
            case let .text(style):
                TextEditorFields(edit: edit, layerID: layer.id, style: Binding(get: { style }, set: { layer.kind = .text($0) }))
            case let .shape(style): shapeFields(style)
            case let .image(path): Text((path as NSString).lastPathComponent).font(.callout)
            }
            EditSlider(label: "Opacity", value: Binding(get: { layer.opacity * 100 }, set: { layer.opacity = $0 / 100 }),
                       range: 0 ... 100, neutral: 100, model: edit)
            EditSlider(label: "Rotation", value: $layer.rotation, range: -180 ... 180, format: { String(format: "%.0f°", $0) }, model: edit)
        }
    }

    @ViewBuilder
    private func shapeFields(_ style: LayerShape) -> some View {
        let binding = Binding(get: { style }, set: { layer.kind = .shape($0) })
        Picker("Shape", selection: binding.kind) {
            ForEach(LayerShape.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        ColorPicker("Colour", selection: colorBinding(binding.color))
        if style.kind != .line { Toggle("Filled", isOn: binding.filled) }
        EditSlider(label: "Line Width",
                   value: Binding(get: { style.lineWidth * 1000 }, set: { binding.wrappedValue.lineWidth = $0 / 1000 }),
                   range: 1 ... 40, neutral: 4, model: edit)
    }
}

/// Text, font, size, colour and spacing.
private struct TextEditorFields: View {
    @Bindable var edit: EditModel
    let layerID: UUID
    @Binding var style: TextStyle
    @State private var search = ""
    @State private var faces: [String] = []

    var body: some View {
        TextEditor(text: $style.text)
            .font(.callout)
            .frame(minHeight: 54, maxHeight: 110)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
            .accessibilityLabel("Text")
        // A download can finish much later: only the family of the layer as it is then changes, never its text.
        FontPicker(edit: edit, family: style.family) { [edit, layerID] family in
            edit.change { recipe in
                guard let index = recipe.layers.firstIndex(where: { $0.id == layerID }),
                      case var .text(current) = recipe.layers[index].kind else { return }
                current.family = family
                current.face = nil
                recipe.layers[index].kind = .text(current)
            }
        }
        if !faces.isEmpty {
            Picker("Style", selection: Binding(get: { style.face ?? faces.first ?? "" }, set: { style.face = $0 })) {
                ForEach(faces, id: \.self) { Text($0).tag($0) }
            }
        }
        EditSlider(label: "Size", value: Binding(get: { style.size * 1000 }, set: { style.size = $0 / 1000 }),
                   range: 4 ... 250, neutral: 60,
                   model: edit)
        ColorPicker("Colour", selection: colorBinding($style.color))
        Picker("Alignment", selection: $style.alignment) {
            Image(systemName: "text.alignleft").tag(TextStyle.Alignment.left).accessibilityLabel("Left")
            Image(systemName: "text.aligncenter").tag(TextStyle.Alignment.center).accessibilityLabel("Centre")
            Image(systemName: "text.alignright").tag(TextStyle.Alignment.right).accessibilityLabel("Right")
        }
        .pickerStyle(.segmented)
        EditSlider(label: "Letter Spacing", value: Binding(get: { style.tracking * 100 }, set: { style.tracking = $0 / 100 }),
                   range: -10 ... 40, model: edit)
        EditSlider(label: "Line Height", value: Binding(get: { style.lineHeight * 100 }, set: { style.lineHeight = $0 / 100 }),
                   range: 70 ... 200, neutral: 110, model: edit)
        Toggle("Capitals", isOn: $style.uppercase)
        Toggle("Shadow", isOn: $style.shadow)
        Toggle("Outline", isOn: Binding(get: { style.outline != nil }, set: { style.outline = $0 ? .black : nil }))
        if let outline = style.outline {
            ColorPicker("Outline Colour", selection: colorBinding(Binding(get: { outline }, set: { style.outline = $0 })))
        }
        Color.clear.frame(height: 0)
            .task(id: style.family) {
                let family = style.family
                faces = await Task.detached(priority: .userInitiated) { FontCatalog.faces(of: family) }.value
            }
    }
}

/// The font list (R-4607): installed families shown in their own face, Apple's downloadable ones marked; a download
/// needs the person's allowance once (D-129).
private struct FontPicker: View {
    @Bindable var edit: EditModel
    let family: String
    var choose: (String) -> Void
    @State private var search = ""
    @State private var families: [FontCatalog.Family] = []
    @State private var asking: String?
    @State private var downloading: String?
    @State private var failed: String?
    private var preferences: Preferences { AppModel.shared.preferences }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Font").font(.callout)
                Spacer()
                Text(family).font(.custom(family, size: 13)).lineLimit(1)
            }
            TextField("Search fonts", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(shown) { item in
                        Button {
                            pick(item)
                        } label: {
                            HStack {
                                Text(item.name).font(item.installed ? .custom(item.name, size: 14) : .system(size: 13))
                                    .lineLimit(1)
                                Spacer()
                                if downloading == item.name {
                                    ProgressView().controlSize(.mini)
                                } else if !item.installed {
                                    Image(systemName: "icloud.and.arrow.down").foregroundStyle(.secondary)
                                        .accessibilityLabel("Downloads from Apple")
                                }
                            }
                            .padding(.vertical, 2)
                            .padding(.horizontal, 4)
                            .background(RoundedRectangle(cornerRadius: 3)
                                .fill(item.name == family ? Color.accentColor.opacity(0.18) : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 170)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
            if let asking {
                VStack(alignment: .leading, spacing: 6) {
                    Text("“\(asking)” is one of Apple's fonts that macOS downloads from Apple. Allow font downloads?")
                        .font(.caption)
                    HStack {
                        Button("Allow and Download") {
                            preferences.allowFontDownloads = true
                            self.asking = nil
                            download(asking)
                        }
                        Button("Not Now") { self.asking = nil }
                    }
                    .controlSize(.small)
                }
            }
            if let failed { Text(failed).font(.caption).foregroundStyle(.secondary) }
        }
        .task {
            families = await Task.detached(priority: .userInitiated) { FontCatalog.families() }.value
        }
    }

    private var shown: [FontCatalog.Family] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return families }
        return families.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func pick(_ item: FontCatalog.Family) {
        failed = nil
        guard !item.installed else {
            choose(item.name)
            return
        }
        if preferences.allowFontDownloads { download(item.name) } else { asking = item.name }
    }

    private func download(_ name: String) {
        downloading = name
        Task {
            let ok = await FontCatalog.download(name)
            downloading = nil
            if ok {
                choose(name)
                families = await Task.detached(priority: .userInitiated) { FontCatalog.families() }.value
            } else {
                failed = "“\(name)” could not be downloaded. Check the internet connection and try again."
            }
        }
    }
}

/// Export (R-4608).
private struct ExportTab: View {
    @Bindable var edit: EditModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch edit.kind {
            case .video: videoSettings
            case .audio: AudioExportSettings(edit: edit)
            default: photoSettings
            }
            Divider()
            destination
        }
    }

    @ViewBuilder private var videoSettings: some View {
        Picker("Size", selection: edit.value(\.export.size, fallback: .original)) {
            ForEach(ExportSettings.Size.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Picker("Codec", selection: edit.value(\.export.videoCodec, fallback: .hevc)) {
            ForEach(ExportSettings.VideoCodec.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Picker("File", selection: Binding(
            get: { edit.recipe?.export.videoContainer },
            set: { value in edit.change { $0.export.videoContainer = value } }
        )) {
            Text("Like the Original").tag(ExportSettings.VideoContainer?.none)
            ForEach(ExportSettings.VideoContainer.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
        }
        Toggle("Keep the location", isOn: edit.value(\.export.keepLocation, fallback: true))
        if let recipe = edit.recipe {
            Text(VideoComposer.isLossless(recipe, size: edit.session?.size)
                ? "Only cuts, turns or muting: the picture is not encoded again. The first sound track is kept."
                : "The picture or the sound changes, so it is encoded again with \(recipe.export.videoCodec.label).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var photoSettings: some View {
            Picker("Format", selection: edit.value(\.export.format, fallback: .jpeg)) {
                ForEach(ExportSettings.PhotoFormat.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Size", selection: edit.value(\.export.size, fallback: .original)) {
                ForEach(ExportSettings.Size.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if edit.recipe?.export.format != .png {
                EditSlider(label: "Quality", value: Binding(
                    get: { (edit.recipe?.export.quality ?? 0.92) * 100 },
                    set: { value in edit.change { $0.export.quality = value / 100 } }
                ), range: 50 ... 100, neutral: 92, model: edit)
            }
            Toggle("Display P3 colour", isOn: edit.value(\.export.displayP3, fallback: false))
                .help("Wider colour for screens that show it; sRGB suits most places a photo is posted")
            Toggle("Keep the location", isOn: edit.value(\.export.keepLocation, fallback: true))
            Toggle("Keep the camera details", isOn: edit.value(\.export.keepCamera, fallback: true))
            Text("HDR is not kept in an edited copy.").font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var destination: some View {
            Text("Save To").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack {
                Text(edit.exportFolder.map { "“\($0.lastPathComponent)”" } ?? "Beside the original").font(.callout)
                Spacer()
                Button("Choose…", action: choose).controlSize(.small)
                if edit.exportFolder != nil {
                    Button("Beside Original") { edit.exportFolder = nil }.controlSize(.small)
                }
            }
            Button {
                edit.export()
            } label: {
                Label(edit.exporting ? "Exporting…" : "Export", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(edit.exporting)
            Text("A new file is written; the original is not changed.").font(.caption).foregroundStyle(.secondary)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        edit.exportFolder = url
    }
}

/// Cuts, speed, fades and sound for a video (R-4609).
private struct TrimTab: View {
    @Bindable var edit: EditModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cut").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack {
                Button("Start Here") { edit.trimStart(at: edit.player.time) }
                    .help("Everything before the playhead goes")
                Button("End Here") { edit.trimEnd(at: edit.player.time) }
                    .help("Everything after the playhead goes")
                Button("Split Here") { edit.split(at: edit.player.time) }
                    .help("Cut at the playhead, so either part can be removed")
            }
            .controlSize(.small)
            .disabled(edit.playingResult)
            let parts = edit.keptRanges
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                HStack {
                    Text("\(EditTimelineView.clock(part.start)) – \(EditTimelineView.clock(part.end))").font(.callout.monospacedDigit())
                    Spacer()
                    if parts.count > 1 {
                        Button { edit.removePart(part) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove this part")
                            .help("Remove this part")
                    }
                }
            }
            Button("Keep All") { edit.resetCuts() }.controlSize(.small).disabled(edit.recipe?.timeline?.kept.isEmpty ?? true)
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("Speed").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Picker("Speed", selection: Binding(get: { edit.timeline.speed }, set: { value in edit.setTimeline { $0.speed = value } })) {
                ForEach([0.25, 0.5, 1, 1.5, 2, 4], id: \.self) { Text($0 == 1 ? "Normal" : "\($0.formatted())×").tag($0) }
            }
            .labelsHidden()
            Text("Fades and Sound").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            EditSlider(label: "Fade In",
                       value: Binding(get: { edit.timeline.fadeIn }, set: { value in edit.setTimeline { $0.fadeIn = value } }),
                       range: 0 ... 5, format: { String(format: "%.1f s", $0) }, model: edit)
            EditSlider(label: "Fade Out", value: Binding(get: { edit.timeline.fadeOut },
                                                         set: { value in edit.setTimeline { $0.fadeOut = value } }),
                       range: 0 ... 5, format: { String(format: "%.1f s", $0) }, model: edit)
            EditSlider(label: "Volume", value: Binding(get: { min(edit.timeline.volume, 1) * 100 },
                                                       set: { value in edit.setTimeline { $0.volume = value / 100 } }),
                       range: 0 ... 100, neutral: 100, format: { String(format: "%.0f %%", $0) }, model: edit)
            Toggle("Mute", isOn: Binding(get: { edit.timeline.volume == 0 }, set: { on in edit.setTimeline { $0.volume = on ? 0 : 1 } }))
        }
        Divider()
        Button("Save Frame at Playhead") { edit.saveFrame() }
            .controlSize(.small)
            .disabled(edit.playingResult)
            .help("Saves the frame shown as a PNG, at full size")
    }
}
