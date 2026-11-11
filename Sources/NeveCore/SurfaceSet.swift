// AGENT HEADER - Sources/NeveCore/SurfaceSet.swift  (the surfaces of a screen and everything derived from them at rebuild time)
// Role: `SurfaceSet` (SnowField.sset; SnowField forwards `surfaces`, `index`, `offsets`, `entries`, `seams`, `occluders`, `zOf`, `groundZ` to it) owns the surface list, the id -> index map, the CSR column index (`offsets[col]..<offsets[col+1]` into `entries`,
//   front to back per column), the seam links, the pile-clip occluders / z numbers, and the two structures that depend only on frames and bin counts and so are computed ONCE per rebuild, not per frame: `joints` (Seams.swift: end bin pairs of the seams) and
//   `windowGroups` (Contour.swift: connected sets of window surfaces). `beginRebuild` sets seams / occluders / z from the snapshot rects (before the surfaces are built: buildSurface reads the seams), `install` stores the built surfaces and derives index / columns / joints / groups,
//   `reset` = Resize (ground only). Surface frame / c0 / id and a pile's bin count never change between rebuilds, which is why the derived data stays valid.
// Tests: SurfaceMapTests, JunctionTests, SeamExchangeTests, GroupContourTests.

import CoreGraphics
import Foundation

struct SurfaceSet {
    var surfaces: [Surface] = []
    var index: [Int: Int] = [:]   // surface id -> index into `surfaces`
    var offsets: [Int32]          // CSR: per column range into entries
    var entries: [Entry] = []
    var seams: [SeamLink] = []    // windows whose piles read as one snowbank (SurfaceMap.swift)
    var occluders: [Occluder] = []
    var zOf: [Int: UInt32] = [:]
    var groundZ: UInt32 = 0
    private(set) var joints: [Joint] = []
    private(set) var windowGroups: [[Int]] = []

    init(numCols: Int) { offsets = [Int32](repeating: 0, count: numCols + 1) }

    /// Seams, occluders and z from the snapshot (`rects` / `windows` front to back, local coords).
    mutating func beginRebuild(rects: [CGRect], windows: [WindowInfo], maxOccluders: Int) {
        seams = Self.computeSeams(rects: rects, windows: windows)
        occluders = Occluder.list(rects: rects, ids: windows.map(\.number), radii: windows.map(\.radius), limit: maxOccluders)
        zOf = Dictionary(windows.indices.map { (windows[$0].number, UInt32($0)) }, uniquingKeysWith: { a, _ in a })
        groundZ = UInt32(windows.count)
    }

    /// The built surfaces replace the old ones: index, column index, joints and groups follow.
    mutating func install(_ built: [Surface]) {
        surfaces = built
        index.removeAll(keepingCapacity: true)
        for (i, s) in surfaces.enumerated() { index[s.id] = i }
        buildColumns()
        joints = computeJoints()
        windowGroups = computeGroups()
    }

    /// Resize: a new column count and the ground as the only surface; no seams.
    mutating func reset(numCols: Int, ground: Surface) {
        offsets = [Int32](repeating: 0, count: numCols + 1)
        entries.removeAll()
        seams = []
        install([ground])
    }
    private mutating func buildColumns() {
        for i in offsets.indices { offsets[i] = 0 }
        for s in surfaces {
            for b in s.pile.heights.indices where s.pile.visible[b] { offsets[s.c0 + b + 1] += 1 }
        }
        for c in 0..<(offsets.count - 1) { offsets[c + 1] += offsets[c] }
        entries = [Entry](repeating: Entry(surface: 0, edgeY: 0), count: Int(offsets[(offsets.count - 1)]))
        var fill = offsets
        for (si, s) in surfaces.enumerated() {
            for b in s.pile.heights.indices where s.pile.visible[b] {
                let c = s.c0 + b
                entries[Int(fill[c])] = Entry(surface: Int32(si), edgeY: s.edgeY + s.pile.base[b])
                fill[c] += 1
            }
        }
    }

