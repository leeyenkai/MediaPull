import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import MediaPullCore

/// Renders a photo with its recipe (section 46, D-128): the same steps for the canvas and for export, so what is shown is
/// what is written. Never on the main actor.
public enum PhotoRenderer {
    /// One context for every render: Core Image contexts are thread-safe and costly to make.
    public static let context = CIContext(options: [.cacheIntermediates: false, .name: "MediaPullEdit"])

    /// A context that renders on the CPU, for tests that compare pixels across runs.
    public static let exactContext = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])

    /// The photo as it is, upright: a RAW developed from its raw data (R-4603), anything else from its primary image.
    public static func source(_ url: URL, draft: Bool = false) -> CIImage? {
        if MediaFormat.fromExtension(url.pathExtension) == .raw, let raw = CIRAWFilter(imageURL: url) {
            raw.isDraftModeEnabled = draft
            if let image = raw.outputImage { return image }
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        return CIImage(cgImageSource: source, index: index, options: [.applyOrientationProperty: true])
    }

    /// The edited picture (geometry, adjustments, look), before any frame. Extent starts at the origin.
    public static func picture(_ input: CIImage, recipe: EditRecipe) -> CIImage {
        var image = geometry(input, recipe.geometry)
        image = adjust(image, recipe.adjust)
        if let look = recipe.look { image = apply(look, to: image) }
        return image.cropped(to: image.extent)
    }

    /// The whole result: the picture, on its frame when it has one, with its layers drawn over it. `layers` draws the text,
    /// shapes and images for a canvas of a given size (MediaPullEdit's LayerRenderer); nil leaves them out.
    /// `fit`: the canvas is scaled to fit this size before the layers are drawn, so text is drawn sharp at the size shown
    /// or written.
    public static func render(_ input: CIImage, recipe: EditRecipe, fit: CGSize? = nil,
                              layers: ((CGSize) -> CGImage?)? = nil) -> CIImage
    {
        let edited = picture(input, recipe: recipe)
        var canvas = recipe.frame.map { FrameRenderer.compose(edited, frame: $0) } ?? edited
        if let fit { canvas = scaled(canvas, toFit: fit) }
        if let layers, !recipe.layers.isEmpty, let overlay = layers(canvas.extent.size) {
            canvas = CIImage(cgImage: overlay).composited(over: canvas).cropped(to: canvas.extent)
        }
        return canvas
    }

    /// `image` scaled so it fits `size` (never enlarged), extent at the origin.
    public static func scaled(_ image: CIImage, toFit size: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scale = min(1, min(size.width / extent.width, size.height / extent.height))
        guard scale < 1 else { return image }
        // Scaled from the picture with its edges carried outward, so the border pixels are never mixed with nothing (which
        // left PNG and HEIC exports see-through at their edges, audit 2026-11-21-8, B8-6).
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = image.clampedToExtent()
        filter.scale = Float(scale)
        filter.aspectRatio = 1
        guard let out = filter.outputImage else { return image }
        let size = CGSize(width: (extent.width * scale).rounded(), height: (extent.height * scale).rounded())
        return out.cropped(to: CGRect(origin: CGPoint(x: extent.minX * scale, y: extent.minY * scale), size: size))
            .transformed(by: CGAffineTransform(translationX: -extent.minX * scale, y: -extent.minY * scale))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Renders to a bitmap in sRGB (or Display P3), 8 bits per channel.
    public static func cgImage(_ image: CIImage, displayP3: Bool = false, exact: Bool = false) -> CGImage? {
        let space = CGColorSpace(name: displayP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!
        return (exact ? exactContext : context).createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space)
    }

    // MARK: Geometry (R-4604)

    static func geometry(_ input: CIImage, _ geometry: EditGeometry) -> CIImage {
        var image = input.transformed(by: CGAffineTransform(translationX: -input.extent.minX, y: -input.extent.minY))
        let orientation: CGImagePropertyOrientation = switch ((geometry.quarterTurns % 4) + 4) % 4 {
        case 1: geometry.flipped ? .leftMirrored : .right
        case 2: geometry.flipped ? .downMirrored : .down
        case 3: geometry.flipped ? .rightMirrored : .left
        default: geometry.flipped ? .upMirrored : .up
        }
        image = image.oriented(orientation)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if geometry.straighten != 0 {
            let size = image.extent.size
            let scale = EditGeometry.straightenScale(width: size.width, height: size.height, degrees: geometry.straighten)
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            // Clockwise for positive degrees, as the slider reads; Core Image's y axis points up.
            let turn = CGAffineTransform(translationX: centre.x, y: centre.y)
                .rotated(by: -geometry.straighten * .pi / 180)
                .translatedBy(x: -centre.x, y: -centre.y)
            let keep = CGRect(x: centre.x - size.width * scale / 2, y: centre.y - size.height * scale / 2,
                              width: size.width * scale, height: size.height * scale).integral
            image = image.clampedToExtent().transformed(by: turn).cropped(to: keep)
            image = image.transformed(by: CGAffineTransform(translationX: -keep.minX, y: -keep.minY))
        }
        if let crop = geometry.crop?.clamped, crop != .whole {
            let size = image.extent.size
            // Unit rects have their origin top left; Core Image's is bottom left.
            let rect = CGRect(x: crop.x * size.width, y: (1 - crop.y - crop.height) * size.height,
                              width: crop.width * size.width, height: crop.height * size.height).integral
            image = image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        }
        return image
    }

    // MARK: Adjustments (R-4603)

    static func adjust(_ input: CIImage, _ a: Adjustments) -> CIImage {
        var image = input
        let extent = input.extent
        if a.exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = image
            filter.ev = Float(a.exposure)
            image = filter.outputImage ?? image
        }
        if a.highlights != 0 || a.shadows != 0 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = image
            // Below 1 darkens highlights; raising them is done with a gentle curve instead (the filter only lowers them).
            filter.highlightAmount = Float(1 - max(0, -a.highlights) / 100)
            filter.shadowAmount = Float(a.shadows / 100)
            filter.radius = 0
            image = filter.outputImage ?? image
            if a.highlights > 0 { image = curve(image, low: 0, mid: 0, high: a.highlights / 100 * 0.08) }
        }
        if a.whites != 0 || a.blacks != 0 {
            image = curve(image, low: a.blacks / 100 * 0.08, mid: 0, high: a.whites / 100 * 0.08)
        }
        if a.contrast != 0 || a.saturation != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.contrast = Float(1 + a.contrast / 100 * 0.5)
            filter.saturation = Float(max(0, 1 + a.saturation / 100))
            filter.brightness = 0
            image = filter.outputImage ?? image
        }
        if a.temperature != 0 || a.tint != 0 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = image
            // A warmer setting tells the filter the light was cooler than it looked, so the picture warms.
            filter.neutral = CIVector(x: 6500 + a.temperature * 25, y: a.tint)
            filter.targetNeutral = CIVector(x: 6500, y: 0)
            image = filter.outputImage ?? image
        }
        if a.vibrance != 0 {
            let filter = CIFilter.vibrance()
            filter.inputImage = image
            filter.amount = Float(a.vibrance / 100)
            image = filter.outputImage ?? image
        }
        if a.clarity > 0 {
            let filter = CIFilter.unsharpMask()
            filter.inputImage = image
            filter.radius = Float(max(extent.width, extent.height) / 100)
            filter.intensity = Float(a.clarity / 100 * 0.6)
            image = filter.outputImage ?? image
        }
        if a.sharpen > 0 {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = image
            filter.sharpness = Float(a.sharpen / 100)
            // In proportion to the picture, so the canvas (a smaller copy) and the export look alike (D-128).
            filter.radius = Float(1.5 * Self.detailScale(extent))
            image = filter.outputImage ?? image
        }
        if a.vignette > 0 {
            let filter = CIFilter.vignette()
            filter.inputImage = image
            filter.intensity = Float(a.vignette / 100 * 1.5)
            filter.radius = Float(max(extent.width, extent.height) / 400)
            image = filter.outputImage ?? image
        }
        if a.grain > 0, let noise = CIFilter.randomGenerator().outputImage {
            // The same grain every time (the generator is fixed), grey, scaled to the picture's size.
            let mono = CIFilter.colorControls()
            let grainSize = 1.5 * Self.detailScale(extent)
            mono.inputImage = noise.transformed(by: CGAffineTransform(scaleX: grainSize, y: grainSize))
            mono.saturation = 0
            mono.brightness = -0.5
            mono.contrast = 1
            let strength = CIFilter.colorMatrix()
            strength.inputImage = mono.outputImage
            strength.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(a.grain / 100 * 0.35))
            let blend = CIFilter.overlayBlendMode()
            blend.inputImage = strength.outputImage?.cropped(to: extent)
            blend.backgroundImage = image
            image = blend.outputImage ?? image
        }
        return image.cropped(to: extent)
    }

    /// Fine detail (grain, sharpening) is sized for a 2400 px picture and scaled with the picture's long edge.
    static func detailScale(_ extent: CGRect) -> Double {
        max(0.25, Double(max(extent.width, extent.height)) / 2400)
    }

    /// A tone curve that lifts or lowers the darkest and brightest quarter.
    static func curve(_ image: CIImage, low: Double, mid: Double, high: Double) -> CIImage {
        let filter = CIFilter.toneCurve()
        filter.inputImage = image
        filter.point0 = CGPoint(x: 0, y: max(0, low))
        filter.point1 = CGPoint(x: 0.25, y: min(1, max(0, 0.25 + low)))
        filter.point2 = CGPoint(x: 0.5, y: 0.5 + mid)
        filter.point3 = CGPoint(x: 0.75, y: min(1, max(0, 0.75 + high)))
        filter.point4 = CGPoint(x: 1, y: min(1, 1 + min(0, high)))
        return filter.outputImage ?? image
    }

    // MARK: Looks (R-4603)

    static func apply(_ look: Look, to image: CIImage) -> CIImage {
        let styled: CIImage? = switch look.name {
        case .mono: photoEffect("CIPhotoEffectMono", image)
        case .noir: photoEffect("CIPhotoEffectNoir", image)
        case .silvertone: photoEffect("CIPhotoEffectTonal", image)
        case .chrome: photoEffect("CIPhotoEffectChrome", image)
        case .instant: photoEffect("CIPhotoEffectInstant", image)
        case .fade: photoEffect("CIPhotoEffectFade", image)
        case .film:
            curve(adjust(image, { var a = Adjustments(); a.temperature = 15; a.saturation = -10; a.grain = 18; return a }()),
                  low: 0.05, mid: 0, high: -0.03)
        case .warm: adjust(image, { var a = Adjustments(); a.temperature = 35; a.vibrance = 10; return a }())
        case .cool: adjust(image, { var a = Adjustments(); a.temperature = -35; a.tint = -5; return a }())
        case .vivid: adjust(image, { var a = Adjustments(); a.vibrance = 45; a.contrast = 15; return a }())
        }
        guard let styled else { return image }
        let amount = min(max(look.amount, 0), 1)
        guard amount < 1 else { return styled.cropped(to: image.extent) }
        let mix = CIFilter.dissolveTransition()
        mix.inputImage = image
        mix.targetImage = styled
        mix.time = Float(amount)
        return (mix.outputImage ?? styled).cropped(to: image.extent)
    }

    static func photoEffect(_ name: String, _ image: CIImage) -> CIImage? {
        guard let filter = CIFilter(name: name) else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage
    }
}

