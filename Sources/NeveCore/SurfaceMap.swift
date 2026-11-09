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
        let runs = surfaces[si].runs
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
}

extension SnowField {
    /// Overlap: a front window hiding the back one with its top 1...maxDrift above joins at its side edge(s) (the back snow drifts up
    /// to the front top). Side by side: gap <= 6 and tops within 4 join both ends. Rects are front to back.
    func computeSeams(rects: [CGRect], windows: [WindowInfo]) -> [SeamLink] {
        var out: [SeamLink] = []
        for i in rects.indices where windows[i].number != 0 {
            for k in (i + 1)..<max(rects.count, i + 1) where windows[k].number != 0 {
                let f = rects[i], b = rects[k], step = f.maxY - b.maxY
                if step > 1, step <= CGFloat(Tuning.maxDrift), f.minY <= b.maxY + 1 {
                    if b.minX < f.minX - 2, f.minX < b.maxX - 2 { out.append(SeamLink(left: windows[k].number, right: windows[i].number, rightSupported: true)) }
                    if f.maxX < b.maxX - 2, f.maxX > b.minX + 2 { out.append(SeamLink(left: windows[i].number, right: windows[k].number, leftSupported: true)) }
                } else if abs(step) <= 4 {
                    let l = f.minX < b.minX ? f : b, r = f.minX < b.minX ? b : f
                    if r.minX - l.maxX >= 0, r.minX - l.maxX <= 6 {
                        out.append(SeamLink(left: windows[f.minX < b.minX ? i : k].number, right: windows[f.minX < b.minX ? k : i].number, leftSupported: true, rightSupported: true))
                    }
                }
            }
        }
        return out
    }
}
