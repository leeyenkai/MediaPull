import Foundation
import MediaPullCore
import MediaPullMedia
import MediaPullNet

/// How alike two images must be to count as duplicates (SPEC R-3302).
public enum DuplicateSensitivity: String, Codable, CaseIterable, Sendable {
    /// Byte-for-byte identical files only (SHA-256).
    case exact
    /// Also the same picture saved again: resized, re-compressed or converted (at most 4 of 64 hash bits differ).
    case nearIdentical
    /// Also light edits such as a small crop or a watermark (at most 7 bits differ).
    case similar

    public var label: String {
        switch self {
        case .exact: "Identical Files Only"
        case .nearIdentical: "Same Picture (Resized or Re-saved)"
        case .similar: "Similar Pictures"
        }
    }

    /// Largest Hamming distance between fingerprints that still counts as a match.
    var threshold: Int? {
        switch self {
        case .exact: nil
        case .nearIdentical: 4
        case .similar: 7
        }
    }

    /// Largest colour difference (0–255) that still counts as a match, and which cells it is read from:
    /// every cell must agree for the same picture; a quarter of the cells may differ for light edits.
    var colorRule: (threshold: Double, percentile: Double) {
        switch self {
        case .exact: (0, 1)
        case .nearIdentical: (14, 1)
        case .similar: (20, 0.75)
        }
    }
}

