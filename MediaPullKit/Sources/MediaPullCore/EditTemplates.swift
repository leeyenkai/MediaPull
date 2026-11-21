import Foundation

/// Starting frames and layers (R-4605): each sets the frame and replaces the layers, which the person then edits.
public enum EditTemplate: String, CaseIterable, Sendable {
    case galleryBorder, polaroid, poster, captionBelow, centredTitle

    public var label: String {
        switch self {
        case .galleryBorder: "Gallery Border"
        case .polaroid: "Polaroid"
        case .poster: "Poster"
        case .captionBelow: "Caption Below"
        case .centredTitle: "Centred Title"
        }
    }

    static let ink = EditColor(red: 0.12, green: 0.12, blue: 0.12)
    static let grey = EditColor(red: 0.45, green: 0.45, blue: 0.47)

    static func text(_ string: String, family: String, face: String? = nil, size: Double, color: EditColor,
                     alignment: TextStyle.Alignment = .left, x: Double, y: Double, width: Double, height: Double) -> Layer
    {
        var style = TextStyle(text: string)
        style.family = family
        style.face = face
        style.size = size
        style.color = color
        style.alignment = alignment
        var layer = Layer(kind: .text(style))
        layer.x = x
        layer.y = y
        layer.width = width
        layer.height = height
        return layer
    }

    public func apply(to recipe: inout EditRecipe) {
        var frame = Frame()
        switch self {
        case .galleryBorder:
            (frame.top, frame.left, frame.right, frame.bottom) = (0.06, 0.06, 0.06, 0.06)
            recipe.layers = []
        case .polaroid:
            (frame.top, frame.left, frame.right, frame.bottom) = (0.05, 0.05, 0.05, 0.24)
            recipe.layers = [Self.text("A day to remember", family: "Bradley Hand", face: "Bold", size: 0.035, color: Self.ink,
                                       alignment: .center, x: 0.5, y: 0.9, width: 0.8, height: 0.07)]
        case .poster:
            // A tall poster: big type over the top of the photo, the title over its lower edge, a date and credits below.
            frame.shape = .portrait23
            frame.fill = true
            (frame.top, frame.left, frame.right, frame.bottom) = (0.05, 0.05, 0.05, 0.36)
            var top = Self.text("First Name\nSecond Name", family: "Helvetica Neue", face: "Bold", size: 0.055,
                                color: EditColor(red: 1, green: 1, blue: 1, alpha: 0.85), x: 0.36, y: 0.12, width: 0.6, height: 0.16)
            if case var .text(style) = top.kind {
                style.lineHeight = 1.05
                style.tracking = -0.02
                top.kind = .text(style)
            }
            recipe.layers = [
                top,
                Self.text("A Film by Someone", family: "Helvetica Neue", size: 0.016, color: .white, x: 0.33, y: 0.62, width: 0.5,
                          height: 0.03),
                Self.text("The Title", family: "Helvetica Neue", face: "Bold", size: 0.06, color: .white, x: 0.39, y: 0.69,
                          width: 0.62, height: 0.09),
                Self.text("December 22", family: "Snell Roundhand", size: 0.022, color: Self.ink, alignment: .right, x: 0.78, y: 0.83,
                          width: 0.36, height: 0.05),
                Self.text("Music by Someone   Produced by Someone   Written by Someone   Directed by Someone", family: "Helvetica Neue",
                          face: "Light", size: 0.009, color: Self.grey, alignment: .center, x: 0.5, y: 0.92, width: 0.9, height: 0.05),
            ]
        case .captionBelow:
            (frame.top, frame.left, frame.right, frame.bottom) = (0.04, 0.04, 0.04, 0.2)
            recipe.layers = [Self.text("Caption", family: "Helvetica Neue", face: "Medium", size: 0.03, color: Self.ink,
                                       x: 0.5, y: 0.9, width: 0.9, height: 0.06)]
        case .centredTitle:
            recipe.frame = nil
            var title = Self.text("The Title", family: "Helvetica Neue", face: "Bold", size: 0.06, color: .white, alignment: .center,
                                  x: 0.5, y: 0.5, width: 0.8, height: 0.12)
            if case var .text(style) = title.kind {
                style.shadow = true
                title.kind = .text(style)
            }
            recipe.layers = [title]
            return
        }
        recipe.frame = frame
    }
}
