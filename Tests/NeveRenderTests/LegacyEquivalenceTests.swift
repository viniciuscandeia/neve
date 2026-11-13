// AGENT HEADER - Tests/NeveRenderTests/LegacyEquivalenceTests.swift  (TEMPORARY BRIDGE test: the old render path draws the deterministic scenario offscreen; it must be non-blank and repeatable)
// Role: bridge commit only checks the legacy path is stable on this machine (two renders of two identical worlds give identical bytes). The extraction commit extends it to compare NeveRender's bytes with these. Delete with Tests/NeveRenderTests/Legacy.

import Foundation
import Metal
import NeveCore
import Testing

func legacyInputs(_ v: RenderVariant) -> LegacyInputs {
    var i = LegacyInputs()
    i.contrast = v.contrast; i.reduceMotion = v.reduceMotion; i.economyOrLowPower = v.economy; i.time = v.time
    i.shiftID = v.shiftID; i.shift = v.shift
    for (k, r) in v.occRects.compact.enumerated() { i.occ[k] = r }
    for (k, r) in v.occRects.behind.enumerated() { i.occ[8 + k] = r }
    for (k, r) in v.occRects.hard.enumerated() { i.occ[16 + k] = r }
    i.occCount = (v.occRects.compact.count, v.occRects.behind.count, v.occRects.hard.count)
    i.occStrength = v.occStrength; i.coverActive = v.coverActive; i.shrunk = v.shrunk; i.liveLocal = v.liveLocal; i.scale = v.scale
    return i
}

@Test(arguments: renderVariants.map(\.name))
func legacyPathIsStable(_ name: String) throws {
    let v = try #require(renderVariants.first { $0.name == name })
    let gpu = try #require(LegacyGpu(), "Metal unavailable")
    let a = try #require(legacyRender(gpu, renderScenario(), legacyInputs(v)))
    let b = try #require(legacyRender(gpu, renderScenario(), legacyInputs(v)))
    #expect(a.contains { $0 != 0 }, "blank frame")
    #expect(a == b)
}
