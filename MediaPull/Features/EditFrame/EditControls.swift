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

/// A labelled slider with its value and a reset; a drag is one change (R-4602).
struct EditSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var neutral: Double = 0
    var step: Double?
    var format: (Double) -> String = { String(format: "%.0f", $0) }
    var model: EditModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.callout)
                Spacer()
                Text(format(value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button {
                    value = neutral
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.borderless)
                .disabled(value == neutral)
                .opacity(value == neutral ? 0.3 : 1)
                .accessibilityLabel("Reset \(label)")
                .help("Reset \(label)")
            }
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

/// The crop rectangle over the uncropped picture (R-4604): moved by dragging inside it, resized by its corners, keeping
/// its shape when one is chosen. One change per drag.
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
            ForEach(0 ..< 4, id: \.self) { corner in
                let point = CGPoint(x: corner % 2 == 0 ? rect.minX : rect.maxX, y: corner < 2 ? rect.minY : rect.maxY)
                Circle().fill(.white).frame(width: 14, height: 14).shadow(radius: 2)
                    .position(point)
                    .gesture(DragGesture().onChanged { value in resize(corner: corner, by: value.translation) }.onEnded { _ in end() })
                    .accessibilityHidden(true)
            }
        }
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

/// Layers' boxes over the canvas (R-4606): the selected one is moved by dragging and resized by its corner.
struct EditLayerOverlay: View {
    @Bindable var model: EditModel
    let frame: CGRect
    @State private var start: Layer?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.recipe?.layers.filter { !$0.hidden } ?? []) { layer in
                let box = CGRect(x: frame.minX + (layer.x - layer.width / 2) * frame.width,
                                 y: frame.minY + (layer.y - layer.height / 2) * frame.height,
                                 width: layer.width * frame.width, height: layer.height * frame.height)
                let selected = model.selectedLayer == layer.id
                Rectangle()
                    .strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.6),
                                  style: StrokeStyle(lineWidth: selected ? 1.5 : 1, dash: selected ? [] : [4, 3]))
                    .contentShape(Rectangle())
                    .frame(width: max(box.width, 8), height: max(box.height, 8))
                    .rotationEffect(.degrees(layer.rotation))
                    .position(x: box.midX, y: box.midY)
                    .onTapGesture { model.selectedLayer = layer.id }
                    .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                        model.selectedLayer = layer.id
                        let base = begin(layer)
                        update(layer.id) {
                            $0.x = base.x + value.translation.width / frame.width
                            $0.y = base.y + value.translation.height / frame.height
                        }
                    }.onEnded { _ in end() })
                    .accessibilityLabel(layer.label)
                if selected {
                    Circle().fill(Color.accentColor).frame(width: 12, height: 12)
                        .position(x: box.maxX, y: box.maxY)
                        .gesture(DragGesture().onChanged { value in
                            let base = begin(layer)
                            update(layer.id) {
                                $0.width = max(0.02, base.width + value.translation.width / frame.width)
                                $0.height = max(0.02, base.height + value.translation.height / frame.height)
                                $0.x = base.x - base.width / 2 + $0.width / 2
                                $0.y = base.y - base.height / 2 + $0.height / 2
                            }
                        }.onEnded { _ in end() })
                        .accessibilityHidden(true)
                }
            }
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
        model.endGesture()
    }

    private func update(_ id: UUID, _ body: (inout Layer) -> Void) {
        model.change { recipe in
            if let index = recipe.layers.firstIndex(where: { $0.id == id }) { body(&recipe.layers[index]) }
        }
    }
}
