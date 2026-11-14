// AGENT HEADER - Tests/NeveCoreTests/PaletteTests.swift  (Palette: Tone.at is the pure blend and characters' colours follow it (Rig = Tone at the current blend, no global mutation), every colour has light and dark, blend takes 0.5 s, tick step capped at 1/30 s so the blend never pops, light vector is unit and from above, glints stay below 3 Hz, flake sizes bias small. Adding a colour: give it BOTH variants or this fails.)

import Testing
@testable import NeveCore

struct PaletteTests {
    @Test func everyColorHasBothAppearances() {
        #expect(Palette.all.count >= 14)
        for (name, t) in Palette.all {
            for v in [t.light, t.dark] { #expect(v.min() >= 0 && v.max() <= 1, "\(name)") }
        }
        #expect(Palette.snow.dark.x < Palette.snow.light.x && Palette.flake.dark.x < Palette.flake.light.x)   // dark mode softens the white
        #expect(Palette.shadowAlpha.dark > Palette.shadowAlpha.light && Palette.rimAlpha.dark == 0)
    }
    @Test func extrasHaveBothAppearances() {
        #expect(Palette.extras.count == 33 && Palette.all.count >= 46)
        for (name, t) in Palette.extras { #expect(t.light != t.dark, "\(name)") }
        for t in [Palette.rabbitFur, Palette.penguinBelly, Palette.trim, Palette.frost] { #expect(t.dark.max() < t.light.max() || t.dark.x < t.light.x) }   // whites soften
    }
    /// Characters' colours follow the light/dark blend. Pure (`Tone.at`), so the process-global `Palette.dark` is never mutated (other suites run in parallel and read it).
    @Test func characterColoursFollowTheBlend() {
        for (name, t) in Palette.all {
            func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool { let d: SIMD3<Float> = a - b; return max(abs(d.x), abs(d.y), abs(d.z)) < 1e-6 }
            #expect(near(t.at(0), t.light) && near(t.at(1), t.dark) && near(t.at(0.5), (t.light + t.dark) * 0.5), "\(name)")
        }
        // the Rig colours are exactly the Tone at the CURRENT blend (0 in tests: light), for the snow and the figures' accents
        let b = Palette.dark
        #expect(Rig.snow == SIMD4(Palette.snow.at(b), 1) && Rig.carrot == SIMD4(Palette.carrot.at(b), 1) && Rig.coal == SIMD4(Palette.coal.at(b), 1))
        #expect(Rig.scarfRed == SIMD4(Palette.red.at(b), 1) && Rig.crest == SIMD4(Palette.flake.at(b), Palette.crestAlpha))
        // dark softens the whites and lifts the dark parts, so the two ends really differ for those
        for t in [Palette.snow, Palette.carrot, Palette.coal, Palette.red] { #expect(t.at(0) != t.at(1)) }
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