    private func computeJoints() -> [Joint] {
        var out: [Joint] = []
        for l in seams {
            guard let a = index[l.left], let b = index[l.right], l.leftSupported || l.rightSupported else { continue }
            let na = surfaces[a].pile.heights.count, nb = surfaces[b].pile.heights.count
            let aEnd = l.front == 0 || l.front == l.left, bEnd = l.front == 0 || l.front == l.right
            let ab = aEnd ? na - 1 : surfaces[b].c0 - 1 - surfaces[a].c0, bb = bEnd ? 0 : surfaces[a].c0 + na - surfaces[b].c0
            guard ab >= 0, ab < na, bb >= 0, bb < nb else { continue }
            out.append(Joint(a: a, ab: ab, b: b, bb: bb))
        }
        return out
    }

    /// Window surfaces (indices) that touch: linked by a seam, or one is a HIGHER window whose end lies over the other's top edge (frames only). Ordered by first member.
    private func computeGroups() -> [[Int]] {
        var parent = Array(surfaces.indices)
        func find(_ i: Int) -> Int { var r = i; while parent[r] != r { r = parent[r] }; var k = i; while parent[k] != r { let n = parent[k]; parent[k] = r; k = n }; return r }
        func union(_ a: Int, _ b: Int) { let x = find(a), y = find(b); if x != y { parent[max(x, y)] = min(x, y) } }
        for l in seams { if let a = index[l.left], let b = index[l.right] { union(a, b) } }
        let ws = surfaces.indices.filter { surfaces[$0].id > 0 }
        for (k, i) in ws.enumerated() {
            let a = surfaces[i].frame
            for j in ws[(k + 1)...] {
                let b = surfaces[j].frame
                guard a.minX < b.maxX - 2, b.minX < a.maxX - 2 else { continue }
                let hi = a.maxY >= b.maxY ? a : b, lo = a.maxY >= b.maxY ? b : a
                if hi.maxY - lo.maxY > 1, hi.minY <= lo.maxY + 1 { union(i, j) }
            }
        }
        var out: [[Int]] = [], at: [Int: Int] = [:]
        for i in ws {
            let r = find(i)
            if let g = at[r] { out[g].append(i) } else { at[r] = out.count; out.append([i]) }
        }
        return out
    }

    /// Order independent (frames only; the list index only enumerates pairs): of two windows the one with the HIGHER top (`H`; equal tops: the narrower, then the lower window number) is the wall / `front` of the link, the other one the lower window `L`.
    /// Overlap: H's top 1...maxDrift above L's, its side edge(s) inside L's span: L's snow drifts up to H's top and H's end holds snow against it (`*Supported`). Overlap with tops within 1 pt: a junction without support. Side by side:
    /// gap 0...6 and tops within 4 join both ends. The draw is one contour over the group (see Contour.swift).
    static func computeSeams(rects: [CGRect], windows: [WindowInfo]) -> [SeamLink] {
        var out: [SeamLink] = []
        for i in rects.indices where windows[i].number != 0 && !windows[i].occluderOnly {
            for k in (i + 1)..<max(rects.count, i + 1) where windows[k].number != 0 && !windows[k].occluderOnly {
                let iHigh = rects[i].maxY != rects[k].maxY ? rects[i].maxY > rects[k].maxY
                    : rects[i].width != rects[k].width ? rects[i].width < rects[k].width : windows[i].number < windows[k].number   // equal tops: the narrower one is the wall (it can sit inside the other)
                let hi = iHigh ? i : k, lo = iHigh ? k : i
                let f = rects[hi], b = rects[lo], step = f.maxY - b.maxY
                let fid = windows[hi].number, lid = windows[lo].number
                if f.minX < b.maxX - 2, f.maxX > b.minX + 2, step <= CGFloat(Tuning.maxDrift), f.minY <= b.maxY + 1 {
                    let sup = step > 1
                    if b.minX < f.minX - 2, f.minX < b.maxX - 2 { out.append(SeamLink(left: lid, right: fid, rightSupported: sup, front: fid)) }
                    if f.maxX < b.maxX - 2, f.maxX > b.minX + 2 { out.append(SeamLink(left: fid, right: lid, leftSupported: sup, front: fid)) }
                } else if step <= 4 {
                    let l = f.minX < b.minX ? f : b, r = f.minX < b.minX ? b : f
                    if r.minX - l.maxX >= 0, r.minX - l.maxX <= 6 {
                        out.append(SeamLink(left: f.minX < b.minX ? fid : lid, right: f.minX < b.minX ? lid : fid, leftSupported: true, rightSupported: true))
                    }
                }
            }
        }
        return out
    }
}
