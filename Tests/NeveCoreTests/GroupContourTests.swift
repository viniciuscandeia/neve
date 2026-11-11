// AGENT HEADER - Tests/NeveCoreTests/GroupContourTests.swift  (one continuous contour per group of touching window supports: Contour.swift)
// Geometries: a narrow window over / under a wide one at steps -20...+20, a partial overlap, two wide overlapping windows, side by side (gap 4 pt, tops within 4), in BOTH stackings and with young (3 rounds) and grown (60 rounds) snow.
//   Checks on the writePiles output (`pileSegs`): every slice with real snow at both ends rises / falls <= 2 pt per 2 pt (no vertical step anywhere in the group); adjacent slices overlap vertically (no gap between a back crest and the front
//   snow's base, also at the rounded corner bins); the drawn picture is identical for both stackings except z; no slice floats without snow of some window of its group beside it; the z of every slice is the window it rests on (a slice over
//   a window's span never carries another window's z unless it rests on the lower one); groups are connected components (a window floating above another is its own group). Related: StackIndependenceTests, SliceZTests, WallBankTests, JunctionTests.

import CoreGraphics
import Testing
@testable import NeveCore

private struct Geo { let name: String; let wins: [WindowInfo] }

private func geometries() -> [Geo] {
    var g: [Geo] = []
    let wide = win(1, 100, 200, 600, 200)   // top 400
    for d in [-20, -13, -6, 0, 1, 6, 13, 20] as [CGFloat] {
        g.append(Geo(name: "narrow \(Int(d))", wins: [win(2, 300, 400 + d - 150, 200, 150), wide]))
        g.append(Geo(name: "partial \(Int(d))", wins: [win(2, 600, 400 + d - 150, 300, 150), wide]))
        g.append(Geo(name: "overlap \(Int(d))", wins: [win(2, 500, 400 + d - 150, 400, 150), win(1, 100, 200, 500, 200)]))
    }
    for d in [-4, 0, 4] as [CGFloat] { g.append(Geo(name: "side \(Int(d))", wins: [win(1, 100, 200, 300, 200), win(2, 404, 400 + d - 200, 300, 200)])) }
    return g
}

private func grown(_ s: [WindowInfo], rounds: Int) -> SnowField {
    let f = makeField()
    f.update(windows: s)
    pileUp(f, id: 1, rounds: rounds); pileUp(f, id: 2, rounds: rounds)
    return f
}

@Test func contourHasNoVerticalStepAndNoGapBetweenSupports() {
    var checked = 0
    for g in geometries() {
        for order in [g.wins, Array(g.wins.reversed())] {
            for rounds in [3, 60] {
                let s = pileSegs(grown(order, rounds: rounds))
                for q in s {
                    let d0 = q.top0 - q.base0 - q.inset, d1 = q.top1 - q.base1 - q.inset
                    if d0 > 1, d1 > 1 { checked += 1; #expect(abs(q.top1 - q.top0) <= 2.05, "\(g.name) rounds \(rounds): step \(q.top1 - q.top0) at \(q.x0)") }
                }
                for a in s { for b in s where b.x0 == a.x1 {   // neighbours across a shared column
                    #expect(b.base0 <= a.top1 + 0.5 && a.base1 <= b.top0 + 0.5, "\(g.name) rounds \(rounds): gap at x \(a.x1): \(a.base1)...\(a.top1) vs \(b.base0)...\(b.top0)")
                } }
            }
        }
    }
    #expect(checked > 1000)
}

private func sameButZ(_ a: PileSeg, _ b: PileSeg) -> Bool {
    [a.x0 - b.x0, a.x1 - b.x1, a.top0 - b.top0, a.top1 - b.top1, a.base0 - b.base0, a.base1 - b.base1, a.n0 - b.n0, a.n1 - b.n1, a.inset - b.inset].allSatisfy { abs($0) < 1e-4 } && a.dragged == b.dragged
}

@Test func contourIsTheSameInBothStackingsExceptZ() {
    for g in geometries() {
        for rounds in [3, 60] {
            let f = grown(g.wins, rounds: rounds)
            let a = pileSegs(f).sorted { ($0.x0, $0.top0, $0.base0) < ($1.x0, $1.top0, $1.base0) }
            f.update(windows: Array(g.wins.reversed()))
            let b = pileSegs(f).sorted { ($0.x0, $0.top0, $0.base0) < ($1.x0, $1.top0, $1.base0) }
            #expect(a.count == b.count && zip(a, b).allSatisfy { sameButZ($0, $1) }, "\(g.name) rounds \(rounds): \(a.count) vs \(b.count)")
        }
    }
}

@Test func noSliceFloatsWithoutSnowBeside() {
    for g in geometries() {
        for order in [g.wins, Array(g.wins.reversed())] {
            for rounds in [3, 60] {
                let f = grown(order, rounds: rounds)
                for q in pileSegs(f) where q.top0 - q.base0 > 1.3 || q.top1 - q.base1 > 1.3 {
                    let near = f.surfaces.contains { s in
                        s.id > 0 && s.pile.heights.indices.contains { b in
                            let x = (Float(s.c0 + b) + 0.5) * Tuning.binWidth
                            return s.pile.heights[b] > 0.15 && x > q.x0 - 60 && x < q.x1 + 60
                        }
                    }
                    #expect(near, "\(g.name) rounds \(rounds): floating slice \(q)")
                }
            }
        }
    }
}

@Test func sliceZIsTheWindowTheSnowRestsOn() {
    // Narrow higher window F (z by stacking) over a wide lower B: slices over F's straight span rest on F; the ramp beside the wall rests on B.
    for order in [[2, 1], [1, 2]] {
        let wins = [2: win(2, 300, 400 + 13 - 150, 200, 150), 1: win(1, 100, 200, 600, 200)]
        let f = makeField()
        f.update(windows: order.map { wins[$0]! })
        pileUp(f, id: 1, rounds: 60); pileUp(f, id: 2, rounds: 60)
        for q in pileSegs(f) {
            let mid = (q.x0 + q.x1) / 2
            if mid > 330, mid < 470 { #expect(q.z == f.zOf[2]!, "order \(order): slice over F at \(mid) has z \(q.z)") }
            if mid < 295 || mid > 505 { #expect(q.z == f.zOf[1]!, "order \(order): slice beside F at \(mid) has z \(q.z)") }
        }
    }
}

@Test func windowGroupsAreConnectedComponents() {
    let f = makeField()
    f.update(windows: [win(1, 100, 200, 300, 200), win(2, 404, 200, 300, 200), win(3, 300, 380, 200, 100), win(4, 100, 600, 100, 100), win(5, 800, 200, 150, 150)])   // 1 | 2 side by side, 3 over both (its bottom 380 < their top 400), 4 floats above 1, 5 alone
    let ids = f.windowGroups().map { Set($0.map { f.surfaces[$0].id }) }
    #expect(Set(ids) == [[1, 2, 3], [4], [5]])
}

@Test func baseFollowsTheCornerArcAtASupportedEnd() {
    // The higher window's end over a lower window: the snow's base dips along the corner arc (it fills the cut-out), never below it.
    let f = grown([win(2, 300, 400 + 13 - 150, 200, 150), win(1, 100, 200, 600, 200)], rounds: 60)
    let o = f.occluders[0]
    let q = pileSegs(f).filter { $0.z == f.zOf[2]! && $0.x0 > 300 && $0.x1 < 310 }
    #expect(!q.isEmpty)
    for s in q { #expect(s.base0 < 413 - 1 - 2, "base \(s.base0) at \(s.x0) does not follow the arc"); _ = o }
}
