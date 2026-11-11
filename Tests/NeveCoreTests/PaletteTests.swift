// AGENT HEADER - Tests/NeveCoreTests/PaletteTests.swift  (Palette: every colour has light and dark, blend takes 0.5 s, tick step capped at 1/30 s so the blend never pops, light vector is unit and from above, glints stay below 3 Hz, flake sizes bias small. Adding a colour: give it BOTH variants or this fails.) Serialized: the suite mutates Palette.dark.

import Testing
@testable import NeveCore

@Suite(.serialized) struct PaletteTests {   // extrasHaveBothAppearancesAndFollowTheBlend mutates Palette.dark (process-wide): the suite runs one test at a time
    @Test func everyColorHasBothAppearances() {
        #expect(Palette.all.count >= 14)
        for (name, t) in Palette.all {
            for v in [t.light, t.dark] { #expect(v.min() >= 0 && v.max() <= 1, "\(name)") }
        }
        #expect(Palette.snow.dark.x < Palette.snow.light.x && Palette.flake.dark.x < Palette.flake.light.x)   // dark mode softens the white
        #expect(Palette.shadowAlpha.dark > Palette.shadowAlpha.light && Palette.rimAlpha.dark == 0)
    }
    @Test func extrasHaveBothAppearancesAndFollowTheBlend() {
        #expect(Palette.extras.count == 25 && Palette.all.count >= 39)
        for (name, t) in Palette.extras { #expect(t.light != t.dark, "\(name)") }
        for t in [Palette.rabbitFur, Palette.penguinBelly, Palette.trim, Palette.frost] { #expect(t.dark.max() < t.light.max() || t.dark.x < t.light.x) }   // whites soften
        let d = Palette.dark; defer { Palette.dark = d }
        Palette.dark = 0; let l = Rig.penguinBelly
        Palette.dark = 1; let k = Rig.penguinBelly
        #expect(l.x > k.x && Rig.carrot.x != l.x || Rig.carrot.x == Palette.carrot.dark.x)
    }
    @Test func lightIsUnitAndFromAbove() {
        #expect(abs(Palette.light.x * Palette.light.x + Palette.light.y * Palette.light.y - 1) < 1e-5 && Palette.light.y > 0.98 && Palette.light.x < 0)
    }
    @Test func blendTakesHalfASecond() {
        var d: Float = 0
        for _ in 0..<30 { d = Palette.blend(d, toward: 1, dt: 1.0 / 60) }
        #expect(abs(d - 1) < 1e-5)
        #expect(Palette.blend(0.5, toward: 0, dt: 10) == 0)
    }
    @Test func sizesBiasSmall() {
        var g = SystemRandomNumberGenerator()
        for (lo, hi) in [(Float(2.5), Float(7)), (1.5, 3.5)] {
            let s = (0..<4001).map { _ in SnowField.sampleSize(lo, hi, u: Float.random(in: 0..<1, using: &g)) }.sorted()
            #expect(s[2000] < 4 && s.min()! >= lo && s.max()! <= hi)
        }
    }
    @Test func glintsStayBelowThreeHertz() {
        // each glint is one 0 -> 1 -> 0 pulse of glintLife; the sleigh adds 3 a second at different spots; area is bounded by maxGlints stars of <= 6pt
        #expect(1 / Tuning.glintLife <= 3)
        #expect(Tuning.maxGlints * 6 * 6 < 400)
    }
    @Test func tickStepIsCappedSoTheBlendNeverPops() {
        #expect(Palette.stepDt(now: 10, last: 0) == 1.0 / 60)
        #expect(Palette.stepDt(now: 10, last: 9) == 1.0 / 30)       // after a long sleep: one short frame
        #expect(Palette.stepDt(now: 10.01, last: 10) < 1.0 / 30 && Palette.stepDt(now: 9, last: 10) == 0)
        var d: Float = 0
        for _ in 0..<2 { d = Palette.blend(d, toward: 1, dt: Palette.stepDt(now: 100, last: 1)) }
        #expect(d < 0.2)
    }
}
