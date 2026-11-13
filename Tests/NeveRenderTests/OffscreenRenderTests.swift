// AGENT HEADER - Tests/NeveRenderTests/OffscreenRenderTests.swift  (permanent: NeveRender draws a deterministic scenario offscreen, non-blank and repeatable)
// Role: every RenderVariant renders to a non-empty frame, and two renders of two identical worlds give identical bytes. Equivalence with the old path lives in LegacyEquivalenceTests (bridge).

import NeveCore
import NeveRender
import Testing

@Test(arguments: renderVariants.map(\.name))
func offscreenFrameIsNonBlankAndRepeatable(_ name: String) throws {
    let v = try #require(renderVariants.first { $0.name == name })
    let gpu = try #require(Gpu(), "Metal unavailable")
    let a = try #require(offscreenRender(gpu, renderScenario(), v))
    let b = try #require(offscreenRender(gpu, renderScenario(), v))
    #expect(a.contains { $0 != 0 })
    #expect(a == b)
}
