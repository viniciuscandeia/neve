import CoreGraphics
import Testing
@testable import NeveCore

private func draw(_ body: (inout PrimWriter) -> Void) -> [Prim] {
    let p = UnsafeMutablePointer<Prim>.allocate(capacity: 400)
    defer { p.deallocate() }
    var w = PrimWriter(p, capacity: 400)
    body(&w)
    return (0..<w.n).map { p[$0] }
}

@Test func charactersStayWithinPrimCaps() {
    let pen = draw { Rig.penguin(PenguinLook(foot: SIMD2(100, 100)), contrast: true, into: &$0) }
    let rob = draw { Rig.robin(RobinLook(foot: SIMD2(100, 100)), contrast: true, into: &$0) }
    let rab = draw { Rig.rabbit(RabbitLook(foot: SIMD2(100, 100)), contrast: true, into: &$0) }
    #expect(pen.count <= 24 && rob.count <= 22 && rab.count <= 30)
    for deer in 2...4 {
        let s = draw { Rig.sleigh(SleighLook(pos: SIMD2(100, 700), deer: deer), contrast: true, into: &$0) }
        #expect(s.count <= 40 + 12 * deer)
    }
}

@Test func robinShadowSitsBelowTheBody() {
    let p = draw { Rig.robin(RobinLook(foot: SIMD2(100, 100), flying: true), contrast: false, into: &$0) }
    let shadow = p[0], body = p.first { $0.kind == 0 && $0.color.x > 0.4 && $0.color.x < 0.5 && $0.b.x > 4.3 }!
    #expect(shadow.a.y < body.a.y)
}

@Test func giftBouncesThenRestsSunk() {
    var g = Gift(pos: SIMD2(100, 100), vel: .zero, surface: 1, rot: 0, spin: 0, color: 0)
    func top(_ land: Float) -> Float {
        g.land = land
        let q = draw { Rig.gift(g, offset: .zero, contrast: false, into: &$0) }.first { $0.kind == 2 }!
        return max(q.a.y, q.b.y, q.c.y, q.d.y)
    }
    let rest = top(1)
    #expect(top(0.02) < rest)            // squashed on touch-down
    #expect(abs(top(0.17) - rest - 1.5) < 0.01)   // bounce peak
    #expect(top(0.5) == rest)
    let f = makeField(); f.update(windows: [])
    let gi = f.surfaces.firstIndex { $0.id == Tuning.groundID }!
    for b in 0..<500 { f.surfaces[gi].pile.heights[b] = 12 }
    f.dropGift(at: SIMD2(300, 200), dir: 0)
    advance(f, 4)
    let r = f.gifts[0]
    #expect(r.surface != nil && r.land > 0.27 && r.pos.y - f.standY(si: gi, x: 300) < r.size / 2)
}

@Test func cheerHopSquashesNearGround() {
    let f = makeField(); f.update(windows: [])
    let gi = f.surfaces.firstIndex { $0.id == Tuning.groundID }!
    for b in 0..<500 { f.surfaces[gi].pile.heights[b] = 12 }
    let id = standAuto(f, x: 300)
    advance(f, 0.6)
    f.figures[f.figureIndex(id)!].motion.cheer = 2
    var m: Float = 0
    for _ in 0..<60 { f.step(dt: 1 / 60); m = max(m, fig(f, id).pose.squash) }
    #expect(m > 0.05)
}

@Test func ghostRadiusFollowsTheBall() {
    let a = draw { Rig.shotGhost(pos: .zero, k: 1, radius: 3.6, into: &$0) }[0], b = draw { Rig.shotGhost(pos: .zero, k: 1, radius: 5.4, into: &$0) }[0]
    #expect(abs(b.b.x / a.b.x - 1.5) < 1e-4)
}

@Test func contrastChangesOutlineColors() {
    let lo = draw { Rig.sleigh(SleighLook(pos: SIMD2(100, 700)), contrast: false, into: &$0) }
    let hi = draw { Rig.sleigh(SleighLook(pos: SIMD2(100, 700)), contrast: true, into: &$0) }
    #expect(lo.count == hi.count && zip(lo, hi).contains { $0.color != $1.color })
    let pl = draw { Rig.penguin(PenguinLook(foot: SIMD2(100, 100)), contrast: false, into: &$0) }
    let ph = draw { Rig.penguin(PenguinLook(foot: SIMD2(100, 100)), contrast: true, into: &$0) }
    #expect(zip(pl, ph).contains { $0.color != $1.color })
}
