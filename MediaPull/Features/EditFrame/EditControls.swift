import AppKit
import MediaPullCore
import MediaPullEdit
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
/// in pixels (D-132), and snaps to the picture's edges, centre and the grid shown, by its edges and centre when moved
/// and by the corner or edge dragged while its shape is free (R-4613, D-133). One change per drag.
struct EditCropOverlay: View {
    @Bindable var model: EditModel
    let frame: CGRect
    @State private var start: UnitRect?
    @State private var guides: [SnapLine] = []

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
                    Text(verbatim: "\(Int(pixels.width)) × \(Int(pixels.height)) px")
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
                .gesture(DragGesture().onChanged { value in move(by: value.translation) }.onEnded { _ in end() })
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
            SnapGuideLines(lines: guides, frame: frame)
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
        guides = []
        model.endGesture()
    }

    private func set(_ rect: UnitRect) {
        model.change { $0.geometry.crop = rect }
    }

    private func points(_ rect: UnitRect) -> CGRect {
        EditGuides.points(CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height), in: frame)
    }

    private func move(by translation: CGSize) {
        let base = begin()
        let targets = EditGuides.targets(canvas: frame)
        let from = points(base)
        var moved = from.offsetBy(dx: translation.width, dy: translation.height)
        if EditGuides.snapping { moved = CanvasSnap.snap(moved, to: targets) }
        let rect = UnitRect(x: base.x + (moved.minX - from.minX) / frame.width, y: base.y + (moved.minY - from.minY) / frame.height,
                            width: base.width, height: base.height).clamped
        guides = CanvasSnap.lines(for: points(rect), targets: targets)
        set(rect)
    }

    /// `translation` of the point at `from` (a corner or an edge's middle) changed so the point lands on a guide.
    private func snapped(_ translation: CGSize, from: CGPoint) -> CGSize {
        let targets = EditGuides.targets(canvas: frame)
        var to = CGPoint(x: from.x + translation.width, y: from.y + translation.height)
        if EditGuides.snapping { to = CanvasSnap.snap(to, to: targets) }
        guides = CanvasSnap.lines(for: CGRect(origin: to, size: .zero), targets: targets)
        return CGSize(width: to.x - from.x, height: to.y - from.y)
    }

    private func resize(edge: Int, by translation: CGSize) {
        let base = begin()
        let box = points(base)
        let from = switch edge {
        case 0: CGPoint(x: box.minX, y: box.midY)
        case 1: CGPoint(x: box.maxX, y: box.midY)
        case 2: CGPoint(x: box.midX, y: box.minY)
        default: CGPoint(x: box.midX, y: box.maxY)
        }
        let translation = snapped(translation, from: from)
        guides = guides.filter { ($0.axis == .vertical) == (edge < 2) }
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
        var translation = translation
        if unitRatio == nil {
            let box = points(base)
            translation = snapped(translation, from: CGPoint(x: corner % 2 == 0 ? box.minX : box.maxX, y: corner < 2 ? box.minY : box.maxY))
        }
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
/// it is turned; others show a faint outline under the pointer. A dragged layer snaps to guides (R-4613, D-133): the
/// canvas's edges and centre, the photo in its frame, the other layers and the grid shown. A click on empty canvas lets
/// go of the layer; Delete removes it. Outside the Text tab a click on a layer opens it in Text; on the Frame tab the
/// photo is dragged to move it in its frame (R-4605).
struct EditLayerOverlay: View {
    @Bindable var model: EditModel
    let frame: CGRect
    /// Moving and resizing; off on tabs other than Text, where a click only chooses the layer.
    var editing = true
    @State private var start: Layer?
    @State private var hovered: UUID?
    @State private var guides: [SnapLine] = []
    /// The photo being moved in its frame: where it was when the drag began, and where it is now, in points.
    @State private var photoStart: (box: CGRect, picture: CGRect)?
    @State private var photoNow: CGRect?
    @State private var hoveringPhoto = false
    @FocusState private var focused: Bool
    @Environment(\.controlActiveState) private var activeState

    private var visibleLayers: [Layer] { model.recipe?.layers.filter { !$0.hidden } ?? [] }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { model.selectedLayer = nil }
                .accessibilityHidden(true)
            if model.tab == .frame, let placement = model.framePlacement, placement.canMove {
                photoArea(placement)
            }
            ForEach(visibleLayers) { layer in
                layerBox(layer)
            }
            SnapGuideLines(lines: guides, frame: frame)
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
        .onDisappear { if start != nil || photoStart != nil { end() } }
    }

    private func box(_ layer: Layer) -> CGRect {
        CGRect(x: frame.minX + (layer.x - layer.width / 2) * frame.width, y: frame.minY + (layer.y - layer.height / 2) * frame.height,
               width: layer.width * frame.width, height: layer.height * frame.height)
    }

    /// The upright box around a layer as drawn, turned or not: what it snaps by and what others snap to.
    private func bounds(_ layer: Layer) -> CGRect {
        let box = box(layer)
        return CanvasSnap.bounds(centre: CGPoint(x: box.midX, y: box.midY), size: box.size, degrees: layer.rotation)
    }

    /// What a layer other than `id` (or the photo, with no id) lines up with.
    private func targets(except id: UUID?) -> SnapTargets {
        let photo = model.framePlacement.map { EditGuides.points($0.photo, in: frame) }
        return EditGuides.targets(canvas: frame, photo: photo, others: visibleLayers.filter { $0.id != id }.map(bounds))
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
                    TwoToneOutline()
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
        let from = bounds(base)
        let targets = targets(except: layer.id)
        var moved = from.offsetBy(dx: translation.width, dy: translation.height)
        if EditGuides.snapping { moved = CanvasSnap.snap(moved, to: targets) }
        guides = CanvasSnap.lines(for: moved, targets: targets)
        update(layer.id) {
            $0.x = base.x + (moved.minX - from.minX) / frame.width
            $0.y = base.y + (moved.minY - from.minY) / frame.height
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
        var translation = translation
        // A layer that is not turned resizes onto guides by the corner dragged; a turned one's corner has no upright line.
        if base.rotation == 0 {
            let targets = targets(except: layer.id)
            let from = CanvasMath.corners(centre: CGPoint(x: start.midX, y: start.midY), size: start.size, degrees: 0)[corner]
            var to = CGPoint(x: from.x + translation.width, y: from.y + translation.height)
            if EditGuides.snapping { to = CanvasSnap.snap(to, to: targets) }
            translation = CGSize(width: to.x - from.x, height: to.y - from.y)
            guides = CanvasSnap.lines(for: CGRect(origin: to, size: .zero), targets: targets)
        }
        let resized = CanvasMath.resize(centre: CGPoint(x: start.midX, y: start.midY), size: start.size, degrees: base.rotation,
                                        corner: corner, by: translation)
        update(layer.id) {
            $0.width = resized.size.width / frame.width
            $0.height = resized.size.height / frame.height
            $0.x = (resized.centre.x - frame.minX) / frame.width
            $0.y = (resized.centre.y - frame.minY) / frame.height
        }
    }

    // MARK: The photo in its frame

    private func photoArea(_ placement: FramePlacement) -> some View {
        let photo = EditGuides.points(placement.photo, in: frame)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .overlay { if hoveringPhoto, photoStart == nil, activeState == .key { TwoToneOutline() } }
                .frame(width: photo.width, height: photo.height)
                .position(x: photo.midX, y: photo.midY)
                .onHover { hoveringPhoto = $0 }
                .gesture(DragGesture(minimumDistance: 2).onChanged { value in movePhoto(placement, by: value.translation) }
                    .onEnded { _ in end() })
                .accessibilityLabel("The photo in its frame")
                .accessibilityHint("Drag to move it in the frame")
            if let whole = photoNow {
                // The whole picture, also the parts the frame trims.
                Rectangle()
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                    .frame(width: whole.width, height: whole.height)
                    .position(x: whole.midX, y: whole.midY)
                    .allowsHitTesting(false)
            }
        }
    }

    private func movePhoto(_ placement: FramePlacement, by translation: CGSize) {
        if photoStart == nil {
            photoStart = (EditGuides.points(placement.box, in: frame), EditGuides.points(placement.picture, in: frame))
            model.selectedLayer = nil
            model.beginGesture()
        }
        guard let (box, picture) = photoStart else { return }
        let targets = EditGuides.targets(canvas: frame, photo: box, others: visibleLayers.map(bounds))
        var moved = picture.offsetBy(dx: translation.width, dy: translation.height)
        if EditGuides.snapping { moved = CanvasSnap.snap(moved, to: targets) }
        let x = FrameRenderer.position(edge: moved.minX, size: moved.width, low: box.minX, length: box.width)
        let y = FrameRenderer.position(edge: moved.minY, size: moved.height, low: box.minY, length: box.height)
        let now = CGRect(x: x.map { box.minX + (box.width - picture.width) * $0 } ?? picture.minX,
                         y: y.map { box.minY + (box.height - picture.height) * $0 } ?? picture.minY,
                         width: picture.width, height: picture.height)
        photoNow = now
        guides = CanvasSnap.lines(for: now, targets: targets, vertical: x != nil, horizontal: y != nil)
        model.change {
            if let x { $0.frame?.photoX = x }
            if let y { $0.frame?.photoY = y }
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
        photoStart = nil
        photoNow = nil
        guides = []
        model.endGesture()
    }

    private func update(_ id: UUID, _ body: (inout Layer) -> Void) {
        model.change { recipe in
            if let index = recipe.layers.firstIndex(where: { $0.id == id }) { body(&recipe.layers[index]) }
        }
    }
}

/// The outline under the pointer: two tones, so it shows on a dark photo and on a white border alike.
private struct TwoToneOutline: View {
    var body: some View {
        Rectangle().strokeBorder(Color.black.opacity(0.45), lineWidth: 2)
            .overlay(Rectangle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1))
    }
}
