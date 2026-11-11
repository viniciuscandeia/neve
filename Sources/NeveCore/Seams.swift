// AGENT HEADER - Sources/NeveCore/Seams.swift  (snow groups: touching supports exchange snow across their seams)
// Role: supports that touch (`SeamLink`s from computeSeams: side by side within 6 pt, or a higher window's end over a lower window's top edge) form a GROUP: one mass of snow. `joints()` turns the links into end bin pairs (A = the left pile, B = the right one,
//   `ab` / `bb` the bins facing each other: the pile end for side by side and for the HIGHER window of an overlap, the bin next to the wall for the lower one), from frames only (never the stacking order). `stepSeams()` (SnowField.step, after stepSlump)
//   relaxes every joint with the same slope rule as Pile.relax (excess over Tuning.slope on absolute tops moves half to the lower side, bounded by the receiver's limit / cap, volume conserved) and settles both sides around it; it is O(joints) per frame
//   (nothing happens while the joint is within the slope), skips the window being dragged and `open` rules apply (covered / hidden bins are walls). `neighbor(si:dir:)` = the surface touching si's END in direction dir and the bin where snow enters it
//   (cursor berm continuation in Surfaces.berm: at a pile end, or against a higher window's side mid-pile (bank up its side to its top, the rest on its pile), wind-leeward hop in Flakes.tryLand, avalanche continuation in Avalanche); `touching(id:dir:)` = ids of windows whose wall / seam meets id's walkable stretch (Walk.transfer).
// Tests: SeamExchangeTests.

import CoreGraphics
import Foundation

struct Joint { let a: Int, ab: Int, b: Int, bb: Int }   // surface indices (a = left pile) and the facing bins

extension SnowField {
    func joints() -> [Joint] {
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

    /// The surface touching `si`'s end in direction `dir` (+1 right, -1 left) and the bin of it that receives snow there.
    /// `bin` = the bin of `si` facing the joint: nil = its end (the pile end), else a wall mid-pile (the bin next to a higher window's side).
    func neighbor(si: Int, dir: Int, bin: Int? = nil) -> (si: Int, bin: Int)? {
        guard !seams.isEmpty else { return nil }
        for j in joints() {
            if dir > 0, j.a == si, j.ab == bin ?? surfaces[si].pile.heights.count - 1 { return (j.b, j.bb) }
            if dir < 0, j.b == si, j.bb == bin ?? 0 { return (j.a, j.ab) }
        }
        return nil
    }

    /// Window ids that meet window `id` on its right (dir > 0) or left: a seam or a wall (any link, whatever the heights; the caller checks steps).
    func touching(id: Int, dir: Float) -> [Int] {
        seams.compactMap { dir > 0 ? ($0.left == id ? $0.right : nil) : ($0.right == id ? $0.left : nil) }
    }

    func stepSeams() {
        guard !seams.isEmpty, !quiet else { return }
        for j in joints() {
            let ia = surfaces[j.a].id, ib = surfaces[j.b].id
            guard ia != draggingID, ib != draggingID, landable(j.a), landable(j.b) else { continue }
            guard surfaces[j.a].pile.open(j.ab), surfaces[j.b].pile.open(j.bb) else { continue }
            let ta = surfaces[j.a].edgeY + surfaces[j.a].pile.base[j.ab] + surfaces[j.a].pile.heights[j.ab]
            let tb = surfaces[j.b].edgeY + surfaces[j.b].pile.base[j.bb] + surfaces[j.b].pile.heights[j.bb]
            let (from, fb, to, tbn) = ta > tb ? (j.a, j.ab, j.b, j.bb) : (j.b, j.bb, j.a, j.ab)
            let excess = abs(ta - tb) - Tuning.slope
            guard excess > 0, surfaces[from].pile.heights[fb] > Tuning.speckFloor else { continue }
            let hf = surfaces[from].pile.heights[fb], ht = surfaces[to].pile.heights[tbn]
            let m = min(excess * 0.5, hf, max(surfaces[to].pile.limit(tbn) - ht, 0), max(surfaces[to].pile.cap[tbn] - ht, 0))
            guard m > 0.001 else { continue }
            surfaces[from].pile.heights[fb] = hf - m
            surfaces[to].pile.heights[tbn] = ht + m
            for (s, b) in [(from, fb), (to, tbn)] {
                if !surfaces[s].pile.mound.isEmpty { surfaces[s].pile.trackMound(b) }
                surfaces[s].pile.settle(max(b - 3, 0), min(b + 3, surfaces[s].pile.heights.count - 1))
            }
            pilesDirty = true
        }
    }
}
