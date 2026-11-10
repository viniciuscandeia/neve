import Testing
@testable import NeveCore

@Suite struct HitchMeterTests {
    @Test func steadyFramesAreNoHitch() {
        var m = HitchMeter()
        for i in 0..<10 { m.present(at: 1 + Double(i) / 60, target: 1 + Double(i) / 60) }
        #expect(m.drops == 0 && m.hitchMs == 0 && m.frames == 9)
    }
    @Test func lateFrameCountsExcess() {
        var m = HitchMeter()
        m.present(at: 1, target: 1)
        m.present(at: 1 + 1.0 / 60, target: 1 + 1.0 / 60)
        m.present(at: 1 + 1.0 / 60 + 0.05, target: 1 + 2.0 / 60)   // 50 ms for a 16.7 ms slot
        #expect(m.drops == 1)
        #expect(abs(m.hitchMs - (50 - 1000.0 / 60)) < 0.01)
        let r = m.take(wall: 2)
        #expect(abs(r.dropsPerSecond - 0.5) < 1e-9 && m.drops == 0)
    }
    @Test func adaptiveRateAndGapsAreIgnored() {
        var m = HitchMeter()
        m.present(at: 1, target: 1)
        m.present(at: 1.0333, target: 1.0333)   // 30 fps scheduled, 30 fps delivered
        m.present(at: 5, target: 4)             // 3 s scheduled gap (pause): skipped
        #expect(m.drops == 0 && m.hitchMs == 0)
    }
}
