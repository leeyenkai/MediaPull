import AppKit
import ImageIO
import MediaPullCore
import MediaPullEdit
import SwiftUI
import UniformTypeIdentifiers

/// The Inspector pane (R-4601, D-132): the tools for the open file as a strip of tabs, and the Export bar at its foot.
struct EditInspectorPane: View {
    @Bindable var model: WindowModel
    @Bindable var edit: EditModel

    private var tools: [EditTab] { edit.tabs.filter { $0 != .export } }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: edit.tabs.isEmpty ? "Inspector" : "", pane: .editInspector, model: model) {
                if !edit.tabs.isEmpty {
                    HStack(spacing: 2) {
                        ForEach(tools) { tab in
                            ToolTab(title: tab.label, symbol: tab.symbol, selected: edit.tab == tab) { edit.tab = tab }
                        }
                        Rectangle().fill(.separator).frame(width: 1, height: 28).padding(.horizontal, 3)
                        ToolTab(title: EditTab.export.label, symbol: EditTab.export.symbol, selected: edit.tab == .export) {
                            edit.tab = .export
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            Divider()
            if edit.recipe == nil {
                Text(edit.current == nil ? "Open a photo, video or audio file to edit it." : "Opening…")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if edit.choosingFont, edit.tab == .text, let layer = edit.layer(edit.selectedLayer) {
                    // The font list takes the whole Inspector, so it is the only thing that scrolls (D-132).
                    FontList(edit: edit, layer: layer)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            switch edit.tab {
                            case .trim: TrimTab(edit: edit)
                            case .sound: SoundTab(edit: edit)
                            case .tags: AudioTagsTab(edit: edit)
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
                Divider()
                ExportBar(edit: edit)
            }
        }
        .background(PaneSurface.tools.color)
    }
}

/// Export, always at the foot of the Inspector (R-4601, D-132): what will be written, Export, and the file's edits.
struct ExportBar: View {
    @Bindable var edit: EditModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                edit.tab = .export
            } label: {
                HStack(spacing: 6) {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if edit.tab != .export {
                        Text("Settings").font(.caption).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Export settings: format, size and where the file goes")
            .accessibilityLabel("Export settings: \(summary)")
            HStack(spacing: 12) {
                if edit.recipe?.isEdited == true {
                    Button("Revert") { edit.revert() }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help("Remove every edit of this file; the original was never changed (⌘Z brings them back)")
                }
                if edit.kind != .audio {
                    Button("Copy Settings") { edit.copySettings() }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help("Copy this file's look, adjustments, frame and text, to paste onto files selected in Media")
                }
                Spacer(minLength: 4)
                Button {
                    edit.export()
                } label: {
                    Text(edit.exporting ? "Exporting…" : "Export").frame(minWidth: 84)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(edit.exporting)
                .help("Write the result as a new file; the original is not changed")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// For example "JPEG · 1080 × 1350 · Beside the original".
    private var summary: String {
        guard let recipe = edit.recipe else { return "" }
        var parts: [String] = []
        switch edit.kind {
        case .video:
            parts.append(recipe.export.videoContainer?.label ?? (edit.current?.pathExtension.uppercased() ?? "Video"))
            parts.append(recipe.export.videoCodec.label)
            if recipe.export.size != .original { parts.append(recipe.export.size.label) }
        case .audio:
            let source = AudioOutput.like(edit.current?.pathExtension ?? "m4a", codec: edit.audioSource?.codec)
            parts.append((recipe.export.audioFormat ?? source).label)
        default:
            parts.append(recipe.export.format.label)
            if let pixels = edit.outputPixels, pixels.width > 0 {
                parts.append("\(Int(pixels.width)) × \(Int(pixels.height))")
            }
        }
        parts.append(edit.exportFolder.map { "In “\($0.lastPathComponent)”" } ?? "Beside the original")
        return parts.joined(separator: " · ")
    }
}

/// Looks first, then Light, Colour and Effects (R-4603).
private struct AdjustTab: View {
    @Bindable var edit: EditModel

    var body: some View {
        looks
        ForEach(["Light", "Colour", "Effects"], id: \.self) { group in
            let keys = Adjustments.Key.allCases.filter { $0.group == group }
            InspectorSection(title: group, key: "adjust.\(group)", changed: keys.contains { (edit.recipe?.adjust[$0] ?? 0) != 0 },
                             reset: { edit.change { recipe in keys.forEach { recipe.adjust[$0] = 0 } } }) {
                ForEach(keys, id: \.self) { key in
                    EditSlider(label: key.label, value: Binding(
                        get: { edit.recipe?.adjust[key] ?? 0 },
                        set: { value in edit.change { $0.adjust[key] = value } }
                    ), range: key.range, format: key == .exposure ? { String(format: "%+.2f", $0) } : { String(format: "%.0f", $0) },
                    model: edit)
                }
            }
        }
    }

    private var looks: some View {
        InspectorSection(title: "Looks", key: "adjust.looks", changed: edit.recipe?.look != nil,
                         reset: { edit.change { $0.look = nil } }) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    tile(label: "None", image: edit.noLookPreview, selected: edit.recipe?.look == nil) { edit.change { $0.look = nil } }
                    ForEach(LookName.allCases, id: \.self) { look in
                        tile(label: look.label, image: edit.lookPreviews[look], selected: edit.recipe?.look?.name == look) {
                            edit.change { $0.look = Look(name: look, amount: $0.look?.amount ?? 1) }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            if edit.recipe?.look != nil {
                EditSlider(label: "Strength", value: Binding(
                    get: { (edit.recipe?.look?.amount ?? 1) * 100 },
                    set: { value in edit.change { $0.look?.amount = value / 100 } }
                ), range: 0 ... 100, neutral: 100, model: edit)
            }
        }
    }

    private func tile(label: String, image: CGImage?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Group {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .frame(width: 60, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                Text(label).font(.caption2).foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) look")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Shape, straighten, turn and flip (R-4604).
private struct CropTab: View {
    @Bindable var edit: EditModel

    var body: some View {
        InspectorSection(title: "Shape", key: "crop.shape", changed: edit.recipe?.geometry != EditGeometry(),
                         reset: { edit.change { $0.geometry = EditGeometry() } }) {
            WrappingChips(items: EditAspect.allCases, label: \.label, selected: edit.recipe?.geometry.aspect ?? .free) {
                edit.setAspect($0)
            }
            if let pixels = edit.cropPixels, pixels.width > 0 {
                Text("\(Int(pixels.width)) × \(Int(pixels.height)) px of the photo")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            EditSlider(label: "Straighten", value: Binding(
                get: { edit.recipe?.geometry.straighten ?? 0 },
                set: { value in edit.change { $0.geometry.straighten = value } }
            ), range: -45 ... 45, format: { String(format: "%+.1f°", $0) }, model: edit)
            HStack(spacing: 4) {
                QuietIconButton(title: "Rotate Left", symbol: "rotate.left", size: 14) { edit.turn(by: 3) }
                QuietIconButton(title: "Rotate Right", symbol: "rotate.right", size: 14) { edit.turn(by: 1) }
                QuietIconButton(title: "Flip", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", size: 14) {
                    edit.change { $0.geometry.flip() }
                }
            }
            Text("Drag inside the box to move it, or a corner to resize it.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A row of chips that wraps onto more lines when the Inspector is narrow.
struct WrappingChips<Item: Hashable>: View {
    let items: [Item]
    let label: KeyPath<Item, String>
    let selected: Item
    let choose: (Item) -> Void

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(items, id: \.self) { item in
                ValueChip(title: item[keyPath: label], selected: item == selected) { choose(item) }
            }
        }
    }
}

/// Lays its views out in rows, starting a new row when the next view would not fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let gap = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += size.width + gap
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

/// The frame (R-4605).
private struct FrameTab: View {
    @Bindable var edit: EditModel
    @State private var confirming: EditTemplate?

    private var hasFrame: Bool { edit.recipe?.frame != nil }

    var body: some View {
        InspectorSection(title: "Templates", key: "frame.templates") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 8)], spacing: 8) {
                ForEach(EditTemplate.allCases, id: \.self) { template in
                    TemplateCard(template: template) { choose(template) }
                }
            }
            Text("A template sets the frame and replaces the text and shapes. ⌘Z undoes it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .alert("Replace your text and shapes?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
               presenting: confirming) { template in
            Button("Replace") { apply(template) }
            Button("Cancel", role: .cancel) {}
        } message: { template in
            Text("\(template.label) sets the frame and puts its own text in place of the text, shapes and pictures you added. "
                + "⌘Z undoes it.")
        }
        InspectorSection(title: "Frame", key: "frame.frame", changed: hasFrame,
                         reset: { edit.change { $0.frame = nil } }) {
            Toggle("Frame around the photo", isOn: Binding(
                get: { hasFrame },
                set: { on in edit.change { $0.frame = on ? ($0.frame ?? Frame()) : nil } }
            ))
            if hasFrame { frameSettings }
        }
    }

    private func choose(_ template: EditTemplate) {
        if EditTemplate.wouldReplaceOwnLayers(edit.recipe?.layers ?? []) { confirming = template } else { apply(template) }
    }

    private func apply(_ template: EditTemplate) {
        edit.change { template.apply(to: &$0) }
        edit.selectedLayer = nil
    }

    @ViewBuilder private var frameSettings: some View {
        Picker("Canvas", selection: edit.frameValue(\.shape, fallback: .photo)) {
            ForEach(Frame.Shape.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        if edit.recipe?.frame?.shape != .photo {
            Toggle("Fill the space", isOn: edit.frameValue(\.fill, fallback: false))
                .help("The photo fills the space inside the border, trimmed at its edges, as on a poster")
        }
        background
        let extra = max(0, (edit.recipe?.frame?.bottom ?? 0) - (edit.recipe?.frame?.left ?? 0))
        let range = Frame.borderRange(extra: extra)
        EditSlider(label: "Border", value: Binding(
            get: { (edit.recipe?.frame?.left ?? 0) * 100 },
            set: { value in
                edit.change { recipe in
                    guard var frame = recipe.frame else { return }
                    // The extra at the bottom is kept whole: the border stops where the bottom would pass 40% (round 11,
                    // B11-7); the slider's range ends there too (D-132).
                    let extra = frame.bottom - frame.left
                    let border = max(0, min(value / 100, Frame.largestInset - extra))
                    (frame.top, frame.left, frame.right) = (border, border, border)
                    frame.bottom = border + extra
                    recipe.frame = frame
                }
            }
        ), range: (range.lowerBound * 100) ... (range.upperBound * 100), neutral: 5, model: edit)
        EditSlider(label: "Extra at the Bottom", value: Binding(
            get: { extra * 100 },
            set: { value in
                edit.change { recipe in
                    guard var frame = recipe.frame else { return }
                    frame.bottom = min(Frame.largestInset, frame.left + value / 100)
                    recipe.frame = frame
                }
            }
        ), range: 0 ... max(1, (Frame.largestInset - (edit.recipe?.frame?.left ?? 0)) * 100), model: edit)
        EditSlider(label: "Rounded Corners", value: Binding(
            get: { (edit.recipe?.frame?.cornerRadius ?? 0) * 100 },
            set: { value in edit.change { $0.frame?.cornerRadius = value / 100 } }
        ), range: 0 ... 50, model: edit)
        Toggle("Shadow", isOn: edit.frameValue(\.shadow, fallback: false))
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
            Text("Blurred").tag(BackgroundKind.blurred)
            Text("Gradient").tag(BackgroundKind.gradient)
        }
        .pickerStyle(.segmented)
        switch edit.recipe?.frame?.background {
        case let .color(color):
            ColorRow(title: "Colour", color: Binding(get: { color }, set: { new in edit.change { $0.frame?.background = .color(new) } }))
        case let .gradient(top, bottom):
            ColorRow(title: "Top", color: Binding(get: { top }, set: { new in
                edit.change { $0.frame?.background = .gradient(new, bottom) }
            }))
            ColorRow(title: "Bottom", color: Binding(get: { bottom }, set: { new in
                edit.change { $0.frame?.background = .gradient(top, new) }
            }))
        default:
            EmptyView()
        }
    }
}

/// A small drawing of a template's layout, made from the template itself so it always matches (D-132).
private struct TemplateCard: View {
    let template: EditTemplate
    let action: () -> Void
    @State private var hovering = false

    private var recipe: EditRecipe {
        var recipe = EditRecipe(source: EditSource(path: "/", kind: .image))
        template.apply(to: &recipe)
        return recipe
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                drawing
                    .frame(width: 58, height: 72)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.08 : 0.03)))
                Text(template.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(template.label): sets the frame and replaces the text and shapes")
        .accessibilityLabel("\(template.label) template")
    }

    private var drawing: some View {
        Canvas { context, size in
            let recipe = recipe
            // The canvas's shape: the frame's own, else a 4:5 photo grown by its border.
            let ratio = recipe.frame?.shape.ratio ?? 0.8
            let canvas = fitted(ratio, in: size)
            let photoColor = Color(red: 0.42, green: 0.55, blue: 0.72)
            if let frame = recipe.frame {
                context.fill(Path(canvas), with: .color(.white))
                context.stroke(Path(canvas), with: .color(.black.opacity(0.15)), lineWidth: 0.5)
                let side = min(canvas.width, canvas.height)
                let photo = CGRect(x: canvas.minX + frame.left * side, y: canvas.minY + frame.top * side,
                                   width: canvas.width - (frame.left + frame.right) * side,
                                   height: canvas.height - (frame.top + frame.bottom) * side)
                context.fill(Path(photo), with: .color(photoColor))
            } else {
                context.fill(Path(canvas), with: .color(photoColor))
            }
            for layer in recipe.layers {
                guard case let .text(style) = layer.kind else { continue }
                let lines = max(1, style.text.split(separator: "\n").count)
                let height = max(1.5, min(layer.height * canvas.height * 0.7, style.size * canvas.height * 1.6 * Double(lines)))
                let width = layer.width * canvas.width * 0.8
                let x: Double = switch style.alignment {
                case .left: canvas.minX + (layer.x - layer.width / 2) * canvas.width
                case .center: canvas.minX + layer.x * canvas.width - width / 2
                case .right: canvas.minX + (layer.x + layer.width / 2) * canvas.width - width
                }
                let bar = CGRect(x: x, y: canvas.minY + layer.y * canvas.height - height / 2, width: width, height: height)
                context.fill(Path(roundedRect: bar, cornerRadius: 1), with: .color(style.color.color.opacity(0.85)))
            }
        }
    }

    private func fitted(_ ratio: Double, in size: CGSize) -> CGRect {
        let width = min(size.width, size.height * ratio)
        let height = width / ratio
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
}

/// A colour with quick swatches for the common ones (D-132), and the well for any other.
struct ColorRow: View {
    let title: String
    @Binding var color: EditColor

    static let swatches: [(name: String, color: EditColor)] = [
        ("White", .white),
        ("Paper", EditColor(red: 0.969, green: 0.961, blue: 0.941)),
        ("Light Grey", EditColor(red: 0.85, green: 0.85, blue: 0.86)),
        ("Charcoal", EditColor(red: 0.2, green: 0.2, blue: 0.21)),
        ("Black", .black),
    ]

    var body: some View {
        HStack(spacing: 5) {
            Text(title).font(.callout)
            Spacer(minLength: 4)
            ForEach(Self.swatches, id: \.name) { swatch in
                let selected = swatch.color == color
                Button {
                    color = swatch.color
                } label: {
                    Circle().fill(swatch.color.color)
                        .frame(width: 15, height: 15)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                        .padding(2)
                        .overlay(Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(swatch.name)
                .accessibilityLabel(swatch.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            ColorPicker(title, selection: colorBinding($color), supportsOpacity: false).labelsHidden()
        }
    }
}

/// Text, shapes and pictures on top (R-4606), with fonts (R-4607).
private struct LayersTab: View {
    @Bindable var edit: EditModel
    @FocusState private var listFocused: Bool

    var body: some View {
        InspectorSection(title: "Layers", key: "text.layers") {
            HStack(spacing: 2) {
                Text("Add").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                QuietIconButton(title: "Add Text", symbol: "textformat", size: 13) { add(.text(TextStyle(text: "Text"))) }
                ForEach(LayerShape.Kind.allCases, id: \.self) { kind in
                    QuietIconButton(title: "Add \(kind.label)", symbol: kind.symbol, size: 13) { add(.shape(LayerShape(kind: kind))) }
                }
                QuietIconButton(title: "Add Picture…", symbol: "photo", help: "Add a picture from a file, such as a logo", size: 13) {
                    addPicture()
                }
            }
            let layers = edit.recipe?.layers ?? []
            if layers.isEmpty {
                Text("Add text, a shape or a picture, or choose a template in Frame.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(layers.enumerated().reversed()), id: \.element.id) { index, layer in
                        LayerRow(edit: edit, layer: layer, index: index, count: layers.count) { listFocused = true }
                    }
                }
                .focusable(edit.window?.section == .edit)
                .focusEffectDisabled()
                .focused($listFocused)
                .onDeleteCommand { edit.removeSelectedLayer() }
            }
        }
        if let binding = edit.layer(edit.selectedLayer) {
            LayerEditor(edit: edit, layer: binding)
        }
    }

    private func add(_ kind: Layer.Kind) {
        var layer = Layer(kind: kind)
        if case .shape = kind { layer.height = 0.3 }
        edit.change { $0.layers.append(layer) }
        edit.selectedLayer = layer.id
    }

    private func addPicture() {
        let panel = NSOpenPanel()
        // Only pictures the Mac can draw (an SVG opens but draws nothing, B14-m2).
        panel.allowedContentTypes = ((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
            .compactMap { UTType($0) }.filter { $0.conforms(to: .image) && $0 != .svg }
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var layer = Layer(kind: .image(path: url.path))
        layer.width = 0.25
        layer.height = 0.25
        edit.change { $0.layers.append(layer) }
        edit.selectedLayer = layer.id
    }
}

/// One layer in the list: its kind, name and visibility; order and Remove on the selected row and on hover.
private struct LayerRow: View {
    @Bindable var edit: EditModel
    let layer: Layer
    let index: Int
    let count: Int
    let focusList: () -> Void
    @State private var hovering = false

    private var selected: Bool { edit.selectedLayer == layer.id }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: layer.symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(layer.label).lineLimit(1).font(.callout)
                .foregroundStyle(layer.hidden ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                // VoiceOver chooses the layer with the name's action, as a click on the row does.
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { edit.selectedLayer = layer.id }
            if selected || hovering {
                QuietIconButton(title: "Bring Forward", symbol: "chevron.up", size: 10) { edit.moveLayer(layer.id, by: 1) }
                    .disabled(index >= count - 1)
                QuietIconButton(title: "Send Backward", symbol: "chevron.down", size: 10) { edit.moveLayer(layer.id, by: -1) }
                    .disabled(index == 0)
                QuietIconButton(title: "Duplicate \(layer.label)", symbol: "plus.square.on.square", help: "Duplicate", size: 10) {
                    edit.duplicateLayer(layer.id)
                }
                QuietIconButton(title: "Remove \(layer.label)", symbol: "trash", help: "Remove (Delete)", size: 10) {
                    edit.removeLayer(layer.id)
                }
            }
            QuietIconButton(title: layer.hidden ? "Show \(layer.label)" : "Hide \(layer.label)", symbol: layer.hidden ? "eye.slash" : "eye",
                            size: 10, emphasised: layer.hidden) { edit.toggleLayerHidden(layer.id) }
                .opacity(layer.hidden || selected || hovering ? 1 : 0.45)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(hovering ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onTapGesture {
            edit.selectedLayer = layer.id
            focusList()
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Duplicate") { edit.duplicateLayer(layer.id) }
            Button("Bring Forward") { edit.moveLayer(layer.id, by: 1) }.disabled(index >= count - 1)
            Button("Send Backward") { edit.moveLayer(layer.id, by: -1) }.disabled(index == 0)
            Button(layer.hidden ? "Show" : "Hide") { edit.toggleLayerHidden(layer.id) }
            Divider()
            Button("Remove") { edit.removeLayer(layer.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The selected layer's settings.
private struct LayerEditor: View {
    @Bindable var edit: EditModel
    @Binding var layer: Layer

    var body: some View {
        switch layer.kind {
        case let .text(style):
            TextEditorFields(edit: edit, layer: $layer, style: Binding(get: { style }, set: { layer.kind = .text($0) }))
        case let .shape(style):
            InspectorSection(title: "Shape", key: "text.shape") { shapeFields(style) }
        case let .image(path):
            InspectorSection(title: "Picture", key: "text.picture") {
                Text((path as NSString).lastPathComponent).font(.callout).lineLimit(1).truncationMode(.middle)
            }
        }
        InspectorSection(title: "Placement", key: "text.placement") {
            EditSlider(label: "Opacity", value: Binding(get: { layer.opacity * 100 }, set: { layer.opacity = $0 / 100 }),
                       range: 0 ... 100, neutral: 100, model: edit)
            EditSlider(label: "Rotation", value: $layer.rotation, range: -180 ... 180, format: { String(format: "%.0f°", $0) }, model: edit)
            Text("Drag the layer on the canvas to move it, or a corner to resize it.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func shapeFields(_ style: LayerShape) -> some View {
        let binding = Binding(get: { style }, set: { layer.kind = .shape($0) })
        Picker("Shape", selection: binding.kind) {
            ForEach(LayerShape.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        ColorRow(title: "Colour", color: binding.color)
        if style.kind != .line { Toggle("Filled", isOn: binding.filled) }
        EditSlider(label: "Line Width",
                   value: Binding(get: { style.lineWidth * 1000 }, set: { binding.wrappedValue.lineWidth = $0 / 1000 }),
                   range: 1 ... 40, neutral: 4, model: edit)
    }
}

/// Text, font, size, colour and spacing.
private struct TextEditorFields: View {
    @Bindable var edit: EditModel
    @Binding var layer: Layer
    @Binding var style: TextStyle
    @State private var faces: [String] = []
    @FocusState private var textFocused: Bool

    private func takeFocus(_ pending: Bool) {
        guard pending else { return }
        edit.focusTextPending = false
        // After the tab has drawn the field.
        Task { @MainActor in textFocused = true }
    }

    var body: some View {
        InspectorSection(title: "Text", key: "text.text") {
            TextEditor(text: $style.text)
                .font(.callout)
                .frame(minHeight: 54, maxHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
                .focused($textFocused)
                .accessibilityLabel("Text")
                .onChange(of: edit.focusTextPending) { _, pending in takeFocus(pending) }
                .onAppear { takeFocus(edit.focusTextPending) }
            Button {
                edit.choosingFont = true
            } label: {
                HStack {
                    Text("Font").font(.callout)
                    Spacer(minLength: 4)
                    Text(style.family).font(.custom(style.family, size: 13)).lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choose the font from every font on this Mac and Apple's")
            .accessibilityLabel("Font: \(style.family)")
            if !faces.isEmpty {
                // With no face chosen, the face that is drawn (B8-7).
                let drawn = LayerRenderer.drawnFace(style)
                let shown = style.face ?? drawn.flatMap { faces.contains($0) ? $0 : nil } ?? faces.first ?? ""
                Picker("Style", selection: Binding(get: { shown },
                                                   set: { style.face = $0 })) {
                    ForEach(faces, id: \.self) { Text($0).tag($0) }
                }
            }
            EditSlider(label: "Size", value: Binding(get: { style.size * 1000 }, set: { style.size = $0 / 1000 }),
                       range: 4 ... 250, neutral: 60, model: edit)
            ColorRow(title: "Colour", color: $style.color)
            HStack(spacing: 6) {
                Picker("Alignment", selection: $style.alignment) {
                    Image(systemName: "text.alignleft").tag(TextStyle.Alignment.left).accessibilityLabel("Left")
                    Image(systemName: "text.aligncenter").tag(TextStyle.Alignment.center).accessibilityLabel("Centre")
                    Image(systemName: "text.alignright").tag(TextStyle.Alignment.right).accessibilityLabel("Right")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 4)
                Toggle("Capitals", isOn: $style.uppercase).toggleStyle(.button)
                Toggle("Shadow", isOn: $style.shadow).toggleStyle(.button)
                Toggle("Outline", isOn: Binding(get: { style.outline != nil }, set: { style.outline = $0 ? .black : nil }))
                    .toggleStyle(.button)
            }
            .controlSize(.small)
            if let outline = style.outline {
                ColorRow(title: "Outline", color: Binding(get: { outline }, set: { style.outline = $0 }))
            }
        }
        .task(id: style.family) {
            let family = style.family
            faces = await Task.detached(priority: .userInitiated) { FontCatalog.faces(of: family) }.value
        }
        InspectorSection(title: "Spacing", key: "text.spacing", changed: style.tracking != 0 || abs(style.lineHeight - 1.1) > 0.001,
                         reset: {
                             style.tracking = 0
                             style.lineHeight = 1.1
                         }) {
            EditSlider(label: "Letter Spacing", value: Binding(get: { style.tracking * 100 }, set: { style.tracking = $0 / 100 }),
                       range: -10 ... 40, model: edit)
            EditSlider(label: "Line Height", value: Binding(get: { style.lineHeight * 100 }, set: { style.lineHeight = $0 / 100 }),
                       range: 70 ... 200, neutral: 110, model: edit)
        }
    }
}

/// The font list (R-4607), in place of the layer's settings (D-132): installed families shown in their own face, Apple's
/// downloadable ones marked; a download needs the person's allowance once (D-129).
private struct FontList: View {
    @Bindable var edit: EditModel
    @Binding var layer: Layer
    @State private var search = ""
    @State private var families: [FontCatalog.Family] = []
    @State private var asking: String?
    @State private var downloading: String?
    @State private var failed: String?
    @FocusState private var searchFocused: Bool
    private var preferences: Preferences { AppModel.shared.preferences }

    private var family: String {
        if case let .text(style) = layer.kind { return style.family }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Button {
                    edit.choosingFont = false
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Back").font(.callout)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Back to “\(layer.label)”")
                Spacer()
                Text("Font for “\(layer.label)”").font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.tail)
            }
            TextField("Search fonts", text: $search)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
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
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
            }
            if let failed { Text(failed).font(.caption).foregroundStyle(.secondary) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(shown) { item in
                            Button {
                                pick(item)
                            } label: {
                                HStack {
                                    Text(item.name).font(item.installed ? .custom(item.name, size: 15) : .system(size: 13))
                                        .lineLimit(1)
                                    Spacer()
                                    if downloading == item.name {
                                        ProgressView().controlSize(.mini)
                                    } else if !item.installed {
                                        Image(systemName: "icloud.and.arrow.down").foregroundStyle(.secondary)
                                            .accessibilityLabel("Downloads from Apple")
                                    } else if item.name == family {
                                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor).accessibilityLabel("Chosen")
                                    }
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                                .background(RoundedRectangle(cornerRadius: 4)
                                    .fill(item.name == family ? Color.accentColor.opacity(0.16) : .clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(item.name)
                        }
                    }
                }
                .onChange(of: families.count) { _, _ in proxy.scrollTo(family, anchor: .center) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            families = await Task.detached(priority: .userInitiated) { FontCatalog.families() }.value
            searchFocused = true
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

    /// A download can finish much later: only the family of the layer as it is then changes, never its text.
    private func choose(_ name: String) {
        let id = layer.id
        edit.change { recipe in
            guard let index = recipe.layers.firstIndex(where: { $0.id == id }),
                  case var .text(current) = recipe.layers[index].kind else { return }
            current.family = name
            current.face = nil
            recipe.layers[index].kind = .text(current)
        }
        edit.choosingFont = false
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

/// Export settings (R-4608): what is written and where. Export itself is in the Export bar.
private struct ExportTab: View {
    @Bindable var edit: EditModel

    var body: some View {
        InspectorSection(title: "Format", key: "export.format") {
            switch edit.kind {
            case .video: videoSettings
            case .audio: AudioFormatSettings(edit: edit)
            default: photoSettings
            }
        }
        InspectorSection(title: "Save To", key: "export.destination") {
            HStack {
                Text(edit.exportFolder.map { "“\($0.lastPathComponent)”" } ?? "Beside the original").font(.callout)
                Spacer()
                Button("Choose…", action: choose).controlSize(.small)
                if edit.exportFolder != nil {
                    Button("Beside Original") { edit.exportFolder = nil }.controlSize(.small)
                }
            }
            Text("A new file is written; the original is not changed.").font(.caption).foregroundStyle(.secondary)
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
        if let pixels = edit.outputPixels, pixels.width > 0 {
            Text("Written at \(Int(pixels.width)) × \(Int(pixels.height)) px.").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
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
        InspectorSection(title: "Cut", key: "trim.cut", changed: !(edit.recipe?.timeline?.kept.isEmpty ?? true),
                         reset: { edit.resetCuts() }) {
            Text("Drag the ends of a part on the timeline, or use the playhead:").font(.caption).foregroundStyle(.secondary)
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
            KeptParts(edit: edit, enabled: true)
        }
        InspectorSection(title: "Speed", key: "trim.speed", changed: edit.timeline.speed != 1,
                         reset: { edit.setTimeline { $0.speed = 1 } }) {
            WrappingChips(items: [0.25, 0.5, 1, 1.5, 2, 4], label: \.speedLabel, selected: edit.timeline.speed) { value in
                edit.setTimeline { $0.speed = value }
            }
        }
        InspectorSection(title: "Fades and Sound", key: "trim.sound",
                         changed: edit.timeline.fadeIn != 0 || edit.timeline.fadeOut != 0 || edit.timeline.volume != 1,
                         reset: { edit.setTimeline { $0.fadeIn = 0; $0.fadeOut = 0; $0.volume = 1 } }) {
            EditSlider(label: "Fade In",
                       value: Binding(get: { edit.timeline.fadeIn }, set: { value in edit.setTimeline { $0.fadeIn = value } }),
                       range: 0 ... 5, format: { String(format: "%.1f s", $0) }, model: edit)
            EditSlider(label: "Fade Out", value: Binding(get: { edit.timeline.fadeOut },
                                                         set: { value in edit.setTimeline { $0.fadeOut = value } }),
                       range: 0 ... 5, format: { String(format: "%.1f s", $0) }, model: edit)
            EditSlider(label: "Volume", value: Binding(get: { min(edit.timeline.volume, 1) * 100 },
                                                       set: { value in edit.setTimeline { $0.volume = value / 100 } }),
                       range: 0 ... 100, neutral: 100, format: { String(format: "%.0f%%", $0) }, model: edit)
            Toggle("Mute", isOn: Binding(get: { edit.timeline.volume == 0 }, set: { on in edit.setTimeline { $0.volume = on ? 0 : 1 } }))
        }
        Button("Save Frame at Playhead") { edit.saveFrame() }
            .controlSize(.small)
            .disabled(edit.playingResult)
            .help("Saves the frame shown as a PNG, at full size")
    }
}

/// The parts of a video or audio file that are kept, each removable while there is more than one.
struct KeptParts: View {
    @Bindable var edit: EditModel
    let enabled: Bool

    var body: some View {
        let parts = edit.keptRanges
        ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
            HStack {
                Text("\(EditTimelineView.clock(part.start)) – \(EditTimelineView.clock(part.end))").font(.callout.monospacedDigit())
                Spacer()
                if parts.count > 1 {
                    QuietIconButton(title: "Remove this part", symbol: "minus.circle") { edit.removePart(part) }
                        .disabled(!enabled)
                }
            }
        }
    }
}

private extension Double {
    var speedLabel: String { self == 1 ? "Normal" : "\(formatted())×" }
}

extension Layer {
    /// The symbol for the layer's kind, in the list and the Add row.
    var symbol: String {
        switch kind {
        case .text: "textformat"
        case let .shape(shape): shape.kind.symbol
        case .image: "photo"
        }
    }
}

extension LayerShape.Kind {
    var symbol: String {
        switch self {
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        }
    }
}
