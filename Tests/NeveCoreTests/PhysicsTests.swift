import CoreGraphics
import Testing
import NeveCore

@Test func skyFlakesLandOnAWindowAndBuildItsPile() {
    let f = makeField(flakes: 600)
    f.update(windows: [win(1, 200, 300, 400, 200)])   // top edge at y=500, x 200...600
    #expect(f.pile(id: 1)!.heights.max()! == 0)
    #expect(snowUntilPiled(f, id: 1, height: 3))
}

@Test func pileOnlyGrowsWhereFlakesCanReachTheEdge() {
    let f = makeField(flakes: 600)
    // The front window hides the left half of the back window's top edge.
    f.update(windows: [win(2, 100, 300, 200, 300), win(1, 100, 200, 400, 200)])
    #expect(snowUntilPiled(f, id: 1, height: 3))
    let p = f.pile(id: 1)!
    for (h, v) in zip(p.heights, p.visible) where !v { #expect(h == 0) }
}

@Test func backgroundFlakesPassThroughWindowsWithoutLanding() {
    let f = makeField(flakes: 600)
    f.update(windows: [win(1, 0, 100, 1000, 600)])   // top edge at y=700 spans the whole screen
    var seen = 0
    for _ in 0..<1200 {
        let before = f.flakes
        f.step(dt: 1 / 60)
        for (a, b) in zip(before, f.flakes) where a.kind == .background && b.pos.y > a.pos.y {
            // A background flake only jumps back up after falling off the bottom of the screen.
            #expect(a.pos.y < 2)
            seen += 1
        }
    }
    #expect(seen > 0)   // the check above actually ran: flakes did respawn
}

@Test func skyFlakesRespawnAboveTheWindowTheyLandedOn() {
    let f = makeField(flakes: 600)
    f.update(windows: [win(1, 0, 100, 1000, 600)])
    var landings = 0
    for _ in 0..<1200 {
        let before = f.flakes
        f.step(dt: 1 / 60)
        for (a, b) in zip(before, f.flakes) where a.kind == .sky && b.pos.y > a.pos.y && a.pos.y > 100 { landings += 1 }
    }
    #expect(landings > 0)
}

@Test func knockedOffSnowAcceleratesDownward() {
    let f = makeField(flakes: 600)
    f.update(windows: [front, back])
    #expect(snowUntilPiled(f, id: 1))
    f.update(windows: [front])
    let falling = f.debris.count
    #expect(falling > 0)
    f.step(dt: 0.05)
    // Starts at most 50 pt/s down (+ a little upward kick is impossible: window did not move);
    // gravity 1400 pt/s^2 over 0.05 s adds 70 pt/s, so every survivor is now at >= 70.
    #expect(f.debris.allSatisfy { $0.fall >= 70 })
    #expect(f.debris.count > 0)
}

@Test func debrisFallingPastTheScreenBottomIsRemoved() {
    let f = makeField(flakes: 600)
    f.update(windows: [win(1, 300, 300, 400, 200)])   // nothing below it
    #expect(snowUntilPiled(f, id: 1))
    f.update(windows: [])
    #expect(f.debris.count > 0)
    for _ in 0..<300 { f.step(dt: 1 / 60) }   // 5 s: far longer than a 500 pt fall
    #expect(f.debris.isEmpty)
}

@Test func debrisLandingOnALowerWindowIsRemovedThere() {
    let f = makeField(flakes: 600)
    // Upper window spans most of the screen; the lower one only sits under x 400...600.
    let upper = win(1, 100, 400, 800, 200)   // top edge at y=600
    let lower = win(2, 400, 100, 200, 200)   // top edge at y=300
    f.update(windows: [upper, lower])
    #expect(snowUntilPiled(f, id: 1))
    f.update(windows: [lower])
    let overLower = f.debris.filter { $0.pos.x > 420 && $0.pos.x < 580 }.count
    let elsewhere = f.debris.filter { $0.pos.x < 380 || $0.pos.x > 620 }.count
    #expect(overLower > 0 && elsewhere > 0)
    // Falling 300 pt at 1400 pt/s^2 takes ~0.6 s; falling the 600 pt to the screen bottom takes ~0.85 s.
    for _ in 0..<42 { f.step(dt: 1 / 60) }   // 0.7 s
    #expect(f.debris.filter { $0.pos.x > 420 && $0.pos.x < 580 }.isEmpty)
    #expect(f.debris.filter { $0.pos.x < 380 || $0.pos.x > 620 }.count > 0)
}

@Test func calmModeCapsActiveFlakesAndRestoresThem() {
    let f = makeField(flakes: 1000)
    f.setIntensity(.media, immediate: true)
    func live() -> Int { var n = 0; for _ in 0..<1200 { f.step(dt: 1 / 30) }   // 40s: surplus flakes retire as they fall out
        let b = UnsafeMutablePointer<Instance>.allocate(capacity: f.capacity); defer { b.deallocate() }
        n = f.writeInstances(to: b); return n }
    let normal = live()
    f.setCalm(true)
    let calm = live()
    #expect(Double(calm) < Double(normal) * 0.4 && calm > 0)   // ~30% of the normal count
    f.setCalm(false)
    #expect(live() > normal * 9 / 10)
}

/// Drags window 1 (pile built first) at `step` pt per update, reversing every `flip` updates; returns the debris spawned.
private func dragDebris(step: CGFloat, updates: Int, flip: Int = .max) -> Int {
    let f = makeField(flakes: 600)
    f.update(windows: [win(1, 300, 300, 400, 200)])
    #expect(snowUntilPiled(f, id: 1))
    let before = f.debris.count
    var x: CGFloat = 300, dir: CGFloat = 1
    for i in 1...updates {
        if i % flip == 0 { dir = -dir }
        x += dir * step
        f.update(windows: [win(1, x, 300, 400, 200)], dt: 1 / 60)
    }
    return f.debris.count - before
}

@Test func slowDragAtFrameRateShedsNothing() {
    #expect(dragDebris(step: 5, updates: 120) == 0)   // 300 pt/s for 2 s, 120 updates
}

@Test func fastShakeAtFrameRateStillSheds() {
    #expect(dragDebris(step: 30, updates: 60, flip: 8) > 0)   // 1800 pt/s, reversing every 8 frames (~3.8 Hz hand shake)
}
