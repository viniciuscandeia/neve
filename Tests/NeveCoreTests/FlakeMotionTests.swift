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

@Test func flakeTimerOffChangesNothingAndOnAccumulates() {
    var t = 0.0
    let a = snow(), b = snow()
    b.timer = { t += 0.001; return t }
    advance(a, 2, fps: 30); advance(b, 2, fps: 30)
    #expect(a.flakes.map(\.pos) == b.flakes.map(\.pos))
    #expect(a.flakeSeconds == 0 && a.flakeSteps == 0)
    #expect(b.flakeSeconds > 0 && b.flakeSteps > 0)
}