/// Puts the edited picture on its frame (R-4605).
public enum FrameRenderer {
    /// The canvas size for a picture of `picture` size: its own shape grown by the insets, or the frame's shape with the
    /// picture fitted inside the insets.
    public static func layout(picture: CGSize, frame: Frame) -> (canvas: CGSize, photo: CGRect) {
        let insets = (top: clamp(frame.top), left: clamp(frame.left), right: clamp(frame.right), bottom: clamp(frame.bottom))
        guard picture.width > 0, picture.height > 0 else { return (picture, .zero) }
        let ratio = frame.shape == .photoShape ? picture.width / picture.height : frame.shape.ratio
        if let ratio {
            // The canvas keeps the picture's long edge; insets are shares of its shorter side.
            let long = max(picture.width, picture.height)
            let canvas = ratio >= 1 ? CGSize(width: long, height: (long / ratio).rounded())
                : CGSize(width: (long * ratio).rounded(), height: long)
            let short = min(canvas.width, canvas.height)
            let box = CGRect(x: insets.left * short, y: insets.top * short,
                             width: canvas.width - (insets.left + insets.right) * short,
                             height: canvas.height - (insets.top + insets.bottom) * short)
            if frame.fill { return (canvas, box.integral) }
            let scale = min(box.width / picture.width, box.height / picture.height)
            let size = CGSize(width: (picture.width * scale).rounded(), height: (picture.height * scale).rounded())
            let photo = CGRect(x: (box.midX - size.width / 2).rounded(), y: (box.midY - size.height / 2).rounded(),
                               width: size.width, height: size.height)
            return (canvas, photo)
        }
        let short = min(picture.width, picture.height)
        let photo = CGRect(x: (insets.left * short).rounded(), y: (insets.top * short).rounded(), width: picture.width,
                           height: picture.height)
        let canvas = CGSize(width: photo.maxX + (insets.right * short).rounded(), height: photo.maxY + (insets.bottom * short).rounded())
        return (canvas, photo)
    }

