import Accelerate
import CoreGraphics
import CoreML
import Foundation

/// Describes the bundled models (`manifest.json` in the Models folder), so a model can change without code changes (D-58, D-67).
public struct ModelManifest: Codable, Sendable {
    public struct ImageText: Codable, Sendable {
        public var id: String
        public var imageModel: String
        public var textModel: String
        public var imageSize: Int
        public var dimension: Int
        public var contextLength: Int
        public var vocab: String
        public var merges: String
        public var imageOutput: String
        public var textOutput: String
        /// Scale applied to the dot product before the softmax used for subject confidence.
        public var logitScale: Float
    }

    public struct Face: Codable, Sendable {
        public var id: String
        public var model: String
        public var dimension: Int
        public var output: String
        public var matchThreshold: Float
        /// The face detector with landmarks; Apple's Vision is used when there is none.
        public var detector: String?
        /// Adds the embedding of the mirrored crop, as the model's own evaluation does.
        public var flipFusion: Bool?

        public init(id: String, model: String, dimension: Int, output: String, matchThreshold: Float, detector: String?,
                    flipFusion: Bool?)
        {
            self.id = id
            self.model = model
            self.dimension = dimension
            self.output = output
            self.matchThreshold = matchThreshold
            self.detector = detector
            self.flipFusion = flipFusion
        }
    }

    public var imageText: ImageText?
    public var face: Face?
    public var places: String?

    public static func load(from folder: URL) -> ModelManifest? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")) else { return nil }
        return try? JSONDecoder().decode(ModelManifest.self, from: data)
    }
}

enum ModelLoader {
    /// Loads a compiled `.mlmodelc`, or compiles an `.mlpackage` once into Caches.
    static func load(_ url: URL, units: MLComputeUnits = .cpuAndNeuralEngine) throws -> MLModel {
        let config = MLModelConfiguration()
        config.computeUnits = units
        if url.pathExtension == "mlmodelc" {
            return try MLModel(contentsOf: url, configuration: config)
        }
        let caches = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("MediaPull/CompiledModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let compiled = caches.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(Int(stamp)).mlmodelc")
        if !FileManager.default.fileExists(atPath: compiled.path) {
            let temporary = try MLModel.compileModel(at: url)
            try? FileManager.default.removeItem(at: compiled)
            try FileManager.default.moveItem(at: temporary, to: compiled)
        }
        return try MLModel(contentsOf: compiled, configuration: config)
    }

    static func vector(_ array: MLMultiArray) -> [Float] {
        var out = [Float](repeating: 0, count: array.count)
        switch array.dataType {
        case .float32:
            let p = array.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0 ..< array.count {
                out[i] = p[i]
            }
        case .float16:
            out = Half.floats(array.dataPointer, count: array.count)
        default:
            for i in 0 ..< array.count {
                out[i] = array[i].floatValue
            }
        }
        return normalized(out)
    }

    static func normalized(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        let s = 1 / max(norm.squareRoot(), 1e-12)
        return v.map { $0 * s }
    }
}

/// Image and text embeddings for free-text search, subjects and similar sets.
public final class ImageTextEncoder: @unchecked Sendable {
    public let spec: ModelManifest.ImageText
    let image: MLModel
    let text: MLModel
    let tokenizer: CLIPTokenizer
    let imageInput: String
    let textInput: String

    public init(folder: URL, spec: ModelManifest.ImageText) throws {
        self.spec = spec
        image = try ModelLoader.load(folder.appendingPathComponent(spec.imageModel))
        text = try ModelLoader.load(folder.appendingPathComponent(spec.textModel))
        tokenizer = try CLIPTokenizer(vocab: folder.appendingPathComponent(spec.vocab), merges: folder.appendingPathComponent(spec.merges),
                                      contextLength: spec.contextLength)
        imageInput = image.modelDescription.inputDescriptionsByName.keys.first ?? "image"
        textInput = text.modelDescription.inputDescriptionsByName.keys.first ?? "text"
    }

    public var dimension: Int {
        spec.dimension
    }

