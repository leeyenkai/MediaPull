import AppKit
import MediaPullCore
import SwiftUI

extension EditModel {
    /// A binding to a part of the recipe. Each set is one change ⌘Z takes back, except while a slider is dragged
    /// (`beginGesture` … `endGesture`), which is one change in all.
    func value<T: Equatable>(_ path: WritableKeyPath<EditRecipe, T>, fallback: T) -> Binding<T> {
        Binding(
            get: { [weak self] in self?.recipe?[keyPath: path] ?? fallback },
            set: { [weak self] value in self?.change { $0[keyPath: path] = value } }
        )
    }

    /// A binding to a part of the frame; safe while the frame is taken away under it (audit B2-1).
    func frameValue<T: Equatable>(_ path: WritableKeyPath<Frame, T>, fallback: T) -> Binding<T> {
        Binding(
            get: { [weak self] in self?.recipe?.frame?[keyPath: path] ?? fallback },
            set: { [weak self] value in self?.change { $0.frame?[keyPath: path] = value } }
        )
    }

    /// The selected layer, as a binding; nil when none is selected.
    func layer(_ id: UUID?) -> Binding<Layer>? {
        guard let id, let recipe, recipe.layers.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in self?.recipe?.layers.first { $0.id == id } ?? Layer(kind: .shape(LayerShape())) },
            set: { [weak self] layer in
                self?.change { recipe in
                    if let index = recipe.layers.firstIndex(where: { $0.id == id }) { recipe.layers[index] = layer }
                }
            }
        )
    }
}

/// A labelled slider with its value; a drag is one change (R-4602). Its reset shows only once it is changed, and a
/// double-click on its name or value resets it too (R-4603, D-132).
struct EditSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var neutral: Double = 0
    var step: Double?
    var format: (Double) -> String = { String(format: "%.0f", $0) }
    var model: EditModel

    private var changed: Bool { abs(value - neutral) > 0.0001 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label).font(.callout)
                Spacer()
                Text(format(value)).font(.caption.monospacedDigit()).foregroundStyle(changed ? .primary : .secondary)
                if changed {
                    QuietIconButton(title: "Reset \(label)", symbol: "arrow.uturn.backward", size: 10) { value = neutral }
                } else {
                    // Keeps the row the same height whether the reset shows or not.
                    Color.clear.frame(width: 22, height: 20).accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if changed { value = neutral } }
            .help(changed ? "Double-click to reset \(label)" : "")
            Slider(value: $value, in: range) { editing in
                if editing { model.beginGesture() } else { model.endGesture() }
            }
            .controlSize(.small)
            .accessibilityLabel(label)
        }
    }
}

extension EditColor {
    var color: Color {
        Color(nsColor: NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha))
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(red: Double(ns.redComponent), green: Double(ns.greenComponent), blue: Double(ns.blueComponent),
                  alpha: Double(ns.alphaComponent))
    }
}

/// Binds a colour picker to an `EditColor`.
func colorBinding(_ binding: Binding<EditColor>) -> Binding<Color> {
    Binding(get: { binding.wrappedValue.color }, set: { binding.wrappedValue = EditColor($0) })
}

