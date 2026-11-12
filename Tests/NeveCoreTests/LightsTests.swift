// AGENT HEADER - Tests/NeveCoreTests/LightsTests.swift  (Lights.swift)
// Role: the Christmas lights: the pattern is a pure function of time (and alternates modes), nothing is drawn with the toggle off, Reduce Motion (calm) makes every bulb constant, lit flakes exist only near a bulb (and never with the toggle off).

import CoreGraphics
import Testing
@testable import NeveCore

private func prims(_ f: SnowField) -> [Prim] {
    let buf = UnsafeMutablePointer<Prim>.allocate(capacity: 2000); defer { buf.deallocate() }
    var w = PrimWriter(buf, capacity: 2000)
    f.writeLightPrims(&w) { _ in .zero }
    return (0..<w.n).map { buf[$0] }
}

@Test func lightsPatternIsDeterministicByTimeAndAlternatesModes() {
    for i in 0..<20 { #expect(Lights.level(i, t: 7.3, calm: false) == Lights.level(i, t: 7.3, calm: false)) }
    let a = (0..<40).map { Lights.level(3, t: Float($0) * 0.4, calm: false) }
    #expect(a.max()! - a.min()! > 0.3)
    #expect((0..<30).contains { Lights.level(0, t: 14 + Float($0) * 0.05, calm: false) != Lights.level(1, t: 14 + Float($0) * 0.05, calm: false) })   // chase: neighbours differ
    for t in stride(from: Float(0), to: 60, by: 0.37) { for i in 0..<12 { let l = Lights.level(i, t: t, calm: false); #expect(l >= 0 && l <= 1.0001) } }
}

@Test func nothingIsDrawnWithLightsOff() {
    let f = makeField(); f.treeEnabled = true
    #expect(prims(f).isEmpty)
    f.lightsEnabled = true
    #expect(prims(f).count > 50)
}

@Test func calmLightsAreConstant() {
    let f = makeField(); f.lightsEnabled = true; f.setCalm(true)
    let a = prims(f)
    f.time += 5.3
    let b = prims(f)
    #expect(a.count == b.count && zip(a, b).allSatisfy { $0.color == $1.color && $0.a == $1.a })
    f.setCalm(false)
    f.time += 1.1
    let c = prims(f)
    #expect(zip(a, c).contains { $0.color != $1.color })
}

@Test func theTreeGetsBulbsAndPileTint() {
    let f = makeField(); f.update(windows: []); f.treeEnabled = true; f.lightsEnabled = true
    let base = prims(f).count
    f.burst = Burst(x: 500, t: 0)
    var n = 0
    while f.tree?.state != .resting, n < 60 * 12 { f.step(dt: 1 / 60); n += 1 }
    #expect(prims(f).count >= base + Lights.treeBulbs.count * 3)
}

@Test func litFlakesOnlyNearBulbs() {
    let f = makeField(flakes: 10); f.lightsEnabled = true
    let b = f.garlandBulb(5)
    #expect(f.lightCode(at: b + [1, 0]) & 255 == 7)
    #expect(f.lightCode(at: [500, 400]) == 0)
    #expect(f.lightCode(at: b + [0, -25]) == 0)
    f.flakes[0].pos = b + [1, 0]
    let buf = UnsafeMutablePointer<Instance>.allocate(capacity: 5000); defer { buf.deallocate() }
    let n = f.writeInstances(to: buf)
    #expect((0..<n).contains { buf[$0].kind & 255 == 7 })
    f.lightsEnabled = false
    let m = f.writeInstances(to: buf)
    #expect(!(0..<m).contains { buf[$0].kind & 255 == 7 })
}
