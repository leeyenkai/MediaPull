import CoreGraphics
import Foundation
import MediaPullCore
import MediaPullMedia
import Vision

/// What analysing one file produced: the record, its image embedding and, when people are recognised, one embedding per face.
public struct AnalysisOutput: Sendable {
    public var record: AnalysisRecord
    public var embedding: [Float]?
    public var faces: [(box: FaceBox, key: String, embedding: [Float])]
}

/// Runs every analysis step on one file (SPEC section 36). Never called on the main actor.
public final class Analyzer: Sendable {
    public let imageText: ImageTextEncoder?
    public let faceEncoder: FaceEncoder?
    public let geocoder: OfflineGeocoder?
    public let faceDetector: FaceDetector?
    let ocrState = OCRState()
    let audioProbe: MediaFactsReader.AudioProbe?
    let audioHash: (@Sendable (URL) async -> String?)?

    public init(modelsFolder: URL?, audioProbe: MediaFactsReader.AudioProbe? = nil, audioHash: (@Sendable (URL) async -> String?)? = nil) {
        self.audioProbe = audioProbe
        self.audioHash = audioHash
        let manifest = modelsFolder.flatMap(ModelManifest.load)
        imageText = modelsFolder.flatMap { folder in manifest?.imageText.flatMap { try? ImageTextEncoder(folder: folder, spec: $0) } }
        faceEncoder = modelsFolder.flatMap { folder in manifest?.face.flatMap { try? FaceEncoder(folder: folder, spec: $0) } }
        geocoder = modelsFolder
            .flatMap { folder in (manifest?.places).flatMap { OfflineGeocoder(table: folder.appendingPathComponent($0)) } }
        faceDetector = modelsFolder
            .flatMap { folder in manifest?.face?.detector.flatMap { try? FaceDetector(url: folder.appendingPathComponent($0)) } }
        let state = ocrState
        // Accurate recognition stalls Vision for up to a minute on first use and then fails on macOS 27.0.x (a known system
        // problem), so it is not tried there; elsewhere fast recognition is used until a probe shows accurate recognition works.
        let version = ProcessInfo.processInfo.operatingSystemVersion
        if !(version.majorVersion == 27 && version.minorVersion == 0) {
            Task.detached(priority: .utility) { state.accurateWorks = Self.probeAccurateText() }
        }
    }

