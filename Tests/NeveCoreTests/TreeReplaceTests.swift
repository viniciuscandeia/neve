// AGENT HEADER - Tests/NeveCoreTests/TreeReplaceTests.swift  (Tree.swift dropTree(replacing:))
// The "Soltar árvore" menu with a tree already about replaces it: the old tree / burst is gone, a new gust starts, and there is still exactly one tree in total (also with the new one fallen and landed).

import CoreGraphics
import Testing
@testable import NeveCore

@Test func replacingDropRemovesTheOldTreeAndLeavesExactlyOne() {
    let f = makeField()
    f.update(windows: [])
    f.treeEnabled = true
    #expect(f.dropTree() && !f.dropTree())            // plain drop still refuses a second
    advance(f, 4)
    #expect(f.tree?.state == .resting)
    #expect(f.dropTree(replacing: true))
    #expect(f.tree == nil && f.burst != nil)           // one thing only: the new burst
    advance(f, 4)
    #expect(f.tree?.state == .resting && f.burst == nil)
    #expect(f.hasTree && !f.dropTree())
}
