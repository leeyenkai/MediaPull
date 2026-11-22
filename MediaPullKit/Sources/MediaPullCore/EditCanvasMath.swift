import CoreGraphics
import Foundation

/// The arithmetic behind Edit/Frame's direct editing on the canvas (D-132): handles on turned layers, snapping to the
/// centre lines, and dragging the ends of kept parts. Points are on screen, y down; a positive turn is clockwise.
public enum CanvasMath {
    /// The corner signs, in the order handles are drawn: top left, top right, bottom left, bottom right.
    public static let cornerSigns: [(x: Double, y: Double)] = [(-1, -1), (1, -1), (-1, 1), (1, 1)]

    /// `point` turned by `degrees` about the origin.
    public static func turned(_ point: CGPoint, by degrees: Double) -> CGPoint {
        let angle = degrees * .pi / 180
        return CGPoint(x: point.x * cos(angle) - point.y * sin(angle), y: point.x * sin(angle) + point.y * cos(angle))
    }

    /// Where the corners of a box of `size` centred on `centre` are once it is turned by `degrees`, in `cornerSigns` order.
    public static func corners(centre: CGPoint, size: CGSize, degrees: Double) -> [CGPoint] {
        cornerSigns.map { sign in
            let offset = turned(CGPoint(x: sign.x * size.width / 2, y: sign.y * size.height / 2), by: degrees)
            return CGPoint(x: centre.x + offset.x, y: centre.y + offset.y)
        }
    }

    /// A turned box resized by dragging corner `corner` by `translation`: the opposite corner stays where it is.
    public static func resize(centre: CGPoint, size: CGSize, degrees: Double, corner: Int, by translation: CGSize,
                              minimum: CGFloat = 8) -> (centre: CGPoint, size: CGSize)
    {
        let sign = cornerSigns[max(0, min(3, corner))]
        let local = turned(CGPoint(x: translation.width, y: translation.height), by: -degrees)
        let width = max(minimum, size.width + sign.x * local.x)
        let height = max(minimum, size.height + sign.y * local.y)
        let shift = turned(CGPoint(x: sign.x * (width - size.width) / 2, y: sign.y * (height - size.height) / 2), by: degrees)
        return (CGPoint(x: centre.x + shift.x, y: centre.y + shift.y), CGSize(width: width, height: height))
    }

    /// `value` moved onto `target` when it is within `tolerance` of it, and whether it was.
    public static func snap(_ value: Double, to target: Double, within tolerance: Double) -> (value: Double, snapped: Bool) {
        abs(value - target) <= tolerance ? (target, true) : (value, false)
    }
}

public extension EditTimeline {
    /// The kept parts with one end of part `index` dragged to `seconds`. The end never passes the part before or after
    /// it, the file's start or end, or comes within `minimum` seconds of the part's other end, so parts stay in order.
    static func moving(_ parts: [TimeRange], index: Int, start: Bool, to seconds: Double, duration: Double,
                       minimum: Double = 0.1) -> [TimeRange]
    {
        guard parts.indices.contains(index), duration > 0 else { return parts }
        var out = parts
        let part = parts[index]
        if start {
            let lower = index > 0 ? parts[index - 1].end : 0
            out[index].start = min(max(seconds, lower), part.end - minimum)
            out[index].start = max(out[index].start, lower)
        } else {
            let upper = index < parts.count - 1 ? parts[index + 1].start : duration
            out[index].end = max(min(seconds, upper), part.start + minimum)
            out[index].end = min(out[index].end, upper)
        }
        return out
    }
}

public extension Frame {
    /// The most of the canvas any inset may take (R-4605).
    static let largestInset = 0.4

    /// How far the even border can go when the bottom has `extra` more: the bottom stops at `largestInset`, so the border
    /// stops with it, and the slider shows that instead of seeming stuck (D-132).
    static func borderRange(extra: Double) -> ClosedRange<Double> {
        0 ... max(0.01, largestInset - max(0, extra))
    }
}

public extension EditTemplate {
    /// The template whose layers `layers` are, unchanged (their ids aside); nil when the person added or changed any.
    /// Applying a template replaces the layers, so it asks first only when they are the person's own (D-132).
    static func template(of layers: [Layer]) -> EditTemplate? {
        func plain(_ list: [Layer]) -> [Layer] {
            list.map { layer in
                var copy = layer
                copy.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
                return copy
            }
        }
        let mine = plain(layers)
        return allCases.first { template in
            var recipe = EditRecipe(source: EditSource(path: "/", kind: .image))
            template.apply(to: &recipe)
            return plain(recipe.layers) == mine
        }
    }

    /// The person has text, shapes or pictures of their own that a template would replace.
    static func wouldReplaceOwnLayers(_ layers: [Layer]) -> Bool {
        !layers.isEmpty && template(of: layers) == nil
    }
}
