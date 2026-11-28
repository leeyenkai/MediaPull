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

// MARK: Guides, snapping and rulers (R-4613, D-133)

/// The guide drawn over the canvas while placing things; never exported.
public enum CanvasGrid: String, Codable, Sendable, CaseIterable {
    case none, thirds, squares

    public var label: String {
        switch self {
        case .none: "None"
        case .thirds: "Thirds"
        case .squares: "Squares"
        }
    }

    /// The grid's lines across `canvas`, inside it (not its edges): thirds, or squares about the centre with eight
    /// across the shorter side.
    public func lines(in canvas: CGRect) -> (xs: [Double], ys: [Double]) {
        switch self {
        case .none:
            return ([], [])
        case .thirds:
            return ([1.0 / 3, 2.0 / 3].map { canvas.minX + canvas.width * $0 }, [1.0 / 3, 2.0 / 3].map { canvas.minY + canvas.height * $0 })
        case .squares:
            let cell = min(canvas.width, canvas.height) / 8
            guard cell > 1 else { return ([], []) }
            func across(_ low: Double, _ high: Double) -> [Double] {
                let middle = (low + high) / 2
                var out: [Double] = []
                var offset = cell
                while middle - offset > low + 0.5 {
                    out += [middle - offset, middle + offset]
                    offset += cell
                }
                return ([middle] + out).sorted()
            }
            return (across(canvas.minX, canvas.maxX), across(canvas.minY, canvas.maxY))
        }
    }
}

/// A line something was aligned to: vertical lines have an x, horizontal ones a y. Points on screen.
public struct SnapLine: Hashable, Sendable {
    public enum Axis: Sendable { case vertical, horizontal }
    public var axis: Axis
    public var position: Double

    public init(_ axis: Axis, _ position: Double) {
        self.axis = axis
        self.position = position
    }
}

/// Where things can be aligned: x positions of vertical lines and y positions of horizontal ones.
public struct SnapTargets: Sendable, Equatable {
    public var xs: [Double]
    public var ys: [Double]

    public init(xs: [Double] = [], ys: [Double] = []) {
        self.xs = xs
        self.ys = ys
    }
}

public enum CanvasSnap {
    /// How close, in points on screen, an edge or centre comes to a line before it snaps to it.
    public static let tolerance = 5.0

    /// The lines on `canvas` worth aligning to: its edges and centre lines, the photo's edges and centre when it is in
    /// a frame, the edges and centres of `others` (the other visible layers) and the lines of the grid shown.
    public static func targets(canvas: CGRect, photo: CGRect? = nil, others: [CGRect] = [], grid: CanvasGrid = .none) -> SnapTargets {
        var targets = SnapTargets(xs: [canvas.minX, canvas.midX, canvas.maxX], ys: [canvas.minY, canvas.midY, canvas.maxY])
        for box in (photo.map { [$0] } ?? []) + others where box.width > 0 || box.height > 0 {
            targets.xs += [box.minX, box.midX, box.maxX]
            targets.ys += [box.minY, box.midY, box.maxY]
        }
        let lines = grid.lines(in: canvas)
        targets.xs += lines.xs
        targets.ys += lines.ys
        return targets
    }

    /// The nearest of `anchors` to any of `targets` within `tolerance`: how far to move so they meet.
    static func nearest(_ anchors: [Double], _ targets: [Double], tolerance: Double) -> Double? {
        var best: Double?
        for anchor in anchors {
            for target in targets where abs(target - anchor) <= tolerance {
                if best == nil || abs(target - anchor) < abs(best!) { best = target - anchor }
            }
        }
        return best
    }

    /// `box` moved so its nearest edge or centre on each axis meets a target within `tolerance`; each axis apart.
    public static func snap(_ box: CGRect, to targets: SnapTargets, tolerance: Double = tolerance) -> CGRect {
        let dx = nearest([box.minX, box.midX, box.maxX], targets.xs, tolerance: tolerance) ?? 0
        let dy = nearest([box.minY, box.midY, box.maxY], targets.ys, tolerance: tolerance) ?? 0
        return box.offsetBy(dx: dx, dy: dy)
    }

    /// `point` moved onto the nearest target on each axis within `tolerance` (a corner being dragged).
    public static func snap(_ point: CGPoint, to targets: SnapTargets, tolerance: Double = tolerance) -> CGPoint {
        CGPoint(x: point.x + (nearest([point.x], targets.xs, tolerance: tolerance) ?? 0),
                y: point.y + (nearest([point.y], targets.ys, tolerance: tolerance) ?? 0))
    }

    /// The lines `box` sits on, to draw: each target an edge or centre of it meets within half a point. An axis the box
    /// cannot move along is left out.
    public static func lines(for box: CGRect, targets: SnapTargets, vertical: Bool = true, horizontal: Bool = true) -> [SnapLine] {
        func meeting(_ anchors: [Double], _ list: [Double]) -> [Double] {
            Array(Set(list.filter { target in anchors.contains { abs($0 - target) < 0.5 } })).sorted()
        }
        var out: [SnapLine] = []
        if vertical { out += meeting([box.minX, box.midX, box.maxX], targets.xs).map { SnapLine(.vertical, $0) } }
        if horizontal { out += meeting([box.minY, box.midY, box.maxY], targets.ys).map { SnapLine(.horizontal, $0) } }
        return out
    }

    /// The upright box around a box of `size` centred on `centre` turned by `degrees`: what a turned layer snaps by.
    public static func bounds(centre: CGPoint, size: CGSize, degrees: Double) -> CGRect {
        let corners = CanvasMath.corners(centre: centre, size: size, degrees: degrees)
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}

/// The marks on a ruler (R-4613): a labelled step in pixels that leaves room for its label, and finer ticks between.
public enum RulerScale {
    /// The smallest step of 1, 2 or 5 times a power of ten whose marks are at least `spacing` points apart, with how
    /// many parts its ticks divide it into.
    public static func step(pointsPerPixel: Double, spacing: Double = 56) -> (major: Double, divisions: Int) {
        guard pointsPerPixel > 0, pointsPerPixel.isFinite else { return (1, 1) }
        var power = 1.0
        while true {
            for factor in [1.0, 2.0, 5.0] {
                let major = factor * power
                if major * pointsPerPixel >= spacing {
                    let divisions = factor == 2 ? 4 : (major * pointsPerPixel / 10 >= 6 ? 10 : 5)
                    return (major, major >= Double(divisions) ? divisions : Int(max(1, major)))
                }
            }
            power *= 10
            if power > 1e9 { return (power, 1) }
        }
    }
}
