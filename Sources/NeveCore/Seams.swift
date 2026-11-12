// AGENT HEADER - Sources/NeveCore/Seams.swift  (snow groups: touching supports exchange snow across their seams)
// Role: supports that touch (`SeamLink`s from SurfaceSet.computeSeams: side by side within 6 pt, or a higher window's end over a lower window's top edge) form a GROUP: one mass of snow. `SurfaceSet.joints` (computed once per rebuild) turns the links into end bin pairs (A = the left pile, B = the right one,
//   `ab` / `bb` the bins facing each other: the pile end for side by side and for the HIGHER window of an overlap, the bin next to the wall for the lower one), from frames only (never the stacking order). `stepSeams()` (SnowField.step, after stepSlump)
//   relaxes every joint with THE rule of Pile.relax (Pile.transfer: excess over Tuning.slope + the dustSlope allowance onto a thin bin, on absolute tops, moves half to the lower side, bounded by the receiver's limit / cap, volume conserved) and settles both sides around it; it is O(joints) per frame
//   (nothing happens while the joint is within the slope), skips the window being dragged and `open` rules apply (covered / hidden bins are walls). `neighbor(si:dir:)` = the surface touching si's END in direction dir and the bin where snow enters it
//   (cursor berm continuation in Surfaces.berm: at a pile end, or against a higher window's side mid-pile (bank up its side to its top, the rest on its pile), wind-leeward hop in Flakes.tryLand, avalanche continuation in Avalanche); `touching(id:dir:)` = ids of windows whose wall / seam meets id's walkable stretch (Walk.transfer).
// Tests: SeamExchangeTests.

import CoreGraphics
import Foundation

struct Joint { let a: Int, ab: Int, b: Int, bb: Int }   // surface indices (a = left pile) and the facing bins

extension SnowField {
    /// The surface touching `si`'s end in direction `dir` (+1 right, -1 left) and the bin of it that receives snow there.
    /// `bin` = the bin of `si` facing the joint: nil = its end (the pile end), else a wall mid-pile (the bin next to a higher window's side).
    func neighbor(si: Int, dir: Int, bin: Int? = nil) -> (si: Int, bin: Int)? {
        guard !seams.isEmpty else { return nil }
        for j in sset.joints {
            if dir > 0, j.a == si, j.ab == bin ?? surfaces[si].pile.heights.count - 1 { return (j.b, j.bb) }
            if dir < 0, j.b == si, j.bb == bin ?? 0 { return (j.a, j.ab) }
        }
        return nil
    }

    /// Window ids that meet window `id` on its right (dir > 0) or left: a seam or a wall (any link, whatever the heights; the caller checks steps).
    func touching(id: Int, dir: Float) -> [Int] {
        seams.compactMap { dir > 0 ? ($0.left == id ? $0.right : nil) : ($0.right == id ? $0.left : nil) }
    }

    /// Fixed 1/60 s substeps owed by `clock` after `dt` (at most 2 a frame): slow work that must not depend on the frame rate (stepSeams, the Dock bank's relax).
    func substeps(_ clock: inout Float, dt: Float) -> Int {
        clock = min(clock + dt, 2.0 / 60)
        var n = 0
        while clock >= 1.0 / 60 { clock -= 1.0 / 60; n += 1 }
        return n
    }

    func stepSeams(dt: Float = 1.0 / 60) {
        guard !seams.isEmpty, !quiet else { seamClock = 0; return }
        for _ in 0..<substeps(&seamClock, dt: dt) { stepSeamsOnce() }
    }

    private func stepSeamsOnce() {
        for j in sset.joints {
            let ia = surfaces[j.a].id, ib = surfaces[j.b].id
            guard ia != draggingID, ib != draggingID, landable(j.a), landable(j.b) else { continue }
            guard surfaces[j.a].pile.open(j.ab), surfaces[j.b].pile.open(j.bb) else { continue }
            let ta = surfaces[j.a].edgeY + surfaces[j.a].pile.base[j.ab] + surfaces[j.a].pile.heights[j.ab]
            let tb = surfaces[j.b].edgeY + surfaces[j.b].pile.base[j.bb] + surfaces[j.b].pile.heights[j.bb]
            let (from, fb, to, tbn) = ta > tb ? (j.a, j.ab, j.b, j.bb) : (j.b, j.bb, j.a, j.ab)
            let hf = surfaces[from].pile.heights[fb], ht = surfaces[to].pile.heights[tbn]
            let m = min(Pile.transfer(drop: abs(ta - tb), from: hf, to: ht, toCap: surfaces[to].pile.cap[tbn], age: surfaces[from].pile.age[fb]), max(surfaces[to].pile.limit(tbn) - ht, 0))   // the shared rule, and never past the receiver's limit
            guard m > 0.001 else { continue }
            surfaces[from].pile.heights[fb] = hf - m
            surfaces[to].pile.heights[tbn] = ht + m
            surfaces[to].pile.mixAge(tbn, added: m, age: surfaces[from].pile.age[fb])
            for (s, b) in [(from, fb), (to, tbn)] {
                if !surfaces[s].pile.mound.isEmpty { surfaces[s].pile.trackMound(b) }
                surfaces[s].pile.settle(max(b - 3, 0), min(b + 3, surfaces[s].pile.heights.count - 1))
            }
            pilesDirty = true
        }
    }
}
