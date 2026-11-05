import CoreGraphics
import Testing
import NeveCore

// Primary screen is 1440x900 in all examples. CG: origin top-left, y down. AppKit: origin bottom-left, y up.

@Test func cgFrameOnPrimaryFlipsY() {
    let r = appKitFrame(fromCG: CGRect(x: 100, y: 50, width: 300, height: 200), primaryHeight: 900)
    #expect(r == CGRect(x: 100, y: 650, width: 300, height: 200))
}

@Test func cgFrameOnScreenAbovePrimaryHasYAboveTop() {
    // Secondary screen above primary: CG y is negative. 900 + 500 - 200 = 1200.
    let r = appKitFrame(fromCG: CGRect(x: 10, y: -500, width: 300, height: 200), primaryHeight: 900)
    #expect(r == CGRect(x: 10, y: 1200, width: 300, height: 200))
}

@Test func cgFrameOnScreenLeftOfPrimaryKeepsNegativeX() {
    let r = appKitFrame(fromCG: CGRect(x: -1000, y: 100, width: 400, height: 300), primaryHeight: 900)
    #expect(r == CGRect(x: -1000, y: 500, width: 400, height: 300))
}

@Test func cgFrameOnScreenBelowPrimaryHasNegativeY() {
    let r = appKitFrame(fromCG: CGRect(x: 0, y: 900, width: 200, height: 100), primaryHeight: 900)
    #expect(r == CGRect(x: 0, y: -100, width: 200, height: 100))
}

// MARK: - Window filter

private func raw(_ n: Int, pid: Int = 500, layer: Int? = 0, alpha: Double = 1,
                 _ bounds: CGRect? = CGRect(x: 0, y: 0, width: 300, height: 200)) -> RawWindow {
    RawWindow(number: n, pid: pid, layer: layer, alpha: alpha, bounds: bounds)
}

private func numbers(_ w: [RawWindow], own: Int = 999) -> [Int] {
    filterWindows(w, ownPID: own, primaryHeight: 900).map(\.number)
}

@Test func filterKeepsNormalWindowsInOrderAndConvertsFrames() {
    let out = filterWindows([raw(7, CGRect(x: 100, y: 50, width: 300, height: 200)), raw(3)], ownPID: 999, primaryHeight: 900)
    #expect(out.map(\.number) == [7, 3])
    #expect(out[0].frame == CGRect(x: 100, y: 650, width: 300, height: 200))
}

@Test func filterDropsNonZeroLayers() {
    #expect(numbers([raw(1, layer: 25), raw(2, layer: -1), raw(3, layer: nil), raw(4)]) == [4])
}

@Test func filterDropsFullyTransparentWindows() {
    #expect(numbers([raw(1, alpha: 0), raw(2, alpha: 0.01), raw(3, alpha: 1)]) == [2, 3])
}

@Test func filterDropsOwnProcessWindows() {
    #expect(numbers([raw(1, pid: 999), raw(2, pid: 998)], own: 999) == [2])
}

@Test func filterEnforcesMinimumSize() {
    let sizes: [(Int, CGFloat, CGFloat)] = [(1, 40, 20), (2, 39, 20), (3, 40, 19), (4, 400, 10)]
    let w = sizes.map { raw($0.0, CGRect(x: 0, y: 0, width: $0.1, height: $0.2)) }
    #expect(numbers(w) == [1])
}

@Test func filterDropsEntriesMissingNumberOrBounds() {
    let noNumber = RawWindow(number: nil, pid: 1, layer: 0, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
    #expect(numbers([noNumber, raw(2, nil), raw(3)]) == [3])
}