/// Where a picture of `size` sits when fitted into `bounds`, centred.
func fittedRect(_ size: CGSize, in bounds: CGSize) -> CGRect {
    guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
    let scale = min(bounds.width / size.width, bounds.height / size.height)
    let fitted = CGSize(width: size.width * scale, height: size.height * scale)
    return CGRect(x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
}

/// The crop rectangle over the uncropped picture (R-4604): moved by dragging inside it, resized by its corners (and its
/// edges when its shape is free), keeping its shape when one is chosen. While dragging it shows the thirds and its size
/// in pixels (D-132). One change per drag.
struct EditCropOverlay: View {
    @Bindable var model: EditModel
    let frame: CGRect
    @State private var start: UnitRect?

    private var crop: UnitRect { model.recipe?.geometry.crop ?? .whole }

    /// The crop's width over height in units, from the chosen shape and the picture's.
    private var unitRatio: Double? {
        guard let aspect = model.recipe?.geometry.aspect, let ratio = aspect.ratio(original: model.cropRatio) else { return nil }
        return ratio / model.cropRatio
    }

    var body: some View {
        let rect = CGRect(x: frame.minX + crop.x * frame.width, y: frame.minY + crop.y * frame.height,
                          width: crop.width * frame.width, height: crop.height * frame.height)
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(frame)
                path.addRect(rect)
            }
            .fill(.black.opacity(0.5), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            if start != nil {
                ThirdsGrid()
                    .stroke(.white.opacity(0.55), lineWidth: 0.75)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
                if let pixels = model.cropPixels {
                    Text("\(Int(pixels.width)) × \(Int(pixels.height)) px")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .position(x: rect.midX, y: max(frame.minY + 12, rect.minY + 14))
                        .allowsHitTesting(false)
                }
            }
            Rectangle()
                .strokeBorder(.white, lineWidth: 1.5)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .contentShape(Rectangle())
                .gesture(DragGesture().onChanged { value in
                    let base = begin()
                    set(UnitRect(x: base.x + value.translation.width / frame.width, y: base.y + value.translation.height / frame.height,
                                 width: base.width, height: base.height).clamped)
                }.onEnded { _ in end() })
            if unitRatio == nil {
                // Edges, for a free crop: left, right, top, bottom.
                ForEach(0 ..< 4, id: \.self) { edge in
                    let point = switch edge {
                    case 0: CGPoint(x: rect.minX, y: rect.midY)
                    case 1: CGPoint(x: rect.maxX, y: rect.midY)
                    case 2: CGPoint(x: rect.midX, y: rect.minY)
                    default: CGPoint(x: rect.midX, y: rect.maxY)
                    }
                    Capsule().fill(.white)
                        .frame(width: edge < 2 ? 5 : 22, height: edge < 2 ? 22 : 5)
                        .shadow(radius: 2)
                        .position(point)
                        .gesture(DragGesture().onChanged { value in resize(edge: edge, by: value.translation) }.onEnded { _ in end() })
                        .accessibilityHidden(true)
                }
            }
            ForEach(0 ..< 4, id: \.self) { corner in
                let point = CGPoint(x: corner % 2 == 0 ? rect.minX : rect.maxX, y: corner < 2 ? rect.minY : rect.maxY)
                Circle().fill(.white).frame(width: 14, height: 14).shadow(radius: 2)
                    .position(point)
                    .gesture(DragGesture().onChanged { value in resize(corner: corner, by: value.translation) }.onEnded { _ in end() })
                    .accessibilityHidden(true)
            }
        }
        // A drag cut short by the overlay going away still ends as one change.
        .onDisappear { if start != nil { end() } }
    }

    private func begin() -> UnitRect {
        if start == nil {
            start = crop
            model.beginGesture()
        }
        return start ?? crop
    }

    private func end() {
        start = nil
        model.endGesture()
    }

    private func set(_ rect: UnitRect) {
        model.change { $0.geometry.crop = rect }
    }

    private func resize(edge: Int, by translation: CGSize) {
        let base = begin()
        let dx = translation.width / frame.width, dy = translation.height / frame.height
        var left = base.x, top = base.y, right = base.x + base.width, bottom = base.y + base.height
        switch edge {
        case 0: left = min(left + dx, right - 0.02)
        case 1: right = max(right + dx, left + 0.02)
        case 2: top = min(top + dy, bottom - 0.02)
        default: bottom = max(bottom + dy, top + 0.02)
        }
        set(UnitRect(x: left, y: top, width: right - left, height: bottom - top).clamped)
    }

    private func resize(corner: Int, by translation: CGSize) {
        let base = begin()
        let dx = translation.width / frame.width, dy = translation.height / frame.height
        var left = base.x, top = base.y, right = base.x + base.width, bottom = base.y + base.height
        if corner % 2 == 0 { left += dx } else { right += dx }
        if corner < 2 { top += dy } else { bottom += dy }
        var width = max(0.02, right - left), height = max(0.02, bottom - top)
        if let ratio = unitRatio {
            // The shape is kept: the width stays inside the picture (and short enough for its height to), and the
            // height follows it.
            width = min(width, 1, ratio)
            height = width / ratio
        }
        let x = corner % 2 == 0 ? base.x + base.width - width : base.x
        let y = corner < 2 ? base.y + base.height - height : base.y
        set(UnitRect(x: x, y: y, width: width, height: height).clamped)
    }
}

/// Layers over the canvas (R-4606, D-132). Only the selected layer is outlined, with a handle at each corner however
/// it is turned; others show a faint outline under the pointer. A layer snaps to the canvas's centre lines while
/// dragged. A click on empty canvas lets go of the layer; Delete removes it. Outside the Text tab a click on a layer
/// opens it in Text.
struct EditLayerOverlay: View {
    @Bindable var model: EditModel
    let frame: CGRect
    /// Moving and resizing; off on tabs other than Text, where a click only chooses the layer.
    var editing = true
    @State private var start: Layer?
    @State private var hovered: UUID?
    @State private var guides: (vertical: Bool, horizontal: Bool) = (false, false)
    @FocusState private var focused: Bool
    @Environment(\.controlActiveState) private var activeState

