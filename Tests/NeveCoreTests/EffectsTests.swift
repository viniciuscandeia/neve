import CoreGraphics
import Testing
@testable import NeveCore

private func tallPile(calm: Bool = false) -> SnowField {
    let f = makeField(seed: 3)
    f.setCalm(calm)
    f.update(windows: [win(1, 300, 300, 400, 200)])
    return f
}

private func setHeights(_ f: SnowField, _ r: Range<Int>, _ h: Float) {
    let i = f.surfaces.firstIndex { $0.id == 1 }!
    for b in r { f.surfaces[i].pile.heights[b] = h }
}

@Test func knockOffOfATallPileMakesSlabsThatCarryItsVolume() {
    let f = tallPile()
    let i = f.surfaces.firstIndex { $0.id == 1 }!
    setHeights(f, 40..<60, 10)   // 20 bins, h = 10
    let n = f.knockOff(f.surfaces[i])
    #expect(n == f.debris.count)
    #expect(f.debris.contains { $0.shape == 2 })
    #expect(abs(f.debris.reduce(0) { $0 + $1.vol } - 400) <= 1)
    #expect(f.debris.filter { $0.shape == 2 }.allSatisfy { $0.size >= 8 && $0.size <= 16 })
}

@Test func lowPilesKeepPlainDots() {
    let f = tallPile()
    setHeights(f, 40..<60, 2)
    _ = f.knockOff(f.surfaces.first { $0.id == 1 }!)
    #expect(!f.debris.isEmpty && f.debris.allSatisfy { $0.shape == 0 })
}

@Test func heavySlabLandingDigsACraterWithARimAndThrowsClumpsUp() {
    let f = makeField(seed: 5)
    f.update(windows: [win(1, 300, 300, 400, 200)])
    let i = f.surfaces.firstIndex { $0.id == 1 }!
    let bin = 100
    f.debris.append(Flake(pos: [Float(f.surfaces[i].c0 + bin) * 2 + 1, 504], vx: 0, fall: 500, phase: 0, amp: 0, freq: 0, size: 16, alpha: 1, kind: .debris, vol: 20, shape: 2))
    f.step(dt: 1 / 60)
    let h = f.surfaces[i].pile.heights
    #expect(h[bin] > 0 && h[bin] < h[bin + 3] && h[bin] < h[bin - 3])
    #expect(f.debris.contains { $0.shape == 1 && $0.fall < 0 })
    #expect(!f.puffs.isEmpty)
}

@Test func reduceMotionSlabsFallStraightWithoutDust() {
    let f = tallPile(calm: true)
    setHeights(f, 40..<60, 10)
    _ = f.knockOff(f.surfaces.first { $0.id == 1 }!)
    #expect(f.debris.contains { $0.shape == 2 })
    #expect(f.puffs.isEmpty && f.debris.allSatisfy { $0.shape == 2 && $0.spin == 0 && $0.vx == 0 && $0.fall == Tuning.calmDebrisFall })
    for _ in 0..<30 { f.step(dt: 1 / 30) }
    #expect(f.glints.isEmpty && f.debris.allSatisfy { $0.shape == 2 })   // no puffs, glints or breaks
}

@Test func slabSplitConservesVolume() {
    let f = tallPile()
    setHeights(f, 40..<48, 10)
    _ = f.knockOff(f.surfaces.first { $0.id == 1 }!)
    setHeights(f, 40..<48, 0)
    f.debris.removeAll { $0.shape != 2 }
    let before = f.debris.reduce(0) { $0 + $1.vol }
    #expect(before > 0)
    var split = false
    f.debris[0].delay = 0.3   // aloft long enough; breaks at 1.5 per second
    for _ in 0..<400 where !split {
        f.splitSlab(0, dt: 1 / 30)
        split = f.debris.count == 2
    }
    #expect(split)
    #expect(abs(f.debris.reduce(0) { $0 + $1.vol } - before) < 0.01)
}

@Test func puffAndGlintCapsHold() {
    let f = makeField(seed: 9)
    f.update(windows: [win(1, 300, 300, 400, 200)])
    for _ in 0..<100 { f.addPuff(x: 500, y: 400) }
    #expect(f.puffs.count == Tuning.maxPuffs)
    setHeights(f, 0..<200, 10)
    for _ in 0..<600 { f.step(dt: 1 / 30); #expect(f.glints.count <= Tuning.maxGlints) }
    f.economy = true
    f.step(dt: 1 / 30)
    #expect(f.glints.isEmpty)
}