    static func probeAccurateText() -> Bool {
        let width = 320, height = 80
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: ImagePrep.space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for i in 0 ..< 6 {
            ctx.fill(CGRect(x: 20 + i * 48, y: 30, width: 30, height: 24))
        }
        guard let image = ctx.makeImage() else { return false }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return true
        } catch {
            return false
        }
    }

    /// The longest side analysed. Large enough for text and small faces, small enough to decode quickly.
    public static let analysisSize = 1024

    /// Reads the file's facts again into an existing record, without running any model (R-4210).
    public func refreshFacts(_ url: URL, record: AnalysisRecord) async -> AnalysisRecord {
        var updated = record
        var facts = await readFacts(url)
        // Sizes measured from the decoded picture when the file did not say are kept.
        if facts.pixelWidth == nil {
            facts.pixelWidth = record.facts.pixelWidth
            facts.pixelHeight = record.facts.pixelHeight
        }
        updated.facts = facts
        updated.isScreenshot = ScreenshotRule.isScreenshot(facts: facts, fileName: url.lastPathComponent)
        updated.place = facts.latitude.flatMap { lat in facts.longitude.flatMap { geocoder?.place(latitude: lat, longitude: $0) } }
        updated.factsVersion = AnalysisRecord.currentFactsVersion
        return updated
    }

    func readFacts(_ url: URL) async -> MediaFacts {
        var facts = await MediaFactsReader.facts(for: url, audioProbe: audioProbe)
        if facts.audio != nil, let audioHash { facts.audio?.streamHash = await audioHash(url) }
        return facts
    }

    public func analyse(_ url: URL, sha256: String, recogniseFaces: Bool) async -> AnalysisOutput {
        var facts = await readFacts(url)
        let isVideo = facts.format?.kind == .video
        let image: CGImage? = isVideo ? await Thumbnailer.videoFrame(at: url, maxPixel: Self.analysisSize, position: .analysis)
            : Thumbnailer.image(at: url, maxPixel: Self.analysisSize)
        var record = AnalysisRecord(sha256: sha256, facts: facts)
        record.isScreenshot = ScreenshotRule.isScreenshot(facts: facts, fileName: url.lastPathComponent)
        if let lat = facts.latitude, let lon = facts.longitude {
            record.place = geocoder?.place(latitude: lat, longitude: lon)
        }
        guard let image else { return AnalysisOutput(record: record, embedding: nil, faces: []) }
        if facts.pixelWidth == nil {
            facts.pixelWidth = image.width
            facts.pixelHeight = image.height
            record.facts = facts
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let classify = VNClassifyImageRequest()
        let faces = VNDetectFaceRectanglesRequest()
        faces.revision = VNDetectFaceRectanglesRequestRevision3
        try? handler.perform(faceDetector == nil ? [classify, faces] : [classify])
        record.labels = (classify.results ?? []).filter { $0.confidence >= 0.1 }.prefix(25)
            .map { ContentLabel(identifier: $0.identifier, confidence: $0.confidence) }
        record.text = recogniseText(handler)
        record.colour = ColourName.dominant(grid: MediaFactsReader.colourGrid(image))

        var faceOutputs: [(FaceBox, String, [Float])] = []
        let found = faces.results ?? []
        if let detector = faceDetector {
            let size = CGSize(width: image.width, height: image.height)
            for face in detector.detect(image) {
                let r = face.box.intersection(CGRect(origin: .zero, size: size))
                guard !r.isNull, r.width > 4 else { continue }
                let box = FaceBox(x: Double(r.minX / size.width), y: Double(r.minY / size.height), width: Double(r.width / size.width),
                                  height: Double(r.height / size.height), quality: face.score, pixelSize: Double(face.box.width),
                                  yaw: face.yaw)
                record.faces.append(box)
                guard recogniseFaces, let encoder = faceEncoder, box.pixelSize >= FaceRules.minimumPixels,
                      let crop = FaceAlignment.warp(image, from: face.landmarks), let vector = encoder.embed(crop) else { continue }
                faceOutputs.append((box, box.key, vector))
            }
        } else if !found.isEmpty {
            let marks = VNDetectFaceLandmarksRequest()
            marks.inputFaceObservations = found
            let quality = VNDetectFaceCaptureQualityRequest()
            quality.inputFaceObservations = found
            try? handler.perform([marks, quality])
            for (i, face) in found.enumerated() {
                let b = face.boundingBox
                let box = FaceBox(x: Double(b.minX), y: Double(1 - b.maxY), width: Double(b.width), height: Double(b.height),
                                  quality: (quality.results ?? []).indices.contains(i) ? quality.results?[i].faceCaptureQuality : nil,
                                  pixelSize: Double(b.width) * Double(image.width), yaw: face.yaw?.doubleValue)
                record.faces.append(box)
                guard recogniseFaces, let encoder = faceEncoder, box.pixelSize >= FaceRules.minimumPixels,
                      let landmarks = (marks.results ?? []).indices.contains(i) ? marks.results?[i].landmarks : nil,
                      let crop = FaceAlignment.crop(image, landmarks: landmarks, box: b),
                      let vector = encoder.embed(crop) else { continue }
                faceOutputs.append((box, box.key, vector))
            }
        }
        let embedding = imageText?.embed(image)
        record.hasEmbedding = embedding != nil
        return AnalysisOutput(record: record, embedding: embedding, faces: faceOutputs.map { (box: $0.0, key: $0.1, embedding: $0.2) })
    }

    /// Accurate recognition once the probe shows it works; fast recognition otherwise, or if it fails later.
    func recogniseText(_ handler: VNImageRequestHandler) -> String? {
        func run(_ level: VNRequestTextRecognitionLevel) -> [String]? {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            request.automaticallyDetectsLanguage = true
            do { try handler.perform([request]) } catch { return nil }
            return (request.results ?? []).compactMap { $0.topCandidates(1).first }.filter { $0.confidence >= 0.3 }.map(\.string)
        }
        var lines: [String]?
        if ocrState.accurateWorks {
            lines = run(.accurate)
            if lines == nil {
                ocrState.accurateWorks = false
            }
        }
        if lines == nil {
            lines = run(.fast)
        }
        let text = (lines ?? []).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(4000))
    }

    public func embed(text: String) -> [Float]? {
        imageText?.embed(text: text)
    }
}

final class OCRState: @unchecked Sendable {
    private let lock = NSLock()
    private var works = false
    var accurateWorks: Bool {
        get { lock.withLock { works } }
        set { lock.withLock { works = newValue } }
    }
}

