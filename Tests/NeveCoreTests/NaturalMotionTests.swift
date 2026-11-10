import CoreGraphics
import Foundation
import Testing
@testable import NeveCore

private func snow(_ seed: UInt64 = 5) -> SnowField {
    SnowField(size: CGSize(width: 1000, height: 800), origin: .zero, groundY: 90, visibleTop: 780, flakeCount: 400, seed: seed)
}

@Test func windIsNotPeriodic() {
    let xs = (0..<1200).map { Double(windNoise(Double($0) * 0.1)) }   // 120 s at 10 Hz
    let m = xs.reduce(0, +) / Double(xs.count), c = xs.map { $0 - m }
    let v = c.reduce(0) { $0 + $1 * $1 }
    for lag in 5...60 {
        let k = lag * 10
        var s = 0.0
        for i in 0..<(c.count - k) { s += c[i] * c[i + k] }
        #expect(abs(s / v) < 0.6, "lag \(lag) s: \(s / v)")
    }
}

@Test func noiseIsContinuous() {
    var worst: Float = 0
    for i in 0..<2000 {
        let x = Float(i) * 0.37, y = Float(i % 50) * 1.3
        worst = max(worst, abs(valueNoise(x + 0.01, y) - valueNoise(x, y)), abs(valueNoise(x, y + 0.01) - valueNoise(x, y)))
    }
    #expect(worst < 0.06)
    for i in 0..<1000 { #expect(abs(windNoise(Double(i) * 0.7 + 0.01) - windNoise(Double(i) * 0.7)) < 0.02) }
    #expect((0..<2000).allSatisfy { abs(windNoise(Double($0) * 1.9)) <= 1.3 + 1e-4 })
}

@Test func swayAvoidsTheTwoTenthsHertzBand() {
    #expect(SnowField.bandGain(2 * .pi * 0.2) <= 0.4)
    #expect(SnowField.bandGain(2 * .pi * 0.1) == 1 && SnowField.bandGain(2 * .pi * 0.3) == 1)
    let f = snow()
    for _ in 0..<600 {
        let k = f.spawn(.sky, anywhere: true)
        for d in stride(from: Float(-1), through: 1, by: 0.25) {   // across the drift range
            let w = k.freq * (1 + 0.25 * d), hz = w / (2 * .pi)
            #expect((hz < 0.15 || hz > 0.25) || SnowField.bandGain(w) < 1)
        }
    }
}

@Test func windDustConservesVolume() {
    let f = snow(3)
    f.setIntensity(.nevasca, immediate: true)
    advance(f, 60, fps: 30)
    let vol = { f.surfaces.reduce(Float(0)) { $0 + $1.pile.heights.reduce(0, +) } }
    let v0 = vol()
    f.wind = 120
    for _ in 0..<2000 { f.stepWindDust(dt: 1 / 30) }
    #expect(abs(vol() - v0) < 1e-2 * max(1, v0))
}

@Test func calmFloorAndHold() {
    #expect(FrameRate.calmFloor == 30 && FrameRate.calmFloorEconomy == 20)
    #expect(FrameRate.holdDown >= 1)
    #expect(Tuning.interpolateCalm == false)
    #expect(FrameRate.interpAlpha(sinceStep: 0.5, stepPeriod: 1) == 0.5 && FrameRate.interpAlpha(sinceStep: 3, stepPeriod: 1) == 1)
}

@Test func fastSinStaysCloseToSin() {
    var worst: Float = 0
    for k in 0..<2000 { let x = Float(k) * 0.05 - 50; worst = max(worst, abs(fastSin(x) - sin(x)), abs(fastCos(x) - cos(x))) }
    #expect(worst < 0.07)
}
