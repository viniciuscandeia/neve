// AGENT HEADER - Tests/NeveCoreTests/SeamExchangeTests.swift  (snow is one mass: order-independent growth, exchange across seams)
// Covers phase 3 of "snow is one mass": (1) a field grown by snowfall with a fixed seed is IDENTICAL in every stacking order (landing support = not under another window's body, `cap` from geometry), for several geometries (wall, side by side, partial
//   overlap, a window floating above another); (2) Seams.stepSeams relaxes across a joint conserving volume; (3) a cursor heap pushed into a touching neighbour continues there (no debris at the joint); (4) a snowman walks across two touching windows
//   (Walk.transfer over `touching`); (5) an avalanche front crosses the seam onto the neighbour; (6) YOUNG snow (few rounds, both stackings): no vertical step > ~2 pt per bin across the junction of a wall relation, and the higher window's end is not
//   bare (supportL / supportR: no taper, no corner dip). Related: StackIndependenceTests, WallBankTests, SurfaceMap.computeSeams, Seams.swift.

import CoreGraphics
import Testing
@testable import NeveCore

private let geoms: [(name: String, wins: [WindowInfo])] = [
    ("wall", [win(1, 100, 200, 600, 200), win(2, 300, 263, 200, 150)]),                // higher narrow window inside a wide one
    ("side", [win(1, 100, 200, 300, 200), win(2, 403, 200, 300, 200)]),                // touching, same tops
    ("overlap", [win(1, 100, 200, 400, 200), win(2, 350, 250, 400, 158)]),             // partial overlap, front 8 pt higher
    ("roof", [win(1, 100, 100, 500, 200), win(2, 250, 340, 300, 200)])                 // a window floating above another (cap)
]

@Test func fieldGrownBySnowfallIsIdenticalInEveryStackingOrder() {
    for g in geoms {
        var grown: [[Int: [Float]]] = []
        for order in [g.wins, g.wins.reversed()] {
            let f = makeField(flakes: 500, seed: 11)
            f.update(windows: order)
            for _ in 0..<2400 { f.time += 1.0 / 60; f.stepFlakes(dt: 1 / 60); f.stepSeams() }   // snowfall + group exchange only: the other steps pick random surfaces by list index
            grown.append(Dictionary(uniqueKeysWithValues: f.surfaces.filter { $0.id > 0 }.map { ($0.id, $0.pile.heights) }))
        }
        for id in grown[0].keys {
            let a = grown[0][id]!, b = grown[1][id]!
            let d = zip(a, b).map { abs($0 - $1) }.max() ?? 0
            #expect(d < 0.01, "\(g.name) window \(id): grown heights differ between stackings by \(d)")
            #expect((a.max() ?? 0) > 0.5, "\(g.name) window \(id): nothing grew")
        }
    }
}

private func touchingField() -> SnowField {
    let f = makeField()
    f.update(windows: [win(1, 100, 200, 300, 200), win(2, 403, 200, 300, 200)])
    return f
}

private func volume(_ f: SnowField) -> Float { f.surfaces.filter { $0.id > 0 }.reduce(0) { $0 + $1.pile.heights.reduce(0, +) } }

@Test func relaxAcrossASeamConservesVolumeAndLevelsTheJoint() {
    let f = touchingField()
    let a = f.index[1]!, b = f.index[2]!, n = f.surfaces[a].pile.heights.count
    for k in (n - 6)..<n { f.surfaces[a].pile.heights[k] = 14 }
    let v0 = volume(f)
    for _ in 0..<600 { f.stepSeams() }
    #expect(abs(volume(f) - v0) < 0.05, "volume \(v0) -> \(volume(f))")
    #expect(f.surfaces[b].pile.heights[0] > 1, "nothing crossed the joint")
    let ta = f.surfaces[a].pile.heights[n - 1], tb = f.surfaces[b].pile.heights[0]
    #expect(abs(ta - tb) <= Tuning.slope + 0.5, "joint not levelled: \(ta) vs \(tb)")
}

@Test func aHeapPushedIntoATouchingNeighbourContinuesThereWithoutDebris() {
    let f = touchingField()
    let a = f.index[1]!, b = f.index[2]!
    var lo = Int.max, hi = Int.min, end: Float = 0, endY: Float = 0
    let debris0 = f.debris.count
    let banked = f.berm(a, atX: 396, dir: 1, area: 600, lo: &lo, hi: &hi, end: &end, endY: &endY)
    #expect(banked > 599, "banked \(banked)")
    #expect(f.surfaces[b].pile.heights.prefix(20).contains { $0 > 1 }, "the heap did not continue onto the neighbour")
    #expect(f.debris.count == debris0)
}

@Test func aSnowmanWalksAcrossTwoTouchingWindows() {
    for auto in [false, true] {
        let f = touchingField()
        pileUp(f, id: 1); pileUp(f, id: 2)
        let id = auto ? standAuto(f, x: 330, on: 1) : stand(f, x: 330, on: 1)
        let i = f.figureIndex(id)!
        f.figures[i].facing = 1; f.figures[i].motion.nextIdle = 1e6; f.figures[i].motion.speed = Tuning.walkSpeed
        var seen = false
        for _ in 0..<(60 * 60) {
            f.step(dt: 1 / 60)
            if fig(f, id).surfaceID == 2 { seen = true; break }
        }
        #expect(seen, "the snowman never crossed onto the touching window (auto \(auto))")
    }
}

@Test func anAvalancheFrontCrossesTheSeamOntoTheNeighbour() {
    let f = touchingField()
    pileUp(f, id: 1); pileUp(f, id: 2)
    #expect(f.startFront(si: f.index[1]!, x: 350))
    var crossed = false
    for _ in 0..<(60 * 6) {
        f.step(dt: 1 / 60)
        if f.chain.fronts.contains(where: { $0.win == 2 }) { crossed = true; break }
    }
    #expect(crossed)
}

@Test func youngSnowHasNoVerticalStepAtTheJunctionAndTheHigherEndIsNotBare() {
    for step in [6, 13, 20, 40] as [CGFloat] {
        for order in [[2, 1], [1, 2]] {
            let f = makeField()
            let wins = [2: win(2, 300, 400 + step - 150, 200, 150), 1: win(1, 100, 200, 600, 200)]
            f.update(windows: order.map { wins[$0]! })
            pileUp(f, id: 1, rounds: 3); pileUp(f, id: 2, rounds: 3)
            let h = f.pile(id: 2)!
            #expect(h.supportL && h.supportR, "step \(step): the higher window's ends are part of the group")
            let mid = h.heights[h.heights.count / 2]
            #expect(h.heights[0] > 0.5 * mid && h.heights[h.heights.count - 1] > 0.5 * mid, "step \(step) order \(order): bare corner zone \(h.heights[0]) / \(h.heights[h.heights.count - 1]) vs \(mid)")
            let low = f.pile(id: 1)!
            for k in low.heights.indices.dropFirst() where low.visible[k] && low.visible[k - 1] && low.hideTop[k] <= 0 && low.hideTop[k - 1] <= 0 {
                let d = abs(low.heights[k] - low.heights[k - 1])
                #expect(d <= 2.2, "step \(step) order \(order): stored step \(d) at bin \(k)")
            }
        }
    }
}
