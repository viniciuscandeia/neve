// AGENT HEADER - Tests/NeveCoreTests/PolishATests.swift  (polish round A: only crystals > 4 pt rotate, calm crystals keep a fixed angle, slab split stays a slab until small and conserves volume, drawn pile eases down within ~0.1 s scale, Rig snow colours come from Palette, `instanceLayoutMatchesTheShader` (Instance layout vs the Metal struct: update BOTH when it changes), instance velocity = delta pos / dt, calm flakes have no velocity.)

import CoreGraphics
import Testing
@testable import NeveCore

private func instances(_ f: SnowField) -> [Instance] {
    var buf = [Instance](repeating: Instance(pos: .zero, size: 0, alpha: 0, seed: 0), count: 20000)
    let n = buf.withUnsafeMutableBufferPointer { f.writeInstances(to: $0.baseAddress!) }
    return Array(buf[0..<n])
}

@Test func onlyCrystalsOverFourPointsRotate() {
    let f = makeField(flakes: 600, seed: 1)
    f.update(windows: [])
    for _ in 0..<60 { f.step(dt: 1.0 / 60) }
    let flakes = instances(f).filter { $0.kind == 0 }
    #expect(flakes.contains { $0.size > 4 })
    #expect(flakes.allSatisfy { $0.size > 4 || $0.rot == 0 })
    #expect(flakes.contains { $0.size > 4 && $0.rot != 0 })
}

@Test func calmCrystalsKeepAFixedAngle() {
    let f = makeField(flakes: 600, seed: 1)
    f.setCalm(true)
    f.update(windows: [])
    for _ in 0..<60 { f.step(dt: 1.0 / 60) }
    let big = instances(f).filter { $0.kind == 0 && $0.size > 4 }
    #expect(!big.isEmpty)
    #expect(big.allSatisfy { abs($0.rot - ($0.seed - $0.seed.rounded(.down)) * 2 * .pi) < 1e-4 })
}

@Test func splitSlabStaysASlabUntilSmallAndConservesVolume() {
    let f = makeField(seed: 2)
    f.update(windows: [])
    for (size, shape) in [(Float(16), UInt8(2)), (Float(8), UInt8(1))] {
        f.debris.removeAll()
        f.debris.append(Flake(pos: [100, 500], vx: 0, fall: 10, phase: 0, amp: 0, freq: 0, size: size, alpha: 1, kind: .debris, vol: 20, shape: 2))
        f.splitSlab(0, dt: 1)
        #expect(f.debris.count == 2)
        #expect(f.debris.allSatisfy { $0.shape == shape })
        #expect(abs(f.debris.reduce(0) { $0 + $1.vol } - 20) < 1e-3)
    }
}

@Test func drawnPileEasesDownAndArrivesWithinATenthOfASecondScale() {
    let f = makeField(seed: 3)
    f.update(windows: [win(1, 300, 300, 400, 200)])
    let i = f.surfaces.firstIndex { $0.id == 1 }!
    for b in 40..<60 { f.surfaces[i].pile.heights[b] = 10 }
    var buf = [PileSeg](repeating: PileSeg(x0: 0, x1: 0, top0: 0, top1: 0, base0: 0, base1: 0, slope: 0, dragged: 0), count: 4096)
    func write(_ dt: Float) { _ = buf.withUnsafeMutableBufferPointer { f.writePiles(to: $0.baseAddress!, capacity: 4096, dt: dt, force: true) } }
    write(10)
    #expect(f.surfaces[i].pile.shown[50] == 10)
    for b in 40..<60 { f.surfaces[i].pile.heights[b] = 0 }
    write(1.0 / 60)
    let first = f.surfaces[i].pile.shown[50]
    #expect(first > 0 && first < 10)
    for _ in 0..<18 { write(1.0 / 60) }
    #expect(f.surfaces[i].pile.shown[50] == 0)
}

@Test func rigSnowColoursComeFromThePalette() {
    #expect(Rig.snow == SIMD4(Palette.snow.now, 1))
    #expect(Rig.lift == SIMD4(Palette.lift.now, 1))
    #expect(Rig.shotSnow == SIMD4(Palette.lift.now, 1))
    #expect(Rig.shadow == SIMD4(Palette.shadow.now, Palette.figureShadowK))
    #expect(Rig.shadowHC == SIMD4(Palette.shadowHC.now, 1))
}

@Test func instanceLayoutMatchesTheShader() {
    // MSL: float2 pos; float size, alpha, seed, rot; uint kind; float2 vel  ->  offsets 0, 8..20, 24, 32; size 40, align 8
    #expect(MemoryLayout<Instance>.stride == 40)
    #expect(MemoryLayout<Instance>.alignment == 8)
    #expect(MemoryLayout<Instance>.offset(of: \Instance.kind) == 24)
    #expect(MemoryLayout<Instance>.offset(of: \Instance.vel) == 32)
}

@Test func instanceVelocityIsPositionDeltaOverDt() {
    let f = makeField(flakes: 300, seed: 3)
    f.update(windows: [])
    for _ in 0..<30 { f.step(dt: 1.0 / 60) }
    let a = instances(f)
    f.step(dt: 1.0 / 60)
    let b = instances(f)
    var checked = 0
    for (p, q) in zip(a, b) where p.kind == 0 && q.kind == 0 && p.seed == q.seed {
        let d = (q.pos - p.pos) * 60
        guard abs(d.x) < 200, abs(d.y) < 200 else { continue }   // skip wraps / respawns
        #expect(abs(q.vel.x - d.x) < 0.5 && abs(q.vel.y - d.y) < 0.5)
        checked += 1
    }
    #expect(checked > 100)
    #expect(b.contains { $0.kind == 0 && $0.vel.y < -20 })
}

@Test func calmFlakesHaveNoVelocity() {
    let f = makeField(flakes: 300, seed: 3)
    f.setCalm(true)
    f.update(windows: [])
    for _ in 0..<60 { f.step(dt: 1.0 / 60) }
    let all = instances(f)
    #expect(!all.isEmpty)
    #expect(all.allSatisfy { $0.vel == .zero })
}
