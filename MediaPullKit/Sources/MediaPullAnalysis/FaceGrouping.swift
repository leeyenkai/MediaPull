import Accelerate
import Foundation

/// Groups faces into people, respecting the person's corrections (R-3903, R-3904).
public enum FaceGrouping {
    public struct Face: Sendable {
        public var key: String
        public var vector: [Float]
        public var quality: Float
        public var personID: UUID?
        public var pinned: Bool
        public var rejected: Set<UUID>

        public init(key: String, vector: [Float], quality: Float, personID: UUID?, pinned: Bool, rejected: Set<UUID>) {
            self.key = key
            self.vector = vector
            self.quality = quality
            self.personID = personID
            self.pinned = pinned
            self.rejected = rejected
        }
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var r: Float = 0
        vDSP_dotpr(a, 1, b, 1, &r, vDSP_Length(a.count))
        return r
    }

    static func normalized(_ v: [Float]) -> [Float] {
        ModelLoader.normalized(v)
    }

    /// New assignments for faces whose person changes. Faces already with a person keep it (incremental), new faces join
    /// the closest person above `threshold` unless they reject that person, and the rest form new people when at least
    /// `minimumGroup` of them are alike. `regroup` first frees faces of unnamed, unpinned groups so they can be grouped again.
    public static func group(_ faces: [Face], threshold: Float, minimumGroup: Int = 2, regroup: Bool = false,
                             named: Set<UUID> = []) -> [String: UUID?]
    {
        var work = faces
        if regroup {
            for i in work.indices where !work[i].pinned && !(work[i].personID.map(named.contains) ?? false) {
                work[i].personID = nil
            }
        }
        // Regrouping gives freed faces new ids, so "Not This Person" is checked against the people the group's faces
        // belonged to before (`origins`), both ways: a face never joins a group holding faces of a person it rejected,
        // nor a group with a face that rejected its own person (R-3904).
        struct Constraints {
            var origins: Set<UUID> = []
            var rejects: Set<UUID> = []

            func allows(_ face: Face) -> Bool {
                face.rejected.isDisjoint(with: origins) && !(face.personID.map(rejects.contains) ?? false)
            }

            mutating func add(_ face: Face) {
                if let id = face.personID {
                    origins.insert(id)
                }
                rejects.formUnion(face.rejected)
            }
        }
        var sums: [UUID: [Float]] = [:]
        var constraints: [UUID: Constraints] = [:]
        for (i, face) in work.enumerated() {
            if let id = face.personID {
                add(face.vector, to: &sums[id, default: zeros(face.vector.count)])
                constraints[id, default: Constraints(origins: [id])].add(faces[i])
            }
        }
        var centroids = sums.mapValues(normalized)
        var result: [String: UUID?] = [:]
        // Best faces first, so poor crops join groups built from clear ones.
        // Ties broken by key and by person id, never by dictionary order, so every run gives the same groups.
        let order = work.indices.filter { work[$0].personID == nil }
            .sorted { work[$0].quality == work[$1].quality ? work[$0].key < work[$1].key : work[$0].quality > work[$1].quality }
        var leftover: [Int] = []
        for i in order {
            var best: (UUID, Float)?
            for (id, centroid) in centroids.sorted(by: { $0.key.uuidString < $1.key.uuidString })
                where constraints[id]?.allows(faces[i]) ?? true
            {
                let s = dot(centroid, work[i].vector)
                if s >= threshold, s > (best?.1 ?? -2) {
                    best = (id, s)
                }
            }
            if let (id, _) = best {
                work[i].personID = id
                add(work[i].vector, to: &sums[id]!)
                constraints[id]?.add(faces[i])
                centroids[id] = normalized(sums[id]!)
                result[work[i].key] = id
            } else {
                leftover.append(i)
            }
        }
        // The rest: greedy grouping among themselves.
        var groups: [(centroid: [Float], sum: [Float], members: [Int], constraints: Constraints)] = []
        for i in leftover {
            var best: (Int, Float)?
            for (g, group) in groups.enumerated() where group.constraints.allows(faces[i]) {
                let s = dot(group.centroid, work[i].vector)
                if s >= threshold, s > (best?.1 ?? -2) {
                    best = (g, s)
                }
            }
            if let (g, _) = best {
                add(work[i].vector, to: &groups[g].sum)
                groups[g].members.append(i)
                groups[g].centroid = normalized(groups[g].sum)
                groups[g].constraints.add(faces[i])
            } else {
                var constraints = Constraints()
                constraints.add(faces[i])
                groups.append((work[i].vector, work[i].vector, [i], constraints))
            }
        }
        for group in groups {
            let id: UUID? = group.members.count >= minimumGroup ? UUID() : nil
            for i in group.members {
                result[work[i].key] = id
            }
        }
        // Faces freed by regrouping that found no group lose their person.
        for (i, face) in faces.enumerated() where face.personID != nil && work[i].personID == nil && result[face.key] == nil {
            result[face.key] = .some(nil)
        }
        let before = Dictionary(faces.map { ($0.key, $0.personID) }, uniquingKeysWith: { a, _ in a })
        return result.filter { key, value in before[key] ?? nil != value }
    }

    static func zeros(_ n: Int) -> [Float] {
        [Float](repeating: 0, count: n)
    }

    static func add(_ v: [Float], to sum: inout [Float]) {
        vDSP_vadd(sum, 1, v, 1, &sum, 1, vDSP_Length(v.count))
    }
}