    /// How close, in points, a layer's centre comes to a centre line before it snaps to it.
    static let snapDistance: CGFloat = 4

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { model.selectedLayer = nil }
                .accessibilityHidden(true)
            ForEach(model.recipe?.layers.filter { !$0.hidden } ?? []) { layer in
                layerBox(layer)
            }
            if guides.vertical {
                Rectangle().fill(Color.accentColor).frame(width: 1, height: frame.height)
                    .position(x: frame.midX, y: frame.midY).allowsHitTesting(false)
            }
            if guides.horizontal {
                Rectangle().fill(Color.accentColor).frame(width: frame.width, height: 1)
                    .position(x: frame.midX, y: frame.midY).allowsHitTesting(false)
            }
            if editing, let layer = model.recipe?.layers.first(where: { $0.id == model.selectedLayer && !$0.hidden }) {
                handles(layer)
            }
        }
        // Out of the key loop while the section is not shown, so Delete never acts out of sight.
        .focusable(editing && model.window?.section == .edit)
        .focusEffectDisabled()
        .focused($focused)
        .onDeleteCommand { if editing { model.removeSelectedLayer() } }
        // A drag cut short by the overlay going away (Before, a zoom) still ends as one change.
        .onDisappear { if start != nil { end() } }
    }

    private func box(_ layer: Layer) -> CGRect {
        CGRect(x: frame.minX + (layer.x - layer.width / 2) * frame.width, y: frame.minY + (layer.y - layer.height / 2) * frame.height,
               width: layer.width * frame.width, height: layer.height * frame.height)
    }

    private func layerBox(_ layer: Layer) -> some View {
        let box = box(layer)
        let selected = editing && model.selectedLayer == layer.id
        // Only in the window in front: an inactive window can be told the pointer is over a layer when it is not.
        let hovering = hovered == layer.id && activeState == .key
        return Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .overlay {
                if selected {
                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 1.5)
                } else if hovering {
                    // Two tones, so it shows on a dark photo and on a white border alike.
                    Rectangle().strokeBorder(Color.black.opacity(0.45), lineWidth: 2)
                        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1))
                }
            }
            .frame(width: max(box.width, 8), height: max(box.height, 8))
            .rotationEffect(.degrees(layer.rotation))
            .position(x: box.midX, y: box.midY)
            .onHover { inside in
                if inside { hovered = layer.id } else if hovered == layer.id { hovered = nil }
            }
            .onTapGesture(count: 2) {
                choose(layer)
                if case .text = layer.kind { model.focusTextPending = true }
            }
            .onTapGesture { choose(layer) }
            .gesture(editing ? DragGesture(minimumDistance: 2).onChanged { value in move(layer, by: value.translation) }
                .onEnded { _ in end() } : nil)
            .accessibilityLabel(layer.label)
            .accessibilityAddTraits(.isButton)
    }

    private func choose(_ layer: Layer) {
        model.selectedLayer = layer.id
        if model.tab != .text { model.tab = .text }
        focused = true
    }

    private func move(_ layer: Layer, by translation: CGSize) {
        model.selectedLayer = layer.id
        focused = true
        let base = begin(layer)
        let centre = CGPoint(x: frame.minX + base.x * frame.width + translation.width,
                             y: frame.minY + base.y * frame.height + translation.height)
        let x = CanvasMath.snap(centre.x, to: frame.midX, within: Self.snapDistance)
        let y = CanvasMath.snap(centre.y, to: frame.midY, within: Self.snapDistance)
        guides = (x.snapped, y.snapped)
        update(layer.id) {
            $0.x = (x.value - frame.minX) / frame.width
            $0.y = (y.value - frame.minY) / frame.height
        }
    }

    private func handles(_ layer: Layer) -> some View {
        let box = box(layer)
        let corners = CanvasMath.corners(centre: CGPoint(x: box.midX, y: box.midY), size: box.size, degrees: layer.rotation)
        return ForEach(0 ..< 4, id: \.self) { corner in
            Circle().fill(.white)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                .frame(width: 11, height: 11)
                .shadow(color: .black.opacity(0.3), radius: 1.5)
                .position(corners[corner])
                .gesture(DragGesture().onChanged { value in resize(layer, corner: corner, by: value.translation) }.onEnded { _ in end() })
                .accessibilityHidden(true)
        }
    }

    private func resize(_ layer: Layer, corner: Int, by translation: CGSize) {
        let base = begin(layer)
        let start = box(base)
        let resized = CanvasMath.resize(centre: CGPoint(x: start.midX, y: start.midY), size: start.size, degrees: base.rotation,
                                        corner: corner, by: translation)
        update(layer.id) {
            $0.width = resized.size.width / frame.width
            $0.height = resized.size.height / frame.height
            $0.x = (resized.centre.x - frame.minX) / frame.width
            $0.y = (resized.centre.y - frame.minY) / frame.height
        }
    }

    private func begin(_ layer: Layer) -> Layer {
        if start?.id != layer.id {
            start = layer
            model.beginGesture()
        }
        return start ?? layer
    }

    private func end() {
        start = nil
        guides = (false, false)
        model.endGesture()
    }

    private func update(_ id: UUID, _ body: (inout Layer) -> Void) {
        model.change { recipe in
            if let index = recipe.layers.firstIndex(where: { $0.id == id }) { body(&recipe.layers[index]) }
        }
    }
}