    static func clamp(_ value: Double) -> Double { min(max(value, 0), 0.4) }

    /// The framed canvas, extent at the origin. Rects from `layout` have their origin top left; Core Image's is bottom left.
    public static func compose(_ picture: CIImage, frame: Frame) -> CIImage {
        let (canvas, photoRect) = layout(picture: picture.extent.size, frame: frame)
        let bounds = CGRect(origin: .zero, size: canvas)
        let background: CIImage = switch frame.background {
        case let .color(color):
            CIImage(color: ciColor(color)).cropped(to: bounds)
        case let .gradient(top, bottom):
            {
                let gradient = CIFilter.linearGradient()
                gradient.point0 = CGPoint(x: 0, y: canvas.height)
                gradient.point1 = CGPoint(x: 0, y: 0)
                gradient.color0 = ciColor(top)
                gradient.color1 = ciColor(bottom)
                return (gradient.outputImage ?? CIImage(color: .white)).cropped(to: bounds)
            }()
        case .blurredPhoto:
            {
                let extent = picture.extent
                let scale = max(canvas.width / extent.width, canvas.height / extent.height)
                let filled = picture.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let centred = filled.transformed(by: CGAffineTransform(translationX: (canvas.width - filled.extent.width) / 2,
                                                                       y: (canvas.height - filled.extent.height) / 2))
                let blur = CIFilter.gaussianBlur()
                blur.inputImage = centred.clampedToExtent()
                blur.radius = Float(max(canvas.width, canvas.height) / 30)
                let dim = CIFilter.exposureAdjust()
                dim.inputImage = blur.outputImage
                dim.ev = -0.6
                return (dim.outputImage ?? centred).cropped(to: bounds)
            }()
        }
        let flippedY = canvas.height - photoRect.maxY
        let placed = CGRect(x: photoRect.minX, y: flippedY, width: photoRect.width, height: photoRect.height)
        // Fitted, the picture is scaled to the rect; filling, it covers the rect and is cropped about its centre.
        let sx = photoRect.width / picture.extent.width, sy = photoRect.height / picture.extent.height
        let scale = frame.fill ? max(sx, sy) : 1
        var photo = picture.transformed(by: frame.fill ? CGAffineTransform(scaleX: scale, y: scale) : CGAffineTransform(scaleX: sx, y: sy))
        photo = photo.transformed(by: CGAffineTransform(translationX: placed.midX - photo.extent.midX, y: placed.midY - photo.extent.midY))
        if frame.cornerRadius > 0 {
            let radius = min(placed.width, placed.height) * min(frame.cornerRadius, 0.5)
            let mask = CIFilter.roundedRectangleGenerator()
            mask.extent = placed
            mask.radius = Float(radius)
            mask.color = .white
            if let shape = mask.outputImage {
                let blend = CIFilter.blendWithAlphaMask()
                blend.inputImage = photo
                blend.backgroundImage = CIImage.empty()
                blend.maskImage = shape
                photo = blend.outputImage ?? photo
            }
        }
        var result = background
        if frame.shadow {
            let shadowShape = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.45)).cropped(to: placed)
                .transformed(by: CGAffineTransform(translationX: 0, y: -min(canvas.width, canvas.height) * 0.008))
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = shadowShape
            blur.radius = Float(min(canvas.width, canvas.height) * 0.012)
            if let soft = blur.outputImage { result = soft.composited(over: result) }
        }
        return photo.cropped(to: placed).composited(over: result).cropped(to: bounds)
    }

    static func ciColor(_ color: EditColor) -> CIColor {
        CIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) ?? CIColor(red: color.red, green: color.green, blue: color.blue)
    }
}
