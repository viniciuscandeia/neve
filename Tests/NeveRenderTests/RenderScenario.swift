// AGENT HEADER - Tests/NeveRenderTests/RenderScenario.swift  (deterministic SnowField scenario + input variants for the offscreen render tests)
// Role: `renderScenario()` builds the same world every call (1000x800 screen, seed 7, Dock + three windows, Nevasca, piles >= 80 %, two snowmen, snowing flakes, Christmas tree + lights, December date, 480 fixed 1/60 s steps, explicit `now` for window updates: no clock, no I/O);
//   `renderVariants` lists the overlay-level inputs the frame is drawn with (plain, contrast + reduce motion + economy + drag shift, compact soft cut with occluders, shrunk live strip at 2x scale). Each render consumes its own field (writePiles eases `shown`), so call `renderScenario()` per render.
// Used by: NeveRenderTests.

import CoreGraphics
import Foundation
import NeveCore

func renderScenario() -> SnowField {
    let f = SnowField(size: CGSize(width: 1000, height: 800), origin: .zero, groundY: 90, visibleTop: 780, flakeCount: 600, seed: 7)
    f.calendarDay = (12, 24)
    f.treeEnabled = true; f.lightsEnabled = true; f.sleighEnabled = true; f.visitorsEnabled = true
    let ws = [WindowInfo(number: 0, frame: CGRect(x: 300, y: 10, width: 400, height: 84), radius: 25.2),
              WindowInfo(number: 1, frame: CGRect(x: 100, y: 200, width: 300, height: 200)),
              WindowInfo(number: 2, frame: CGRect(x: 200, y: 300, width: 300, height: 300)),
              WindowInfo(number: 3, frame: CGRect(x: 600, y: 150, width: 320, height: 220))]
    f.update(windows: ws, now: 0)
    f.stage(.heavy)
    _ = f.dropTree()
    for i in 0..<480 {
        if i % 30 == 0 { f.update(windows: ws, now: Double(i) / 60) }
        f.step(dt: 1 / 60)
    }
    return f
}

/// Overlay-level inputs of one frame (the names are NeveRender's `FrameInputs`).
struct RenderVariant {
    var name: String
    var contrast: Float = 0
    var reduceMotion = false
    var economy = false
    var time: Float = 123.456
    var shiftID: Int?
    var shift = SIMD2<Float>.zero
    var occRects: (compact: [SIMD4<Float>], behind: [SIMD4<Float>], hard: [SIMD4<Float>]) = ([], [], [])
    var occStrength: Float = 0
    var coverActive = false
    var shrunk: CGRect?
    var liveLocal: CGRect?
    var scale: CGFloat = 1
}

let renderVariants: [RenderVariant] = [
    RenderVariant(name: "plain"),
    RenderVariant(name: "contrast+reduce+economy+drag", contrast: 1, reduceMotion: true, economy: true, shiftID: 2, shift: SIMD2(14, -6)),
    RenderVariant(name: "compact soft cut", occRects: ([SIMD4(100, 150, 560, 640)], [SIMD4(600, 100, 900, 400)], [SIMD4(20, 500, 140, 700)]), occStrength: 0.6, coverActive: true, liveLocal: CGRect(x: 600, y: 0, width: 400, height: 800)),
    RenderVariant(name: "shrunk live strip 2x", occRects: ([SIMD4(0, 0, 600, 800)], [], []), occStrength: 1, coverActive: true, shrunk: CGRect(x: 600, y: 0, width: 400, height: 800), liveLocal: CGRect(x: 600, y: 0, width: 400, height: 800), scale: 2),
]
