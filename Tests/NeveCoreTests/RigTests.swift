import Testing
@testable import NeveCore

private let cap = 128

/// Runs `body` with a writer on a stack buffer; returns the prims written.
private func draw(_ body: (inout PrimWriter) -> Void) -> [Prim] {
    withUnsafeTemporaryAllocation(of: Prim.self, capacity: cap) { buf in
        buf.initialize(repeating: Prim())
        var w = PrimWriter(buf.baseAddress!, capacity: cap)
        body(&w)
        return Array(buf[0..<w.n])
    }
}

private func look(built: Int = 7, facing: Float = 1, lean: Float = 0) -> SnowmanLook {
    SnowmanLook(foot: SIMD2(100, 50), radii: SIMD3(17.25, 12.75, 9.75), facing: facing, pose: Pose(lean: lean), built: built)
}

@Test func primIs64Bytes() { #expect(MemoryLayout<Prim>.stride == 64) }

@Test func primCountsPerStage() {
    var last = 0
    var counts: [Int] = []
    for s in 0...7 {
        let n = draw { Rig.snowman(look(built: s), contrast: false, into: &$0) }.count
        counts.append(n)
        #expect(n >= last)
        last = n
    }
    #expect(counts[0] == 0)
    #expect(counts[1] == 4 && counts[2] == 8 && counts[3] == 12)   // shadow, body, lit disc, crest per ball
    #expect(counts[4] == 12 + 3 + 7)                               // + buttons, eyes, smile
    #expect(counts[5] == counts[4] + 1)                            // nose
    #expect(counts[6] == counts[5] + 6)                            // 2 arms x 3 capsules
    #expect(counts[7] == counts[6] + 5)                            // pill, 2 tails, 2 stripes
}

@Test func headMovesByLean() {
    let a = draw { Rig.snowman(look(), contrast: false, into: &$0) }, b = draw { Rig.snowman(look(lean: 5), contrast: false, into: &$0) }
    #expect(a.count == b.count)
    func headBody(_ p: [Prim]) -> Prim { p.first { $0.kind == 0 && abs($0.b.x - 9.75) < 1e-4 }! }
    func baseBody(_ p: [Prim]) -> Prim { p.first { $0.kind == 0 && abs($0.b.x - 17.25) < 1e-4 }! }
    #expect(abs((headBody(b).a.x - headBody(a).a.x) - 5) < 1e-4)
    #expect(baseBody(a).a == baseBody(b).a)
}

@Test func facingMirrorsNose() {
    func noseX(_ f: Float) -> Float {
        let t = draw { Rig.snowman(look(facing: f), contrast: false, into: &$0) }.first { $0.kind == 2 && $0.color.x > 0.9 && $0.color.y < 0.6 }!
        return t.b.x - 100   // tip
    }
    #expect(noseX(1) > 0 && noseX(-1) < 0)
    #expect(abs(noseX(1) + noseX(-1)) < 1e-3)
}

@Test func autoScaleEqualsStackedRadii() {
    let s: Float = 1.5
    let auto = SnowmanLook(foot: SIMD2(30, 7), radii: SIMD3(11.5, 8.5, 6.5) * s)
    let stacked = SnowmanLook(foot: SIMD2(30, 7), radii: SIMD3(17.25, 12.75, 9.75))
    let a = draw { Rig.snowman(auto, contrast: false, into: &$0) }, b = draw { Rig.snowman(stacked, contrast: false, into: &$0) }
    #expect(a.count == b.count)
    for (p, q) in zip(a, b) {
        for (u, v) in [(p.a, q.a), (p.b, q.b), (p.c, q.c), (p.d, q.d)] { #expect(abs(u.x - v.x) < 1e-3 && abs(u.y - v.y) < 1e-3) }
        #expect(abs(p.width - q.width) < 1e-3 && p.kind == q.kind)
    }
}

@Test func writerDropsPastCapacity() {
    let n = withUnsafeTemporaryAllocation(of: Prim.self, capacity: 5) { buf -> Int in
        var w = PrimWriter(buf.baseAddress!, capacity: 5)
        for _ in 0..<3 { Rig.ball(center: .zero, radius: 10, rotation: 0, fade: 1, squash: 0, contrast: false, face: false, into: &w) }
        return w.n
    }
    #expect(n == 5)
}

@Test func collapsingKeepsOnlyAccessories() {
    var l = look(); l.collapsing = true; l.fade = 0.5
    let p = draw { Rig.snowman(l, contrast: false, into: &$0) }
    #expect(!p.contains { $0.kind == 0 && $0.b.x > 12 })   // no ball bodies
    #expect(p.allSatisfy { $0.color.w <= 0.5 + 1e-5 })
}

@Test func headlessDropsHeadAndFace() {
    var l = look(); l.headless = true
    let p = draw { Rig.snowman(l, contrast: false, into: &$0) }
    #expect(!p.contains { $0.kind == 0 && abs($0.b.x - 9.75) < 1e-4 })
    #expect(p.count == 8 + 3 + 6)   // base + middle, buttons, arms: no head / face / scarf
}

@Test func headlessEmitsNoEllipseAboveTheMiddleBall() {
    var l = look(); l.headless = true
    let rb: Float = 17.25, rm: Float = 12.75
    let top = 50 + 2 * rb + 2 * rm - 1.5   // top of the middle ball
    let p = draw { Rig.snowman(l, contrast: false, into: &$0) }
    #expect(!p.contains { $0.kind == 0 && $0.a.y > top - 0.5 * rm })   // nothing floats up where the head was
}
