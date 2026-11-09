import CoreGraphics
import Foundation
import Testing
@testable import NeveCore

// A drag sample changes one window's frame: `update` rebuilds just that window and the ones its x-range meets (`movedOnly`).
// It must leave exactly the state a full rebuild leaves.

private func scene(_ dragX: CGFloat, _ dragY: CGFloat) -> [WindowInfo] {
    [win(2, dragX, dragY, 220, 140), win(1, 100, 300, 250, 120), win(3, 800, 250, 150, 100), win(4, 553, 380, 150, 90), win(5, 330, 200, 190, 120), win(6, 640, 120, 100, 90)]
}

private func same(_ a: SnowField, _ b: SnowField) -> Bool {
    a.surfaces.count == b.surfaces.count && zip(a.surfaces, b.surfaces).allSatisfy {
        $0.id == $1.id && $0.frame == $1.frame && $0.cover == $1.cover && $0.runs == $1.runs && $0.vel == $1.vel && $0.c0 == $1.c0
            && $0.pile.heights == $1.pile.heights && $0.pile.shown == $1.pile.shown && $0.pile.visible == $1.pile.visible && $0.pile.cap == $1.pile.cap
            && $0.pile.base == $1.pile.base && $0.pile.boost == $1.pile.boost && $0.pile.walls == $1.pile.walls && $0.pile.supportL == $1.pile.supportL && $0.pile.supportR == $1.pile.supportR
    } && a.seams.map { [$0.left, $0.right] } == b.seams.map { [$0.left, $0.right] } && a.debris.count == b.debris.count
}

@Test func movedOnlyPicksTheDraggedWindowAndItsXNeighbours() {
    let f = makeField()
    let a = scene(10, 500), b = scene(30, 500)
    #expect(f.movedOnly(b, prev: a) == [1, 2, Tuning.groundID])   // x 2...258 (+-8) meets window 1 (100...350), not 5 (330...)
    var c = b; c[0] = win(2, 30, 500, 220, 140); c.swapAt(1, 2)
    #expect(f.movedOnly(c, prev: b) == nil)   // order changed
    #expect(f.movedOnly(b, prev: b) == nil)
    #expect(f.movedOnly(Array(b.dropFirst()), prev: b) == nil)
}

private func why(_ a: SnowField, _ b: SnowField) -> String {
    for (x, y) in zip(a.surfaces, b.surfaces) {
        if x.id != y.id { return "id" }
        if x.cover != y.cover { return "cover \(x.id)" }
        if x.runs != y.runs { return "runs \(x.id)" }
        if x.vel != y.vel { return "vel \(x.id) \(x.vel) \(y.vel)" }
        if x.pile.heights != y.pile.heights { return "heights \(x.id)" }
        if x.pile.shown != y.pile.shown { return "shown \(x.id)" }
        if x.pile.visible != y.pile.visible { return "visible \(x.id)" }
        if x.pile.cap != y.pile.cap { return "cap \(x.id)" }
        if x.pile.boost != y.pile.boost || x.pile.walls != y.pile.walls { return "boost/walls \(x.id)" }
    }
    return a.debris.count == b.debris.count ? "seams" : "debris"
}

@Test func dragSamplesGiveTheSameFieldAsFullRebuilds() {
    let a = makeField(seed: 3), b = makeField(seed: 3)
    b.dragOnlyRebuild = false
    for f in [a, b] {
        f.update(windows: scene(10, 500))
        for id in 1...6 { pileUp(f, id: id, rounds: 8) }
        pileUp(f, id: Tuning.groundID, rounds: 6)
    }
    for k in 1...60 {
        let x = 10 + CGFloat(k) * 12, y = 500 - CGFloat(k % 20) * 9
        for f in [a, b] { f.update(windows: scene(x, y), dt: 0.04); f.step(dt: 0.04) }
        if !same(a, b) { FileHandle.standardError.write(Data("DIFF \(k) \(why(a, b))\n".utf8)); #expect(Bool(false)) }
    }
}
