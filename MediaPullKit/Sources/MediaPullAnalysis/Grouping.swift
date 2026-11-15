import Accelerate
import Foundation

/// Visually similar sets: images whose embeddings are close, joined into groups (R-3705). Looser than duplicates and separate from them.
public enum SimilarSets {
    /// A group index per vector, or nil for a vector with no close neighbour.
    public static func groups(_ vectors: [[Float]], threshold: Float) -> [Int?] {
        let n = vectors.count
        guard n > 1, let dim = vectors.first?.count else { return [Int?](repeating: nil, count: n) }
        let flat = vectors.flatMap(\.self)
        var parent = Array(0 ..< n)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        // Blocks of rows against all rows, so memory stays small for large folders.
        let block = 512
        var sims = [Float](repeating: 0, count: block * n)
        var columns = [Float](repeating: 0, count: flat.count)
        vDSP_mtrans(flat, 1, &columns, 1, vDSP_Length(dim), vDSP_Length(n))
        var start = 0
        while start < n {
            let rows = min(block, n - start)
            flat.withUnsafeBufferPointer { all in
                vDSP_mmul(all.baseAddress! + start * dim, 1, columns, 1, &sims, 1, vDSP_Length(rows), vDSP_Length(n),
                          vDSP_Length(dim))
            }
            for r in 0 ..< rows {
                let i = start + r
                for j in (i + 1) ..< n where sims[r * n + j] >= threshold {
                    let a = find(i), b = find(j)
                    if a != b {
                        parent[a] = b
                    }
                }
            }
            start += rows
        }
        var counts: [Int: Int] = [:]
        for i in 0 ..< n {
            counts[find(i), default: 0] += 1
        }
        var numbering: [Int: Int] = [:]
        return (0 ..< n).map { i in
            let root = find(i)
            guard counts[root, default: 0] > 1 else { return nil }
            if let k = numbering[root] {
                return k
            }
            let k = numbering.count
            numbering[root] = k
            return k
        }
    }
}

/// Subjects for Sort into Folders by Subject (R-3706): the image–text model scores each subject's wording,
/// and a softmax over the subjects gives the confidence compared with the threshold (D-65).
public struct SubjectClassifier: Sendable {
    public static let standard: [(name: String, prompts: [String])] = [
        ("People", ["a photo of a person", "a photo of people", "a portrait of a person"]),
        ("Dogs", ["a photo of a dog"]),
        ("Cats", ["a photo of a cat"]),
        ("Birds", ["a photo of a bird"]),
        ("Other animals", ["a photo of an animal", "a photo of wildlife"]),
        ("Food", ["a photo of food", "a photo of a meal", "a photo of a drink"]),
        ("Nature", ["a photo of nature", "a photo of a forest", "a photo of flowers", "a photo of a landscape"]),
        ("Beach", ["a photo of a beach", "a photo of the sea"]),
        ("Mountains", ["a photo of mountains", "a photo of snowy mountains"]),
        ("City", ["a photo of a city street", "a photo of a city skyline"]),
        ("Buildings", ["a photo of a building", "a photo of architecture", "a photo of a room interior"]),
        ("Vehicles", ["a photo of a car", "a photo of a vehicle", "a photo of a plane", "a photo of a train", "a photo of a boat"]),
        ("Documents", ["a photo of a document", "a scan of a page of text", "a photo of a receipt"]),
        ("Screenshots", ["a screenshot of a phone screen", "a screenshot of a computer screen", "a screenshot of an app"]),
        ("Art", ["a painting", "a drawing", "an illustration", "digital art"]),
    ]

    public let names: [String]
    let embeddings: [[Float]]
    let logitScale: Float

    /// `custom` subjects are words the person adds; each becomes "a photo of <words>".
    public init(encoder: ImageTextEncoder, custom: [String] = []) {
        var names: [String] = []
        var embeddings: [[Float]] = []
        let all = Self.standard + custom.map { ($0, ["a photo of \($0)"]) }
        for (name, prompts) in all {
            let vectors = prompts.compactMap { encoder.embed(text: $0) }
            guard !vectors.isEmpty else { continue }
            var mean = [Float](repeating: 0, count: vectors[0].count)
            for v in vectors {
                vDSP_vadd(mean, 1, v, 1, &mean, 1, vDSP_Length(mean.count))
            }
            names.append(name)
            embeddings.append(ModelLoader.normalized(mean))
        }
        self.names = names
        self.embeddings = embeddings
        logitScale = encoder.spec.logitScale
    }

    /// The best subject for an image embedding and its confidence.
    public func classify(_ embedding: [Float]) -> (subject: String, confidence: Float)? {
        guard !embeddings.isEmpty else { return nil }
        let scores = embeddings.map { e -> Float in
            var r: Float = 0
            vDSP_dotpr(e, 1, embedding, 1, &r, vDSP_Length(e.count))
            return r
        }
        let top = scores.max()!
        let exps = scores.map { exp(logitScale * ($0 - top)) }
        let best = scores.firstIndex(of: top)!
        return (names[best], exps[best] / exps.reduce(0, +))
    }
}
