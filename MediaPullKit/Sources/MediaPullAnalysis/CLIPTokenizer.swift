import Foundation

/// The CLIP byte-level BPE tokenizer (49,408 tokens), written here so search needs no third-party code.
/// Matches the reference tokenizer exactly on the benchmark strings, including accents and truncation.
public final class CLIPTokenizer: @unchecked Sendable {
    let encoder: [String: Int32]
    let ranks: [String: Int]
    let byteToUnicode: [UInt8: Character]
    let lock = NSLock()
    var cache: [String: [Int32]] = [:]
    public let contextLength: Int
    let startToken: Int32
    let endToken: Int32
    // A fixed pattern that compiles; a failure would be a programming error, found by the tokenizer tests.
    // swiftlint:disable:next force_try
    let pattern = try! NSRegularExpression(
        pattern: #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#,
        options: [.caseInsensitive]
    )

    public init(vocab: URL, merges: URL, contextLength: Int = 77) throws {
        let vocabulary = try JSONDecoder().decode([String: Int32].self, from: Data(contentsOf: vocab))
        encoder = vocabulary
        var r: [String: Int] = [:]
        let lines = try String(contentsOf: merges, encoding: .utf8).split(separator: "\n")
        for (i, line) in lines.enumerated() where !line.hasPrefix("#version") {
            r[String(line)] = i
        }
        ranks = r
        var bs = Array(33 ... 126) + Array(161 ... 172) + Array(174 ... 255)
        var cs = bs
        var n = 0
        for b in 0 ..< 256 where !bs.contains(b) {
            bs.append(b)
            cs.append(256 + n)
            n += 1
        }
        var map: [UInt8: Character] = [:]
        for (b, c) in zip(bs, cs) {
            map[UInt8(b)] = Character(UnicodeScalar(c)!)
        }
        byteToUnicode = map
        self.contextLength = contextLength
        startToken = vocabulary["<|startoftext|>"] ?? 49406
        endToken = vocabulary["<|endoftext|>"] ?? 49407
    }

    func bpe(_ token: String) -> [Int32] {
        lock.lock()
        if let hit = cache[token] {
            lock.unlock(); return hit
        }
        lock.unlock()
        var word = token.map { String($0) }
        word[word.count - 1] += "</w>"
        while word.count > 1 {
            var best: (rank: Int, index: Int)?
            for i in 0 ..< (word.count - 1) {
                if let rank = ranks[word[i] + " " + word[i + 1]], best == nil || rank < best!.rank {
                    best = (rank, i)
                }
            }
            guard let best else { break }
            let first = word[best.index], second = word[best.index + 1]
            var merged: [String] = []
            var i = 0
            while i < word.count {
                if i < word.count - 1, word[i] == first, word[i + 1] == second {
                    merged.append(first + second)
                    i += 2
                } else {
                    merged.append(word[i])
                    i += 1
                }
            }
            word = merged
        }
        let ids = word.compactMap { encoder[$0] }
        lock.lock()
        if cache.count > 20000 {
            cache.removeAll()
        }
        cache[token] = ids
        lock.unlock()
        return ids
    }

    /// Token ids padded with zeros to the context length, start and end tokens included.
    public func encode(_ text: String) -> [Int32] {
        let cleaned = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).lowercased()
        var ids = [startToken]
        let ns = cleaned as NSString
        for match in pattern.matches(in: cleaned, range: NSRange(location: 0, length: ns.length)) {
            let piece = ns.substring(with: match.range)
            ids += bpe(String(piece.utf8.compactMap { byteToUnicode[$0] }))
        }
        ids.append(endToken)
        if ids.count > contextLength {
            ids = Array(ids.prefix(contextLength))
            ids[contextLength - 1] = endToken
        }
        return ids + [Int32](repeating: 0, count: contextLength - ids.count)
    }
}
