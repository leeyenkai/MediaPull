import CoreGraphics
import CoreML
import Foundation

/// A face found by the detector, in pixels of the analysed image (origin top left), with its five landmarks:
/// image-left eye, image-right eye, nose tip, left and right mouth corners.
public struct DetectedFace: Sendable {
    public var box: CGRect
    public var score: Float
    public var landmarks: [CGPoint]

    /// A rough left-right turn from where the nose sits between the eyes, in radians.
    public var yaw: Double {
        let eyeMid = (landmarks[0].x + landmarks[1].x) / 2
        let eyeGap = max(abs(landmarks[1].x - landmarks[0].x), 1)
        return Double(max(-1, min(1, (landmarks[2].x - eyeMid) / eyeGap * 2))) * .pi / 2
    }
}

/// SCRFD-10G with landmarks (D-67): anchor-free boxes and five points at strides 8, 16 and 32 on a 640 × 640 letterbox.
public final class FaceDetector: @unchecked Sendable {
    let model: MLModel
    let input: String
    let outputs: [String]
    static let side = 640
    static let strides = [8, 16, 32]
    public var scoreThreshold: Float = 0.5
    public var nmsThreshold: CGFloat = 0.4

    public init(url: URL) throws {
        model = try ModelLoader.load(url)
        input = model.modelDescription.inputDescriptionsByName.keys.first ?? "image"
        outputs = (0 ..< 9).map { "out\($0)" }
    }

    public func detect(_ image: CGImage) -> [DetectedFace] {
        let side = Self.side
        let scale = min(CGFloat(side) / CGFloat(image.width), CGFloat(side) / CGFloat(image.height))
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: ImagePrep.space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
            let constraint = model.modelDescription.inputDescriptionsByName[input]?.imageConstraint else { return [] }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.interpolationQuality = .high
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        // Pasted at the top left, as the model was evaluated.
        ctx.draw(image, in: CGRect(x: 0, y: CGFloat(side) - h, width: w, height: h))
        guard let letterbox = ctx.makeImage(),
              let value = try? MLFeatureValue(cgImage: letterbox, constraint: constraint, options: nil),
              let out = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: [input: value])) else { return [] }
        let arrays = outputs.compactMap { out.featureValue(for: $0)?.multiArrayValue }
        guard arrays.count == 9 else { return [] }
        var faces: [DetectedFace] = []
        for (level, stride) in Self.strides.enumerated() {
            let scores = Self.floats(arrays[level]), boxes = Self.floats(arrays[3 + level]), points = Self.floats(arrays[6 + level])
            let width = side / stride
            let s = CGFloat(stride)
            for index in 0 ..< scores.count where scores[index] >= scoreThreshold {
                let cell = index / 2
                let cx = CGFloat(cell % width) * s, cy = CGFloat(cell / width) * s
                let d = (0 ..< 4).map { CGFloat(boxes[index * 4 + $0]) * s }
                let box = CGRect(
                    x: (cx - d[0]) / scale,
                    y: (cy - d[1]) / scale,
                    width: (d[0] + d[2]) / scale,
                    height: (d[1] + d[3]) / scale
                )
                let marks = (0 ..< 5).map { i in
                    CGPoint(
                        x: (cx + CGFloat(points[index * 10 + i * 2]) * s) / scale,
                        y: (cy + CGFloat(points[index * 10 + i * 2 + 1]) * s) / scale
                    )
                }
                faces.append(DetectedFace(box: box, score: scores[index], landmarks: marks))
            }
        }
        return Self.suppress(faces.sorted { $0.score > $1.score }, threshold: nmsThreshold)
    }

    /// The values row by row, following the array's strides (Neural Engine outputs can have padded rows).
    static func floats(_ array: MLMultiArray) -> [Float] {
        let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
        let columns = shape.last ?? 1, rows = array.count / max(columns, 1)
        let rowStride = shape.count >= 2 ? strides[shape.count - 2] : columns, colStride = strides.last ?? 1
        var out = [Float](repeating: 0, count: rows * columns)
        func fill<T>(_: T.Type, _ convert: (T) -> Float) {
            let p = array.dataPointer.assumingMemoryBound(to: T.self)
            for r in 0 ..< rows {
                for c in 0 ..< columns {
                    out[r * columns + c] = convert(p[r * rowStride + c * colStride])
                }
            }
        }
        switch array.dataType {
        case .float16:
            var bits = [UInt16](repeating: 0, count: rows * columns)
            let p = array.dataPointer.assumingMemoryBound(to: UInt16.self)
            for r in 0 ..< rows {
                for c in 0 ..< columns {
                    bits[r * columns + c] = p[r * rowStride + c * colStride]
                }
            }
            out = bits.withUnsafeBytes { Half.floats($0.baseAddress!, count: bits.count) }
        case .float32: fill(Float.self) { $0 }
        default: for i in 0 ..< array.count {
                out[i] = array[i].floatValue
            }
        }
        return out
    }

    static func suppress(_ faces: [DetectedFace], threshold: CGFloat) -> [DetectedFace] {
        var kept: [DetectedFace] = []
        for face in faces {
            let overlaps = kept.contains { other in
                let inter = face.box.intersection(other.box)
                guard !inter.isNull else { return false }
                let i = inter.width * inter.height
                return i / (face.box.width * face.box.height + other.box.width * other.box.height - i) > threshold
            }
            if !overlaps {
                kept.append(face)
            }
        }
        return kept
    }
}
