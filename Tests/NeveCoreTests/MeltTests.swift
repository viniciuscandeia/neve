import CoreGraphics
import Testing
@testable import NeveCore

private func snowy(seed: UInt64 = 7, calm: Bool = false) -> SnowField {
    let f = SnowField(size: CGSize(width: 1000, height: 800), origin: .zero, groundY: 90, visibleTop: 780, flakeCount: 200, seed: seed)
    f.setCalm(calm)
    f.update(windows: [win(1, 300, 400, 300, 150)])
    f.stage(.heavy)
    return f
}

private func trace(_ f: SnowField, seconds: Float, dt: Float = 1.0 / 60) -> [Float] {
    var v: [Float] = []
    for _ in 0..<Int(seconds / dt) { f.step(dt: dt); v.append(f.pileVolume) }
    return v
}

@Test func meltDrainsPilesMonotonicallyWithinDuration() {
    let f = snowy()
    advance(f, 1)
    #expect(f.pileVolume > 0)
    f.beginMelt(duration: 5)
    #expect(f.isMelting)
    let v = trace(f, seconds: 5.5)
    for k in 1..<v.count { #expect(v[k] <= v[k - 1] + 1e-3) }
    #expect(v.last == 0)
    #expect(f.meltDone)
}

@Test func nothingSpawnsOrLandsDuringMeltAndActorsAreGone() {
    let f = snowy()
    advance(f, 3)
    #expect(f.activeFlakes > 0)
    f.beginMelt(duration: 5)
    advance(f, 1.6)
    #expect(f.flakes.allSatisfy { $0.kind == .dormant || $0.kind == .debris || $0.fade < 0.01 || $0.pos.y > 0 })
    var maxActive = f.activeFlakes
    for _ in 0..<240 { f.step(dt: 1 / 60); maxActive = max(maxActive, f.activeFlakes) }
    #expect(maxActive <= 5)   // no new flakes; the fading ones are nearly out
    advance(f, 2)
    #expect(f.figures.isEmpty && f.balls.isEmpty && f.icicles.isEmpty && f.gifts.isEmpty && f.debris.isEmpty)
    #expect(f.activeFlakes == 0 && f.pileVolume == 0 && f.meltDone)
}

@Test func introCancelsMeltAndKeepsWhatIsLeft() {
    let f = snowy()
    advance(f, 1)
    let before = f.pileVolume
    f.beginMelt(duration: 5)
    advance(f, 2)
    let mid = f.pileVolume
    #expect(mid < before && mid > 0)
    f.beginIntro(duration: 2.5)
    #expect(!f.isMelting)
    advance(f, 1)
    #expect(f.pileVolume >= mid - 1e-3)   // not melting anymore (new snow may add)
}

@Test func resumeStartsFromTheTopWithNoFlakeOnScreen() {
    let f = snowy()
    advance(f, 3)
    f.beginMelt(duration: 5)
    advance(f, 5.1)
    #expect(f.meltDone)
    f.beginIntro(duration: 2.5)
    #expect(f.activeFlakes == 0)
    for _ in 0..<12 {   // 0.2 s: still entering, nowhere near mid-screen
        f.step(dt: 1 / 60)
        for fl in f.flakes where fl.kind != .dormant { #expect(fl.pos.y >= 780 - 25) }
    }
    advance(f, 3)
    #expect(f.activeFlakes > 20)
}

@Test func meltIsDeterministic() {
    func run() -> [Float] { let f = snowy(seed: 3); advance(f, 2); f.beginMelt(duration: 4); return trace(f, seconds: 4.2) }
    #expect(run() == run())
}

@Test func reduceMotionMeltIsAQuickFade() {
    let f = snowy(calm: true)
    advance(f, 2)
    f.beginMelt(duration: 5)
    advance(f, 1.1)
    #expect(f.meltDone && f.pileVolume == 0 && f.figures.isEmpty)
}