    public func embed(_ cg: CGImage) -> [Float]? {
        guard let description = image.modelDescription.inputDescriptionsByName[imageInput] else { return nil }
        let value: MLFeatureValue?
        if let constraint = description.imageConstraint {
            guard let square = ImagePrep.centerCropped(cg, side: constraint.pixelsWide) else { return nil }
            value = try? MLFeatureValue(cgImage: square, constraint: constraint, options: nil)
        } else {
            value = ImagePrep.tensor(cg, side: spec.imageSize).map { MLFeatureValue(multiArray: $0) }
        }
        guard let value, let out = try? image.prediction(from: MLDictionaryFeatureProvider(dictionary: [imageInput: value])),
              let array = out.featureValue(for: spec.imageOutput)?.multiArrayValue else { return nil }
        return ModelLoader.vector(array)
    }

    public func embed(text query: String) -> [Float]? {
        let tokens = tokenizer.encode(query)
        guard let array = try? MLMultiArray(shape: [1, NSNumber(value: tokens.count)], dataType: .int32) else { return nil }
        let p = array.dataPointer.assumingMemoryBound(to: Int32.self)
        for (i, t) in tokens.enumerated() {
            p[i] = t
        }
        guard let out = try? text.prediction(from: MLDictionaryFeatureProvider(dictionary: [textInput: MLFeatureValue(multiArray: array)])),
              let result = out.featureValue(for: spec.textOutput)?.multiArrayValue else { return nil }
        return ModelLoader.vector(result)
    }
}

/// Face embeddings from aligned 112 × 112 crops (R-3902).
public final class FaceEncoder: @unchecked Sendable {
    public let spec: ModelManifest.Face
    let model: MLModel
    let input: String

    public init(folder: URL, spec: ModelManifest.Face) throws {
        self.spec = spec
        model = try ModelLoader.load(folder.appendingPathComponent(spec.model))
        input = model.modelDescription.inputDescriptionsByName.keys.first ?? "face"
    }

    public func embed(_ crop: CGImage) -> [Float]? {
        guard let first = embedOnce(crop) else { return nil }
        guard spec.flipFusion == true, let mirrored = ImagePrep.mirrored(crop), let second = embedOnce(mirrored) else { return first }
        return ModelLoader.normalized(zip(first, second).map { $0 + $1 })
    }

    func embedOnce(_ crop: CGImage) -> [Float]? {
        guard let tensor = ImagePrep.tensor(crop, side: 112, stretch: true),
              let out = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: [input: MLFeatureValue(multiArray: tensor)])),
              let array = out.featureValue(for: spec.output)?.multiArrayValue else { return nil }
        return ModelLoader.vector(array)
    }
}

enum ImagePrep {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    /// RGBA pixels of the image drawn at its own size.
    static func pixels(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return data
    }

    /// The shortest side scaled to `side` with Lanczos resampling, then the centre square, as the models were trained.
    static func centerCropped(_ image: CGImage, side: Int) -> CGImage? {
        guard var src = pixels(image) else { return nil }
        let w = image.width, h = image.height
        let scale = Double(side) / Double(min(w, h))
        let sw = max(side, Int((Double(w) * scale).rounded())), sh = max(side, Int((Double(h) * scale).rounded()))
        var dst = [UInt8](repeating: 0, count: sw * sh * 4)
        let error = src.withUnsafeMutableBytes { s in
            dst.withUnsafeMutableBytes { d in
                var a = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                var b = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(sh), width: vImagePixelCount(sw), rowBytes: sw * 4)
                return vImageScale_ARGB8888(&a, &b, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        guard error == kvImageNoError else { return nil }
        let x0 = (sw - side) / 2, y0 = (sh - side) / 2
        var crop = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0 ..< side {
            let from = ((y + y0) * sw + x0) * 4
            crop.replaceSubrange(y * side * 4 ..< (y + 1) * side * 4, with: dst[from ..< from + side * 4])
        }
        guard let provider = CGDataProvider(data: Data(crop) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    static func mirrored(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.translateBy(x: CGFloat(image.width), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    /// A 1×3×side×side Float32 tensor of RGB values in 0...1.
    static func tensor(_ image: CGImage, side: Int, stretch: Bool = false) -> MLMultiArray? {
        let square: CGImage? = stretch && image.width == side && image.height == side ? image : centerCropped(image, side: side)
        guard let square, let px = pixels(square),
              let array = try? MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
        else { return nil }
        let p = array.dataPointer.assumingMemoryBound(to: Float.self)
        let plane = side * side
        for i in 0 ..< plane {
            p[i] = Float(px[i * 4]) / 255
            p[plane + i] = Float(px[i * 4 + 1]) / 255
            p[2 * plane + i] = Float(px[i * 4 + 2]) / 255
        }
        return array
    }
}
