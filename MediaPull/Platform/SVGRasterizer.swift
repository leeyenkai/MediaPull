import AppKit

/// Draws SVG files with AppKit's SVG support, for saving them as PNG in Archive folders.
nonisolated enum SVGRasterizer {
    @Sendable
    static func rasterize(_ file: URL, longSide: Int) -> CGImage? {
        guard let image = NSImage(contentsOf: file), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = CGFloat(longSide) / max(image.size.width, image.size.height)
        let width = max(1, Int((image.size.width * scale).rounded()))
        let height = max(1, Int((image.size.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
