import Accelerate
import CryptoKit
import Foundation

/// Embeddings on disk: `<name>.vec` holds half-precision rows back to back, `<name>.ids` the 32-byte id of each row.
/// Appended as files are analysed, read whole for search (benchmark: 4 ms for 50,000 rows), never inside a library folder (D-60).
public actor VectorStore {
    public let dimension: Int
    let vectorURL: URL
    let idURL: URL
    var ids: [Data] = []
    var rowByID: [Data: Int] = [:]
    var vectors: [UInt16] = []

    public init(folder: URL, name: String, dimension: Int, excludeFromBackup: Bool = false) {
        self.dimension = dimension
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        vectorURL = folder.appendingPathComponent("\(name).vec")
        idURL = folder.appendingPathComponent("\(name).ids")
        let idData = (try? Data(contentsOf: idURL)) ?? Data()
        let vecData = (try? Data(contentsOf: vectorURL)) ?? Data()
        let rows = min(idData.count / 32, vecData.count / (dimension * 2))
        var ids: [Data] = []
        ids.reserveCapacity(rows)
        for r in 0 ..< rows {
            ids.append(idData.subdata(in: r * 32 ..< (r + 1) * 32))
        }
        var vectors = [UInt16](repeating: 0, count: rows * dimension)
        vectors
            .withUnsafeMutableBytes { dst in vecData.withUnsafeBytes { src in
                dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[0 ..< rows * dimension * 2]))
            } }
        self.ids = ids
        self.vectors = vectors
        rowByID = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { _, b in b })
        for url in [vectorURL, idURL] where excludeFromBackup {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var target = url
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            try? target.setResourceValues(values)
        }
    }

    public static func id(_ key: String) -> Data {
        Data(SHA256.hash(data: Data(key.utf8)))
    }

    public var count: Int {
        ids.count
    }

    public func contains(_ key: String) -> Bool {
        rowByID[Self.id(key)] != nil
    }

    /// Adds or replaces the vector for `key`, returning its row.
    @discardableResult
    public func put(_ key: String, _ vector: [Float]) -> Int {
        precondition(vector.count == dimension)
        let id = Self.id(key)
        let half = Half.bits(vector)
        if let row = rowByID[id] {
            vectors.replaceSubrange(row * dimension ..< (row + 1) * dimension, with: half)
            rewrite()
            return row
        }
        let row = ids.count
        ids.append(id)
        vectors.append(contentsOf: half)
        rowByID[id] = row
        append(id: id, vector: half)
        return row
    }

    public func vector(_ key: String) -> [Float]? {
        guard let row = rowByID[Self.id(key)] else { return nil }
        return vector(row: row)
    }

    public func vector(row: Int) -> [Float]? {
        guard row >= 0, row < ids.count else { return nil }
        return vectors.withUnsafeBytes { Half.floats($0.baseAddress! + row * dimension * 2, count: dimension) }
    }

    /// Cosine similarity of every stored row to `query` (rows and query are unit length), keyed by row.
    public func similarities(to query: [Float]) -> [Float] {
        let rows = ids.count
        guard rows > 0, query.count == dimension else { return [] }
        var out = [Float](repeating: 0, count: rows)
        let chunk = 4096
        var buffer = [Float](repeating: 0, count: chunk * dimension)
        var start = 0
        while start < rows {
            let n = min(chunk, rows - start)
            vectors.withUnsafeBufferPointer { half in
                buffer.withUnsafeMutableBufferPointer { full in
                    var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: half.baseAddress! + start * dimension), height: 1,
                                            width: vImagePixelCount(n * dimension), rowBytes: n * dimension * 2)
                    var dst = vImage_Buffer(
                        data: full.baseAddress!,
                        height: 1,
                        width: vImagePixelCount(n * dimension),
                        rowBytes: n * dimension * 4
                    )
                    vImageConvert_Planar16FtoPlanarF(&src, &dst, 0)
                }
            }
            out.withUnsafeMutableBufferPointer { o in
                vDSP_mmul(buffer, 1, query, 1, o.baseAddress! + start, 1, vDSP_Length(n), 1, vDSP_Length(dimension))
            }
            start += n
        }
        return out
    }

    /// Similarity of `query` to each key that has a vector.
    public func similarities(to query: [Float], keys: [String]) -> [String: Float] {
        let all = similarities(to: query)
        var out: [String: Float] = [:]
        for key in keys {
            if let row = rowByID[Self.id(key)], row < all.count {
                out[key] = all[row]
            }
        }
        return out
    }

    public func deleteAll() {
        ids = []
        vectors = []
        rowByID = [:]
        try? FileManager.default.removeItem(at: vectorURL)
        try? FileManager.default.removeItem(at: idURL)
    }

    func append(id: Data, vector: [UInt16]) {
        func add(_ data: Data, to url: URL) {
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
        add(id, to: idURL)
        add(vector.withUnsafeBufferPointer { Data(buffer: $0) }, to: vectorURL)
    }

    func rewrite() {
        try? ids.reduce(Data(), +).write(to: idURL, options: .atomic)
        try? vectors.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: vectorURL, options: .atomic)
    }
}
