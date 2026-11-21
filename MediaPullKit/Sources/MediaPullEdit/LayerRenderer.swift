import CoreGraphics
import CoreText
import Foundation
import ImageIO
import MediaPullCore

/// Draws a recipe's layers (R-4606) for a canvas of a given size: text with Core Text, shapes and pictures with Core
/// Graphics, all in units of the canvas, so the canvas and an export of any size match.
public enum LayerRenderer {
    /// A transparent bitmap of `size` with the visible layers drawn in order.
    public static func image(_ layers: [Layer], canvas size: CGSize) -> CGImage? {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width > 0, height > 0, width <= 30000, height <= 30000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Top-left origin, as the recipe's units are.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        for layer in layers where !layer.hidden && layer.opacity > 0 {
            draw(layer, in: context, canvas: CGSize(width: width, height: height))
        }
        return context.makeImage()
    }

    /// The layer's rectangle on a canvas of `size`, origin top left, before rotation.
    public static func rect(of layer: Layer, canvas size: CGSize) -> CGRect {
        CGRect(x: (layer.x - layer.width / 2) * size.width, y: (layer.y - layer.height / 2) * size.height,
               width: layer.width * size.width, height: layer.height * size.height)
    }

    static func draw(_ layer: Layer, in context: CGContext, canvas: CGSize) {
        let box = rect(of: layer, canvas: canvas)
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(min(max(layer.opacity, 0), 1))
        context.translateBy(x: box.midX, y: box.midY)
        context.rotate(by: layer.rotation * .pi / 180)
        let local = CGRect(x: -box.width / 2, y: -box.height / 2, width: box.width, height: box.height)
        switch layer.kind {
        case let .text(style): drawText(style, in: local, context: context, canvas: canvas)
        case let .shape(style): drawShape(style, in: local, context: context, canvas: canvas)
        case let .image(path): drawPicture(path, in: local, context: context)
        }
    }

    // MARK: Text

    /// The font for a style, sized so a capital letter is `size` of the canvas height; nil `missing` when the family and
    /// face were found, else the font drawn instead (R-4607).
    public static func font(_ style: TextStyle, canvasHeight: CGFloat) -> (font: CTFont, missing: Bool) {
        var attributes: [CFString: Any] = [kCTFontFamilyNameAttribute: style.family]
        if let face = style.face { attributes[kCTFontStyleNameAttribute] = face }
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        var font = CTFontCreateWithFontDescriptor(descriptor, 100, nil)
        let family = (CTFontCopyFamilyName(font) as String).caseInsensitiveCompare(style.family) == .orderedSame
        // A face the family no longer has is drawn in the family's regular face and said, as a missing family is
        // (R-4607, audit 2026-11-21-6, B6-m6).
        let faceFound = style.face.map { face in
            (CTFontCopyName(font, kCTFontStyleNameKey) as String?)?.caseInsensitiveCompare(face) == .orderedSame
        } ?? true
        let found = family && faceFound
        if !family { font = CTFontCreateUIFontForLanguage(.system, 100, nil) ?? font }
        let capHeight = max(CTFontGetCapHeight(font), 1)
        let pointSize = max(1, style.size * canvasHeight * 100 / capHeight)
        return (CTFontCreateCopyWithAttributes(font, pointSize, nil, nil), !found)
    }

    public static func attributed(_ style: TextStyle, canvasHeight: CGFloat) -> NSAttributedString {
        let font = font(style, canvasHeight: canvasHeight).font
        let size = CTFontGetSize(font)
        var alignment: CTTextAlignment = switch style.alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        var lineHeight = CGFloat(max(style.lineHeight, 0.5)) * size
        let settings = [
            CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: &alignment),
            CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: &lineHeight),
            CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: &lineHeight),
        ]
        let paragraph = CTParagraphStyleCreate(settings, settings.count)
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(style.color),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
            NSAttributedString.Key(kCTKernAttributeName as String): style.tracking * size,
        ]
        if let outline = style.outline {
            // Negative: filled and outlined.
            attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -4.0
            attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = cgColor(outline)
        }
        let text = style.uppercase ? style.text.uppercased() : style.text
        return NSAttributedString(string: text, attributes: attributes)
    }

    static func drawText(_ style: TextStyle, in rect: CGRect, context: CGContext, canvas: CGSize) {
        let string = attributed(style, canvasHeight: canvas.height)
        let setter = CTFramesetterCreateWithAttributedString(string)
        // Text is never cut off: the frame is as tall as the text needs.
        let needed = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                                  CGSize(width: rect.width, height: .greatestFiniteMagnitude), nil)
        let height = max(rect.height, ceil(needed.height))
        let frameRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
        context.saveGState()
        if style.shadow {
            // Shadow offsets are in the bitmap's own space, where y points up: a negative height falls down.
            context.setShadow(offset: CGSize(width: 0, height: -canvas.height * 0.002), blur: canvas.height * 0.006,
                              color: CGColor(gray: 0, alpha: 0.55))
        }
        // Core Text draws with its origin bottom left: flip within the box.
        context.translateBy(x: 0, y: frameRect.minY + frameRect.maxY)
        context.scaleBy(x: 1, y: -1)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: frameRect, transform: nil), nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    // MARK: Shapes and pictures

    static func drawShape(_ style: LayerShape, in rect: CGRect, context: CGContext, canvas: CGSize) {
        let color = cgColor(style.color)
        let line = max(1, style.lineWidth * min(canvas.width, canvas.height))
        context.setFillColor(color)
        context.setStrokeColor(color)
        context.setLineWidth(line)
        switch style.kind {
        case .rectangle:
            if style.filled { context.fill(rect) } else { context.stroke(rect.insetBy(dx: line / 2, dy: line / 2)) }
        case .ellipse:
            if style.filled { context.fillEllipse(in: rect) } else { context.strokeEllipse(in: rect.insetBy(dx: line / 2, dy: line / 2)) }
        case .line:
            context.setLineCap(.round)
            context.strokeLineSegments(between: [CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY)])
        }
    }

    static func drawPicture(_ path: String, in rect: CGRect, context: CGContext) {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let picture = CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: Int(max(rect.width, rect.height).rounded(.up)),
              ] as CFDictionary)
        else { return }
        let scale = min(rect.width / CGFloat(picture.width), rect.height / CGFloat(picture.height))
        let size = CGSize(width: CGFloat(picture.width) * scale, height: CGFloat(picture.height) * scale)
        let fitted = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        // Drawn upright in the flipped context.
        context.saveGState()
        context.translateBy(x: 0, y: fitted.minY + fitted.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(picture, in: fitted)
        context.restoreGState()
    }

    static func cgColor(_ color: EditColor) -> CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [color.red, color.green, color.blue, color.alpha].map {
            CGFloat(min(max($0, 0), 1))
        }) ?? CGColor(gray: 0, alpha: 1)
    }
}