/// Finds identical and visually similar files under a library folder (SPEC section 33).
public actor DuplicateFinder {
    struct Entry: Codable {
        var size: Int64
        var modified: Double
        var sha256: String?
        var fingerprint: ImageFingerprint?
        var fingerprinted = false
    }

    public struct Group: Sendable, Equatable {
        public var members: [URL]
        /// True when every member is byte-for-byte the same file.
        public var identical: Bool
    }

    public struct Report: Sendable, Equatable {
        public var root: URL
        public var groups: [Group] = []
        /// File path to its index in `groups`.
        public var groupOf: [String: Int] = [:]
        public var filesChecked = 0
        /// Path to its set of byte-for-byte identical files; files without an identical twin are absent.
        public var twinSet: [String: Int] = [:]

        /// Whether the file has a byte-for-byte identical twin; the others in a group only look alike.
        public func isIdentical(_ url: URL) -> Bool {
            twinSet[url.standardizedFileURL.path] != nil
        }

        public func areIdentical(_ a: URL, _ b: URL) -> Bool {
            guard let first = twinSet[a.standardizedFileURL.path] else { return false }
            return first == twinSet[b.standardizedFileURL.path]
        }

        public func group(for url: URL) -> Group? {
            groupOf[url.standardizedFileURL.path].map { groups[$0] }
        }

        public var duplicateFileCount: Int { groupOf.count }
    }

    private var cache: [String: Entry] = [:]
    private let storeURL: URL?
    private var loaded = false
    private var dirty = false

    public init(storeURL: URL?) {
        self.storeURL = storeURL
    }

    // MARK: Scanning

    /// `audioHashes`: each audio file's stream hash from analysis (path → hash), so the same sound with other tags is a
    /// look-alike (R-4205).
    public func scan(root: URL, sensitivity: DuplicateSensitivity, audioHashes: [String: String] = [:],
                     progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> Report {
        loadIfNeeded()
        let files = Self.mediaFiles(under: root)
        var report = Report(root: root)
        report.filesChecked = files.count

        // Identical files: only files that share a size need a checksum.
        let bySize = Dictionary(grouping: files, by: \.size).values.filter { $0.count > 1 }.flatMap { $0 }
        let needsImages = sensitivity.threshold != nil
        let imageFiles = needsImages ? files.filter { $0.isImage } : []
        var work: [(file: MediaFile, sha: Bool, print: Bool)] = []
        let shaSet = Set(bySize.map(\.path))
        let printSet = Set(imageFiles.map(\.path))
        for file in files where shaSet.contains(file.path) || printSet.contains(file.path) {
            let entry = current(file)
            let needSha = shaSet.contains(file.path) && entry?.sha256 == nil
            let needPrint = printSet.contains(file.path) && entry?.fingerprinted != true
            // A file kept only in iCloud would be downloaded by reading it; it is left out until it is on this Mac.
            if needSha || needPrint, !FileFlags.isDataless(file.url) { work.append((file, needSha, needPrint)) }
        }

        var done = 0
        let total = work.count
        progress(0, total)
        await withTaskGroup(of: (MediaFile, String?, ImageFingerprint?, Bool).self) { group in
            var iterator = work.makeIterator()
            func addNext() -> Bool {
                guard let next = iterator.next() else { return false }
                group.addTask {
                    let sha = next.sha ? try? FileHasher.sha256(of: next.file.url) : nil
                    let print = next.print ? PerceptualHash.fingerprint(of: next.file.url) : nil
                    return (next.file, sha, print, next.print)
                }
                return true
            }
            for _ in 0 ..< 4 where addNext() {}
            while let (file, sha, print, printed) = await group.next() {
                if Task.isCancelled { group.cancelAll(); break }
                var entry = current(file) ?? Entry(size: file.size, modified: file.modified)
                if let sha { entry.sha256 = sha }
                if printed {
                    entry.fingerprint = print
                    entry.fingerprinted = true
                }
                cache[file.path] = entry
                dirty = true
                done += 1
                if done % 25 == 0 || done == total { progress(done, total) }
                _ = addNext()
            }
        }
        guard !Task.isCancelled else { return report }
        save()

        var union = UnionFind(count: files.count)
        let index = Dictionary(uniqueKeysWithValues: files.enumerated().map { ($1.path, $0) })
        var identicalPairs = Set<Int>()
        let shaGroups = Dictionary(grouping: bySize.compactMap { file in cache[file.path]?.sha256.map { (file, $0) } }, by: \.1)
        var twinCounter = 0
        for members in shaGroups.values.sorted(by: { $0[0].0.path < $1[0].0.path }) where members.count > 1 {
            let indices = members.compactMap { index[$0.0.path] }
            for other in indices.dropFirst() { union.join(indices[0], other) }
            identicalPairs.formUnion(indices)
            twinCounter += 1
            for member in members { report.twinSet[member.0.path] = twinCounter }
        }

        if let threshold = sensitivity.threshold {
            let printed = imageFiles.compactMap { file in cache[file.path]?.fingerprint.map { (index[file.path]!, $0) } }
            // Pigeonhole: two 64-bit hashes within 7 bits of each other agree on at least one of 8 bytes.
            var buckets = [[UInt64: [Int]]](repeating: [:], count: 8)
            for (position, (_, print)) in printed.enumerated() {
                for band in 0 ..< 8 {
                    buckets[band][(print.pHash >> UInt64(band * 8)) & 0xFF, default: []].append(position)
                }
            }
            // A pair sharing several bytes meets in several bands; it is compared only in the first one, which needs no
            // memory of compared pairs (a set of them grew to millions on large libraries).
            func byte(_ hash: UInt64, _ band: Int) -> UInt64 { (hash >> UInt64(band * 8)) & 0xFF }
            for (bandIndex, band) in buckets.enumerated() {
                for members in band.values where members.count > 1 && members.count < 4000 {
                    for i in 0 ..< members.count {
                        for j in (i + 1) ..< members.count {
                            let a = members[i], b = members[j]
                            let first = printed[a].1.pHash, second = printed[b].1.pHash
                            let metBefore = (0 ..< bandIndex).contains { earlier in
                                byte(first, earlier) == byte(second, earlier) && (buckets[earlier][byte(first, earlier)]?.count ?? 0) < 4000
                            }
                            guard !metBefore else { continue }
                            if printed[a].1.distance(to: printed[b].1) <= threshold,
                               printed[a].1.colorDifference(to: printed[b].1, percentile: sensitivity.colorRule.percentile)
                               <= sensitivity.colorRule.threshold
                            {
                                union.join(printed[a].0, printed[b].0)
                            }
                        }
                    }
                }
            }
        }

        if sensitivity.threshold != nil, !audioHashes.isEmpty {
            let sounds = Dictionary(grouping: files.indices.compactMap { i in audioHashes[files[i].path].map { (i, $0) } }, by: \.1)
            for members in sounds.values where members.count > 1 {
                for other in members.dropFirst() { union.join(members[0].0, other.0) }
            }
        }

        var groups: [Int: [Int]] = [:]
        for position in files.indices {
            groups[union.find(position), default: []].append(position)
        }
        for members in groups.values.filter({ $0.count > 1 }).sorted(by: { $0[0] < $1[0] }) {
            let urls = members.map { files[$0].url }
            let shas = Set(members.compactMap { cache[files[$0].path]?.sha256 })
            let identical = shas.count == 1 && members.allSatisfy { identicalPairs.contains($0) }
            let groupIndex = report.groups.count
            report.groups.append(Group(members: urls, identical: identical))
            for member in members {
                report.groupOf[files[member].path] = groupIndex
            }
        }
        return report
    }

    private func current(_ file: MediaFile) -> Entry? {
        guard let entry = cache[file.path], entry.size == file.size, entry.modified == file.modified else { return nil }
        return entry
    }

    // MARK: Files

    struct MediaFile: Sendable {
        var url: URL
        var path: String
        var size: Int64
        var modified: Double
        var isImage: Bool
    }

    /// Media files, a unit counted once by its lead (R-4206): Trash Extra Copies never sees half a pair.
    static func mediaFiles(under root: URL) -> [MediaFile] {
        let all = allMediaFiles(under: root)
        let leads = Set(FolderOperations.withoutUnitMembers(all.map(\.url)).map(\.path))
        return all.count == leads.count ? all : all.filter { leads.contains($0.url.path) }
    }

    static func allMediaFiles(under root: URL) -> [MediaFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var files: [MediaFile] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard ext != "json", let format = MediaFormat.fromExtension(ext),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
            else { continue }
            let size = Int64(values.fileSize ?? 0)
            guard size > 0 else { continue }
            let standard = url.standardizedFileURL
            files.append(MediaFile(url: standard, path: standard.path, size: size,
                                   modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                                   isImage: format.kind == .image || format.kind == .animatedImage))
        }
        return files.sorted { $0.path < $1.path }
    }

    // MARK: Cache

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let storeURL, let data = try? Data(contentsOf: storeURL),
              let stored = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return }
        cache = stored
    }

    private func save() {
        guard dirty, let storeURL else { return }
        dirty = false
        // Forget files that no longer exist so the cache does not grow without bound.
        cache = cache.filter { FileManager.default.fileExists(atPath: $0.key) }
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic) // lint:allow silent-write a cache; lost, it is worked out again
    }
}

/// Disjoint sets with path halving.
struct UnionFind {
    private var parent: [Int]

    init(count: Int) {
        parent = Array(0 ..< count)
    }

    mutating func find(_ x: Int) -> Int {
        var x = x
        while parent[x] != x {
            parent[x] = parent[parent[x]]
            x = parent[x]
        }
        return x
    }

    mutating func join(_ a: Int, _ b: Int) {
        let rootA = find(a), rootB = find(b)
        if rootA != rootB { parent[max(rootA, rootB)] = min(rootA, rootB) }
    }
}
