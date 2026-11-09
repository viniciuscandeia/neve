import CoreGraphics
import Testing
@testable import NeveCore

private func snow(_ seed: UInt64 = 5) -> SnowField {
    SnowField(size: CGSize(width: 1000, height: 800), origin: .zero, groundY: 90, visibleTop: 780, flakeCount: 400, seed: seed)
}

@Test func motionDeterministicForSeed() {
    let a = snow(), b = snow()
    advance(a, 20, fps: 30); advance(b, 20, fps: 30)
    #expect(a.flakes.map(\.pos) == b.flakes.map(\.pos))
}

@Test func terminalSpeedGrowsWithSize() {
    let f = snow()
    var fs: [Flake] = []
    for _ in 0..<400 { fs.append(f.spawn(.sky, anywhere: true)) }
    let small = fs.filter { $0.size < 3.5 }.map(\.fall), big = fs.filter { $0.size > 6 }.map(\.fall)
    #expect(!small.isEmpty && !big.isEmpty)
    let bigAvg: Float = big.reduce(0, +) / Float(big.count), smallAvg: Float = small.reduce(0, +) / Float(small.count)
    #expect(bigAvg > smallAvg + 10)
    var bg: [Flake] = []
    for _ in 0..<400 { bg.append(f.spawn(.background, anywhere: true)) }
    let bgBig: Float = bg.filter { $0.size > 3 }.map(\.fall).min()!
    let bgSmall: Float = bg.filter { $0.size < 2 }.map(\.fall).min()!
    #expect(bgBig > bgSmall)
}

@Test func windResponseIsSmooth() {
    let f = SnowField(size: CGSize(width: 1000, height: 800), origin: .zero, groundY: 90, visibleTop: 780, flakeCount: 400, seed: 5)
    f.setIntensity(.nevasca, immediate: true)
    advance(f, 3, fps: 60)
    var prev = f.flakes.map(\.wv), maxStep: Float = 0, maxWv: Float = 0
    for _ in 0..<600 {
        f.step(dt: 1 / 60)
        for (k, g) in f.flakes.enumerated() where g.kind == .sky && k < prev.count && abs(g.wv) > 0 && abs(prev[k]) > 0 { maxStep = max(maxStep, abs(g.wv - prev[k])) }
        maxWv = max(maxWv, f.flakes.map { abs($0.wv) }.max()!)
        prev = f.flakes.map(\.wv)
    }
    #expect(maxWv > 20)       // the wind does move them
    #expect(maxStep < 5)      // but never snaps (per 1/60 s frame)
}

@Test func pointerPushOffIgnoresCursor() {
    func run(cursor: Bool, push: Bool) -> [SIMD2<Float>] {
        let f = snow(); f.pointerPush = push
        if cursor { f.setPointer(SIMD2(500, 400), velocity: SIMD2(300, 0)) }
        for _ in 0..<120 { f.step(dt: 1 / 60) }
        return f.flakes.map(\.pos)
    }
    let none = run(cursor: false, push: true)
    #expect(run(cursor: true, push: false) == none)
    #expect(run(cursor: true, push: true) != none)
}

@Test func flakeTimerOffChangesNothingAndOnAccumulates() {
    var t = 0.0
    let a = snow(), b = snow()
    b.timer = { t += 0.001; return t }
    advance(a, 2, fps: 30); advance(b, 2, fps: 30)
    #expect(a.flakes.map(\.pos) == b.flakes.map(\.pos))
    #expect(a.flakeSeconds == 0 && a.flakeSteps == 0)
    #expect(b.flakeSeconds > 0 && b.flakeSteps > 0)
}

// Rare large out-of-focus foreground flakes (.near, Instance kind 6).
private func nearField(_ i: Intensity = .media) -> SnowField {
    let f = SnowField(size: CGSize(width: 1000, height: 800), origin: .zero, groundY: 90, visibleTop: 780, flakeCount: 400, seed: 9)
    f.setIntensity(i, immediate: true)
    return f
}

@Test func nearFlakesAreAboutTwoPercentOfSky() {
    for i in [Intensity.media, .nevasca] {
        let f = nearField(i)
        advance(f, 25, fps: 30)
        let near = f.flakes.filter { $0.kind == .near }, sky = f.flakes.filter { $0.kind == .sky }.count + near.count
        #expect(near.count == Int((Float(f.skyLimit) * 0.02).rounded()) && near.count >= 3)
        #expect(abs(Float(near.count) / Float(sky) - 0.02) < 0.01)
        #expect(near.allSatisfy { (8...13).contains($0.size) && $0.fall >= 75 && $0.fall <= 100 && abs($0.alpha - 0.28) < 0.05 })
    }
}

@Test func nearFlakesNeverDeposit() {
    let g = nearField()
    advance(g, 15, fps: 30)
    let nearIdx = g.flakes.indices.filter { g.flakes[$0].kind == .near }
    #expect(!nearIdx.isEmpty)
    let before = g.surfaces.reduce(0) { $0 + $1.pile.heights.reduce(0, +) }
    for i in nearIdx { g.flakes[i].pos.y = 95 }   // just above the ground line
    g.flakes = g.flakes.map { var h = $0; if h.kind == .sky || h.kind == .background { h.kind = .dormant }; return h }
    g.skyLimit = 0; g.bgLimit = 0
    g.skyEnd = g.skyCount; g.bgEnd = g.flakes.count - g.skyCount
    advance(g, 0.2, fps: 30)
    #expect(g.surfaces.reduce(0) { $0 + $1.pile.heights.reduce(0, +) } == before)
}

@Test func nearFlakesOffUnderCalmEconomyLowPower() {
    for mode in 0..<3 {
        let f = nearField()
        advance(f, 5, fps: 30)
        #expect(f.flakes.contains { $0.kind == .near })
        if mode == 0 { f.setCalm(true) } else if mode == 1 { f.economy = true } else { f.setLowPower(true) }
        advance(f, 3, fps: 30)
        #expect(!f.flakes.contains { $0.kind == .near })
        advance(f, 20, fps: 30)
        #expect(!f.flakes.contains { $0.kind == .near })
    }
}

@Test func nearFlakesWriteSoftDiscInstances() {
    let f = nearField()
    advance(f, 15, fps: 30)
    let buf = UnsafeMutablePointer<Instance>.allocate(capacity: f.flakes.count + 4096)
    defer { buf.deallocate() }
    let n = f.writeInstances(to: buf)
    let k6 = (0..<n).map { buf[$0] }.filter { $0.kind == 6 }
    #expect(k6.count == f.flakes.filter { $0.kind == .near }.count && k6.count >= 3)
    #expect(k6.allSatisfy { (8...13).contains($0.size) && $0.alpha > 0.1 && $0.alpha < 0.4 && $0.vel == .zero })
    #expect(MemoryLayout<Instance>.stride == 40)
}
