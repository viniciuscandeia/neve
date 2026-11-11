// AGENT HEADER - Tests/NeveCoreTests/PrefDiffTests.swift  (changedKeys snapshot diff; pointerPush toggle is reported)

import Testing
@testable import NeveCore

@Test func changedKeysDiffsSnapshots() {
    #expect(changedKeys(old: ["a": true, "b": false], new: ["a": true, "b": false]).isEmpty)
    #expect(changedKeys(old: ["a": true, "b": false], new: ["a": false, "b": false]) == ["a"])
    #expect(Set(changedKeys(old: ["a": true], new: ["a": false, "b": true])) == ["a", "b"])
}

@Test func pointerPushToggleIsReported() {
    #expect(changedKeys(old: ["pointerPush": true], new: ["pointerPush": false]) == ["pointerPush"])
}
