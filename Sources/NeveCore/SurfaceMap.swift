// AGENT HEADER - Sources/NeveCore/SurfaceMap.swift  (Surface record, column index, seams between window piles)
// Role: `Surface` (id: window number, 0 = Dock bar, Tuning.groundID = screen bottom; unclipped local frame, edgeY = top edge height, c0 = first GLOBAL column, anchor, pile, vel, radius, cover = rects of windows in front, runs = visible local-bin ranges, aliveRuns = runs plus bins hidden only by stacking order) and `Entry`.
//   The per-column index is CSR: `offsets[col]..<offsets[col+1]` into `entries` (surface index + edgeY, ordered front to back per column), rebuilt by buildColumns() whenever surfaces change; flakes use it to find what they land on.
//   Helpers: column(x), edgeVisible, surface(id:), pile(id:), meanHeight(si:col:span:), visibleRun(si:bin:) (binary search).
//   `SeamLink` + computeSeams(rects:windows:): windows whose piles read as ONE snowbank (side by side gap <= 6 pt with tops within 4, or overlapped with the front top 1...maxDrift above / up to maxPileHeight/2 below). `*Supported` ends
//   hold snow against the neighbour (no dip, taper or spill); `front` = id of the HIGHER window of an overlap junction (stacking order never matters; 0 = side by side). Render.writePiles `junctions()` / `blendCrest` draw the merged crest (smoothstep saddle, half-width min(80, max(16, 6 * crest difference)) pt; heap-guarded, skipped while one side is dragged).
// Rects are front to back; coordinates local AppKit y-up pt. Callers: Surfaces.swift (rebuild), Render.swift, Flakes.swift (landing), Walk/Figures (standing surfaces). Tests: SurfaceMapTests, JunctionTests, LowSeamTests.

import CoreGraphics
import Foundation

struct Surface {
    let id: Int          // window number; 0 = Dock bar, Tuning.groundID = screen bottom
    let frame: CGRect    // unclipped, local coords
    let edgeY: Float
    let c0: Int          // first global column
    let anchor: Int      // window's left edge in whole columns (absolute): pile moves are differences of these, so rounding never accumulates
    var pile: Pile
    var vel: SIMD2<Float> = .zero   // window velocity (pt/s) at the last poll that moved it
    var radius: Float = 0           // window corner radius (clamped to the frame), for ice hung along the silhouette
    var cover: [CGRect] = []        // windows in front that overlap this frame (local coords): clip the frost lip and icicles
    var aliveRuns: [Range<Int>] = []   // runs + bins hidden only by stacking order (physics: walkers, robins, avalanches)
    var runs: [Range<Int>] = []     // visible stretches of the pile (local bins), set when the surfaces are built
}

struct Entry {
    let surface: Int32
    let edgeY: Float
}

extension SnowField {
    func column(_ x: Float) -> Int {
        let c = x * invBin
        return c.isNaN ? 0 : Int(min(max(c, 0), Float(numCols - 1)))   // NaN / inf / huge never reach Int(): that traps
    }

    func edgeVisible(id: Int, x: Float) -> Bool {
        let c = column(x)
        for k in Int(offsets[c])..<Int(offsets[c + 1]) where surfaces[Int(entries[k].surface)].id == id { return true }
        return false
    }

    func surface(id: Int) -> Int? { index[id] }

    func pile(id: Int) -> Pile? { index[id].map { surfaces[$0].pile } }

    /// Mean pile height over the global columns col-span...col+span (clipped to the surface); nil when `col` is off it.
    func meanHeight(si: Int, col: Int, span: Int) -> Float? {
        let c = col - surfaces[si].c0, n = surfaces[si].pile.heights.count
        guard c >= 0, c < n else { return nil }
        let lo = max(0, c - span), hi = min(n - 1, c + span)
        var sum: Float = 0
        for b in lo...hi { sum += surfaces[si].pile.heights[b] }
        return sum / Float(hi - lo + 1)
    }

    /// The visible run (local bins) containing local bin `c`, by binary search.
    func visibleRun(si: Int, bin c: Int) -> Range<Int>? {
        let runs = surfaces[si].aliveRuns
        var lo = 0, hi = runs.count
        while lo < hi {
            let m = (lo + hi) / 2
            if runs[m].upperBound <= c { lo = m + 1 } else { hi = m }
        }
        return lo < runs.count && runs[lo].contains(c) ? runs[lo] : nil
    }

    func buildColumns() {
        for i in offsets.indices { offsets[i] = 0 }
        for s in surfaces {
            for b in s.pile.heights.indices where s.pile.visible[b] { offsets[s.c0 + b + 1] += 1 }
        }
        for c in 0..<numCols { offsets[c + 1] += offsets[c] }
        entries = [Entry](repeating: Entry(surface: 0, edgeY: 0), count: Int(offsets[numCols]))
        var fill = offsets
        for (si, s) in surfaces.enumerated() {
            for b in s.pile.heights.indices where s.pile.visible[b] {
                let c = s.c0 + b
                entries[Int(fill[c])] = Entry(surface: Int32(si), edgeY: s.edgeY + s.pile.base[b])
                fill[c] += 1
            }
        }
    }
}

/// Two window piles that read as one snowbank: `left`'s right end meets `right`'s left end (surface ids).
/// `*Supported`: that end holds snow against the other side (no dip, taper or spill).
struct SeamLink {
    let left: Int, right: Int
    var leftSupported = false, rightSupported = false
    var front = 0   // overlap junction: id of the front window (the other one is behind it); 0 = side by side
}

extension SnowField {
    /// Order independent (frames only; the list index only enumerates pairs): of two windows the one with the HIGHER top (`H`; equal tops: the narrower, then the lower window number) is the wall / `front` of the link, the other one the lower window `L`.
    /// Overlap: H's top 1...maxDrift above L's, its side edge(s) inside L's span: L's snow drifts up to H's top and H's end holds snow against it (`*Supported`). Overlap with tops within 1 pt: a junction without support. Side by side:
    /// gap 0...6 and tops within 4 join both ends. The draw merges L's crest into H's slices (see `junctions`).
    func computeSeams(rects: [CGRect], windows: [WindowInfo]) -> [SeamLink] {
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