/// Aligns a face to the five-point template recognition models expect (eyes, nose tip, mouth corners at 112 × 112).
public enum FaceAlignment {
    static let template: [CGPoint] = [CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014), CGPoint(x: 56.0252, y: 71.7366),
                                      CGPoint(x: 41.5493, y: 92.3655), CGPoint(x: 70.7299, y: 92.2041)]

    static func mean(_ pts: [CGPoint]) -> CGPoint {
        CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count), y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count))
    }

    /// Least-squares similarity transform (rotation, uniform scale, translation) mapping `src` onto `dst`.
    public static func similarity(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform {
        let ms = mean(src), md = mean(dst)
        var a: CGFloat = 0, b: CGFloat = 0, den: CGFloat = 0
        for (s, d) in zip(src, dst) {
            let sx = s.x - ms.x, sy = s.y - ms.y, dx = d.x - md.x, dy = d.y - md.y
            a += sx * dx + sy * dy
            b += sx * dy - sy * dx
            den += sx * sx + sy * sy
        }
        let ca = a / max(den, 1e-9), cb = b / max(den, 1e-9)
        return CGAffineTransform(a: ca, b: cb, c: -cb, d: ca, tx: md.x - (ca * ms.x - cb * ms.y), ty: md.y - (cb * ms.x + ca * ms.y))
    }

    /// Five points in image coordinates (origin top left), from Vision's landmarks; nil when they disagree with the face box.
    static func points(_ landmarks: VNFaceLandmarks2D, box: CGRect, size: CGSize) -> [CGPoint]? {
        guard let le = landmarks.leftEye?.pointsInImage(imageSize: size), let re = landmarks.rightEye?.pointsInImage(imageSize: size),
              let nose = landmarks.nose?.pointsInImage(imageSize: size), let lips = landmarks.outerLips?.pointsInImage(imageSize: size),
              !le.isEmpty, !re.isEmpty, !nose.isEmpty, lips.count >= 2, landmarks.confidence >= 0.5 else { return nil }
        func flip(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x, y: size.height - p.y)
        }
        let eyes = [mean(le), mean(re)].map(flip).sorted { $0.x < $1.x }
        // The lowest point of the nose outline is the tip.
        let tip = flip(nose.min { $0.y < $1.y } ?? mean(nose))
        let mouth = lips.map(flip).sorted { $0.x < $1.x }
        let src = [eyes[0], eyes[1], tip, mouth.first!, mouth.last!]
        let boxWidth = box.width * size.width
        let eyeGap = hypot(src[1].x - src[0].x, src[1].y - src[0].y)
        let mouthBelow = (src[3].y + src[4].y) / 2 - (src[0].y + src[1].y) / 2
        guard eyeGap >= boxWidth * 0.25, eyeGap <= boxWidth * 0.7, mouthBelow >= eyeGap * 0.5 else { return nil }
        return src
    }

    /// The aligned 112 × 112 crop. Untrusted landmarks fall back to the face box (benchmark: 93.3 % → 97.0 % on LFW).
    public static func crop(_ image: CGImage, landmarks: VNFaceLandmarks2D, box: CGRect) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        let src = points(landmarks, box: box, size: size) ?? {
            let r = CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height, width: box.width * size.width,
                           height: box.height * size.height)
            return [
                CGPoint(x: r.minX + r.width * 0.3, y: r.minY + r.height * 0.4),
                CGPoint(x: r.minX + r.width * 0.7, y: r.minY + r.height * 0.4),
                CGPoint(x: r.midX, y: r.minY + r.height * 0.6),
                CGPoint(x: r.minX + r.width * 0.35, y: r.minY + r.height * 0.8),
                CGPoint(x: r.minX + r.width * 0.65, y: r.minY + r.height * 0.8),
            ]
        }()
        return warp(image, from: src)
    }

    /// Draws `image` so the five points land on the template.
    public static func warp(_ image: CGImage, from src: [CGPoint]) -> CGImage? {
        let t = similarity(from: src, to: template)
        let height = CGFloat(image.height)
        guard let ctx = CGContext(data: nil, width: 112, height: 112, bitsPerComponent: 8, bytesPerRow: 112 * 4, space: ImagePrep.space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: 112)
        ctx.scaleBy(x: 1, y: -1)
        ctx.concatenate(t)
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: height))
        return ctx.makeImage()
    }
}
