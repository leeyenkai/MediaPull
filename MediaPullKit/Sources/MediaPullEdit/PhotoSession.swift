import CoreGraphics
import CoreImage
import Foundation
import MediaPullCore

/// A photo open in Edit/Frame: decoded once, with a smaller copy for the canvas, rendered with any recipe off the main
/// actor. The app holds it without seeing Core Image (D-128). Core Image images never change, so sharing is safe.
public final class PhotoSession: @unchecked Sendable {
    public let url: URL
    /// The photo's size upright, before any edit.
    public let size: CGSize
    private let proxy: CIImage

    /// The canvas never needs more than this many pixels on its long edge.
    public static let proxyEdge: CGFloat = 2400

    /// Reads the photo; nil when it cannot be decoded. Slow for large files: call off the main actor.
    public init?(url: URL) {
        guard let source = PhotoRenderer.source(url, draft: true), source.extent.width > 0 else { return nil }
        let upright = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
        self.url = url
        size = upright.extent.size
        // Rendered once into memory, so every slider move starts from decoded pixels, not the file.
        let small = PhotoRenderer.scaled(upright, toFit: CGSize(width: Self.proxyEdge, height: Self.proxyEdge))
        // Kept in extended linear sRGB at half-float, so wide-gamut (Display P3) colours are not clipped before edits and
        // the canvas matches the export (D-128).
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        if let bitmap = PhotoRenderer.context.createCGImage(small, from: small.extent, format: .RGBAh, colorSpace: space) {
            proxy = CIImage(cgImage: bitmap)
        } else {
            proxy = small
        }
    }

    /// A still (a video's frame) to edit on the canvas like a photo.
    public init(image: CGImage, url: URL) {
        self.url = url
        let full = CIImage(cgImage: image)
        size = full.extent.size
        proxy = PhotoRenderer.scaled(full, toFit: CGSize(width: Self.proxyEdge, height: Self.proxyEdge))
    }

    /// The result for the canvas, fitted to `fit` points × scale. `before` shows the photo with no edits (Before/After).
    public func preview(_ recipe: EditRecipe, fit: CGSize, before: Bool = false) -> CGImage? {
        // In the export's colour space, so the canvas shows what the export keeps: a wide colour only when it is kept
        // (audit 2026-11-21-3, B3-m1, and round 4, B4-m2). The window colour-manages either.
        let wide = recipe.export.displayP3
        if before { return PhotoRenderer.cgImage(PhotoRenderer.scaled(proxy, toFit: fit), displayP3: wide) }
        var canvas = PhotoRenderer.render(proxy, recipe: recipe, fit: fit) { size in
            LayerRenderer.image(recipe.layers, canvas: size)
        }
        // A JPEG has no transparency: see-through parts are shown white, as the export writes them (round 12, B12-m4).
        if recipe.export.format == .jpeg {
            canvas = canvas.composited(over: CIImage(color: .white).cropped(to: canvas.extent))
        }
        return PhotoRenderer.cgImage(canvas, displayP3: wide)
    }

    /// The picture turned and straightened but not cropped, for choosing the crop; no frame or layers.
    public func uncropped(_ recipe: EditRecipe, fit: CGSize) -> CGImage? {
        var plain = recipe
        plain.geometry.crop = nil
        plain.frame = nil
        plain.layers = []
        let picture = PhotoRenderer.scaled(PhotoRenderer.picture(proxy, recipe: plain), toFit: fit)
        return PhotoRenderer.cgImage(picture, displayP3: recipe.export.displayP3)
    }

    /// Small previews of each look, for the look picker.
    public func lookPreview(_ recipe: EditRecipe, look: LookName?, edge: CGFloat) -> CGImage? {
        var styled = recipe
        styled.look = look.map { Look(name: $0) }
        styled.frame = nil
        styled.layers = []
        let small = PhotoRenderer.scaled(proxy, toFit: CGSize(width: edge * 2, height: edge * 2))
        return PhotoRenderer.cgImage(PhotoRenderer.render(small, recipe: styled, fit: CGSize(width: edge, height: edge)))
    }

    /// The pixel size Export writes for `recipe` (shown on the canvas and the Export bar, D-132). Worked out from the
    /// proxy's extent, which Core Image gives without drawing, scaled to the photo's own size.
    public func outputSize(_ recipe: EditRecipe) -> CGSize {
        guard proxy.extent.width > 0 else { return .zero }
        var plain = recipe
        plain.layers = []
        let extent = PhotoRenderer.render(proxy, recipe: plain).extent.size
        let scale = size.width / proxy.extent.width
        let full = CGSize(width: (extent.width * scale).rounded(), height: (extent.height * scale).rounded())
        return recipe.export.size.pixels(for: full)
    }

    /// The pixel size of the crop on the photo itself, before any frame (shown while cropping).
    public func cropPixels(_ geometry: EditGeometry) -> CGSize {
        let turned = geometry.turnedSize(size)
        let crop = geometry.crop ?? .whole
        return CGSize(width: (turned.width * crop.width).rounded(), height: (turned.height * crop.height).rounded())
    }

    /// Width over height of the picture once turned and straightened (what the crop's shape is measured against).
    public func turnedRatio(_ geometry: EditGeometry) -> Double {
        let turned = geometry.turnedSize(size)
        return turned.height > 0 ? turned.width / turned.height : 1
    }
}
