// AGENT HEADER - Tests/NeveRenderTests/LegacyEquivalenceTests.swift  (TEMPORARY BRIDGE test: the old render path draws the deterministic scenario offscreen; it must be non-blank and repeatable)
// Role: bridge commit only checks the legacy path is stable on this machine (two renders of two identical worlds give identical bytes). The extraction commit extends it to compare NeveRender's bytes with these. Delete with Tests/NeveRenderTests/Legacy.

import Foundation
import Metal
import NeveCore
import NeveRender
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

/// The extraction's contract: NeveRender draws byte-for-byte what the old Overlay path drew (same machine, same GPU).
@Test(arguments: renderVariants.map(\.name))
func neveRenderMatchesLegacyBytes(_ name: String) throws {
    let v = try #require(renderVariants.first { $0.name == name })
    let legacy = try #require(LegacyGpu(), "Metal unavailable")
    let gpu = try #require(Gpu(), "Metal unavailable")
    let a = try #require(legacyRender(legacy, renderScenario(), legacyInputs(v)))
    let b = try #require(offscreenRender(gpu, renderScenario(), v))
    #expect(a.count == b.count)
    var maxDiff = 0, diffs = 0
    for i in 0..<min(a.count, b.count) where a[i] != b[i] { diffs += 1; maxDiff = max(maxDiff, abs(Int(a[i]) - Int(b[i]))) }
    print("EQUIV \(name): \(a.count) bytes, \(diffs) differ, max diff \(maxDiff)")
    #expect(diffs == 0, "\(diffs) bytes differ, max \(maxDiff)")
}
