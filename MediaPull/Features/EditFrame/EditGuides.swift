import AppKit
import MediaPullCore
import SwiftUI

/// Guides on the Edit/Frame canvas (R-4613, D-133): the grid, the lines a drag snaps to, the rulers and the bar that
/// chooses them. None of it is ever exported.
enum EditGuides {
    private static var preferences: Preferences { AppModel.shared.preferences }

    /// Snapping is on and ⌘ is not held, which places freely for the drag.
    static var snapping: Bool { preferences.editSnap && !NSEvent.modifierFlags.contains(.command) }

    static var grid: CanvasGrid { preferences.editGrid }

    /// The lines worth aligning to on `canvas`, in points on screen.
    static func targets(canvas: CGRect, photo: CGRect? = nil, others: [CGRect] = []) -> SnapTargets {
        CanvasSnap.targets(canvas: canvas, photo: photo, others: others, grid: grid)
    }

    /// `rect`, in units of `frame`, in points on screen.
    static func points(_ rect: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + rect.minX * frame.width, y: frame.minY + rect.minY * frame.height, width: rect.width * frame.width,
               height: rect.height * frame.height)
    }
}

/// The grid chosen, dotted in two tones so it shows on a dark photo and a white border alike.
struct GuideGrid: View {
    let grid: CanvasGrid
    let frame: CGRect

    var body: some View {
        let lines = grid.lines(in: frame)
        Canvas { context, _ in
            var path = Path()
            for x in lines.xs {
                path.move(to: CGPoint(x: x, y: frame.minY))
                path.addLine(to: CGPoint(x: x, y: frame.maxY))
            }
            for y in lines.ys {
                path.move(to: CGPoint(x: frame.minX, y: y))
                path.addLine(to: CGPoint(x: frame.maxX, y: y))
            }
            context.stroke(path, with: .color(.black.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
            context.stroke(path, with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [1, 3], dashPhase: 2))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The lines a dragged layer, photo or crop meets, dashed across the canvas.
struct SnapGuideLines: View {
    let lines: [SnapLine]
    let frame: CGRect

    var body: some View {
        Canvas { context, _ in
            var path = Path()
            for line in lines {
                switch line.axis {
                case .vertical:
                    path.move(to: CGPoint(x: line.position, y: frame.minY))
                    path.addLine(to: CGPoint(x: line.position, y: frame.maxY))
                case .horizontal:
                    path.move(to: CGPoint(x: frame.minX, y: line.position))
                    path.addLine(to: CGPoint(x: frame.maxX, y: line.position))
                }
            }
            context.stroke(path, with: .color(.white.opacity(0.7)), lineWidth: 2.5)
            context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A ruler along the top or the left of the canvas, counting the canvas's pixels; `highlight` marks the selected
/// layer's, the photo's or the crop's span.
struct CanvasRuler: View {
    enum Axis { case horizontal, vertical }

    static let thickness: CGFloat = 18

    let axis: Axis
    /// Where the canvas starts along the ruler and how long it is, in the ruler's points.
    let start: CGFloat
    let length: CGFloat
    /// The canvas's length in pixels.
    let pixels: CGFloat
    var highlight: ClosedRange<CGFloat>?

    var body: some View {
        // Read here: the drawing runs off the main actor.
        let horizontal = axis == .horizontal
        let (start, length, pixels, highlight) = (start, length, pixels, highlight)
        Canvas { context, size in
            let along = horizontal ? size.width : size.height
            let across = horizontal ? size.height : size.width
            func span(_ low: CGFloat, _ high: CGFloat) -> CGRect {
                horizontal ? CGRect(x: low, y: 0, width: high - low, height: across)
                    : CGRect(x: 0, y: low, width: across, height: high - low)
            }
            context.fill(Path(span(max(0, start), min(along, start + length))), with: .color(.primary.opacity(0.05)))
            if let highlight {
                context.fill(Path(span(highlight.lowerBound, highlight.upperBound)), with: .color(.accentColor.opacity(0.22)))
            }
            guard pixels > 0, length > 0 else { return }
            let scale = Double(length / pixels)
            let step = RulerScale.step(pointsPerPixel: scale)
            let minor = step.major / Double(step.divisions)
            let low = max(0, Double(-start) / scale), high = min(Double(pixels), Double(along - start) / scale)
            guard high >= low else { return }
            var ticks = Path()
            var index = (low / minor).rounded(.up)
            while index * minor <= high + 1e-6 {
                let value = index * minor
                let position = start + CGFloat(value * scale)
                let part = Int(index.rounded()) % step.divisions
                let tick: CGFloat = part == 0 ? across - 2 : (step.divisions % 2 == 0 && part == step.divisions / 2 ? 6 : 3)
                if horizontal {
                    ticks.move(to: CGPoint(x: position, y: across))
                    ticks.addLine(to: CGPoint(x: position, y: across - tick))
                } else {
                    ticks.move(to: CGPoint(x: across, y: position))
                    ticks.addLine(to: CGPoint(x: across - tick, y: position))
                }
                // A label with no room before the ruler's end is left out rather than cut.
                if part == 0, position + 26 <= along {
                    let label = Text(verbatim: "\(Int(value.rounded()))").font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                    if horizontal {
                        context.draw(label, at: CGPoint(x: position + 3, y: 1), anchor: .topLeading)
                    } else {
                        // Read from the bottom up, just after the tick.
                        var turned = context
                        turned.translateBy(x: 1, y: position + 3)
                        turned.rotate(by: .degrees(-90))
                        turned.draw(label, at: .zero, anchor: .topTrailing)
                    }
                }
                index += 1
            }
            context.stroke(ticks, with: .color(.secondary.opacity(0.8)), lineWidth: 1)
        }
        .frame(width: axis == .vertical ? Self.thickness : nil, height: axis == .horizontal ? Self.thickness : nil)
        .background(PaneSurface.tools.color)
        .overlay(alignment: axis == .horizontal ? .bottom : .trailing) {
            Rectangle().fill(.separator).frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// Under the Canvas (R-4613): the grid, the rulers and snapping, on screen and remembered.
struct EditGuideBar: View {
    @Bindable var edit: EditModel
    @Bindable var preferences: Preferences

    var body: some View {
        HStack(spacing: 8) {
            Text("Grid").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                ForEach(CanvasGrid.allCases, id: \.self) { grid in
                    ValueChip(title: grid.label, selected: preferences.editGrid == grid) { preferences.editGrid = grid }
                }
            }
            .help("A guide over the canvas; it is never exported")
            ValueChip(title: "Rulers", selected: preferences.editRulers) { preferences.editRulers.toggle() }
                .help("Rulers at the top and left, in the pixels Export writes")
            ValueChip(title: "Snap", selected: preferences.editSnap) { preferences.editSnap.toggle() }
                .help("Snap to the canvas's edges and centre, the photo, other layers and the grid; hold ⌘ while dragging to place freely")
            Spacer(minLength: 4)
            Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).layoutPriority(-1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var hint: String {
        if edit.tab == .frame, edit.framePlacement?.canMove == true { return "Drag the photo to move it in the frame." }
        return preferences.editSnap ? "Hold ⌘ while dragging to place freely." : ""
    }
}
