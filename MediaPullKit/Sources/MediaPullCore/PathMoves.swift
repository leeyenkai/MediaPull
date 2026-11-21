import Foundation

/// Recorded moves applied in order to stored paths. A folder moves as one step, so a path below a moved folder follows it.
public struct PathMoves: Sendable {
    public let moves: [(from: String, to: String)]
    let indices: [String: [Int]]

    public init(_ moves: [(from: String, to: String)]) {
        self.moves = moves
        var indices: [String: [Int]] = [:]
        for (i, move) in moves.enumerated() {
            indices[move.from, default: []].append(i)
        }
        self.indices = indices
    }

    /// Where `path` is after the moves, or nil when none of them touched it.
    public func destination(of path: String) -> String? {
        var current = path
        var after = -1
        while true {
            // The earliest later move of this path or of a folder above it.
            var best: (index: Int, from: String)?
            var candidate = current
            while true {
                if let i = indices[candidate]?.first(where: { $0 > after }), i < best?.index ?? .max {
                    best = (i, candidate)
                }
                let parent = (candidate as NSString).deletingLastPathComponent
                if parent == candidate || parent.isEmpty { break }
                candidate = parent
            }
            guard let best else { break }
            current = moves[best.index].to + String(current.dropFirst(best.from.count))
            after = best.index
        }
        return after >= 0 ? current : nil
    }
}
