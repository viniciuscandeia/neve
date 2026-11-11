// AGENT HEADER - Sources/NeveCore/SurfaceMap.swift  (Surface record, column index, seams between window piles)
// Role: `Surface` (id: window number, 0 = Dock bar, Tuning.groundID = screen bottom; unclipped local frame, edgeY = top edge height, c0 = first GLOBAL column, anchor, pile, vel, radius, cover = rects of windows in front, runs = visible local-bin ranges, aliveRuns = runs plus bins hidden only by stacking order) and `Entry`.
//   The per-column index is CSR: `offsets[col]..<offsets[col+1]` into `entries` (surface index + edgeY, ordered front to back per column), rebuilt by SurfaceSet.install whenever surfaces change (SurfaceSet.swift owns the surfaces / index / columns / seams / occluders); flakes use it to find what they land on.
//   Helpers: column(x), edgeVisible, surface(id:), pile(id:), meanHeight(si:col:span:), visibleRun(si:bin:) (binary search).
//   `SeamLink` (computed by SurfaceSet.computeSeams(rects:windows:)): windows whose piles read as ONE snowbank (side by side gap <= 6 pt with tops within 4, or overlapped with the front top 1...maxDrift above / up to maxPileHeight/2 below). `*Supported` ends
//   hold snow against the neighbour (no dip, taper or spill); `front` = id of the HIGHER window of an overlap junction (stacking order never matters; 0 = side by side). Contour.swift draws every group (seams + walls) as one contour (slope-limited crest, owner = the open bin with the highest top).
// Rects are front to back; coordinates local AppKit y-up pt. Callers: Surfaces.swift (rebuild), Render.swift, Flakes.swift (landing), Walk/Figures (standing surfaces). Snow exchange across the links (relax, berm, hop, walk, avalanche): Seams.swift. Tests: SurfaceMapTests, JunctionTests, LowSeamTests, SeamExchangeTests.

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
}

/// Two window piles that read as one snowbank: `left`'s right end meets `right`'s left end (surface ids).
/// `*Supported`: that end holds snow against the other side (no dip, taper or spill).
struct SeamLink {
    let left: Int, right: Int
    var leftSupported = false, rightSupported = false
    var front = 0   // overlap junction: id of the front window (the other one is behind it); 0 = side by side
}
