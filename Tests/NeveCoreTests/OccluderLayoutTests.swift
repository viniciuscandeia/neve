// AGENT HEADER - Tests/NeveCoreTests/OccluderLayoutTests.swift  (which window rects fill the flake shader's occluder slots: Coverage.swift `occluderLayout`)
// Covers: windows with no surface (top within minHeadroom of the menu bar) go to the always-on hard slots; every front window hides background flakes (behindLarge, any size); compact mode keeps up to 8 rects; panels follow the bare windows.

import CoreGraphics
import Testing
@testable import NeveCore

private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800), vis = CGRect(x: 0, y: 90, width: 1000, height: 690)

@Test func aZoomedWindowIsAnAlwaysOnOccluder() {
    let zoomed = win(1, 0, 90, 500, 685), normal = win(2, 500, 200, 300, 200)   // top 775: 5 pt under the menu bar
    let l = occluderLayout(windows: [zoomed, normal], vis: vis, screen: screen, behindWindows: false, behindFar: true)
    #expect(l.hard == [zoomed.frame] && l.behind == [normal.frame])
}

@Test func everyFrontWindowHidesBackgroundFlakesNotJustLargeOnes() {
    let small = win(3, 100, 200, 120, 80)   // far below 35 % of the screen
    let l = occluderLayout(windows: [small], vis: vis, screen: screen, behindWindows: false, behindFar: true)
    #expect(l.behind == [small.frame])
    #expect(occluderLayout(windows: [small], vis: vis, screen: screen, behindWindows: false, behindFar: false).behind.isEmpty)
}

@Test func compactModeKeepsEightRects() {
    let ws = (1...10).map { win($0, CGFloat($0) * 50, 200, 40 + CGFloat($0), 100) }
    let l = occluderLayout(windows: ws, vis: vis, screen: screen, behindWindows: false, behindFar: true)
    #expect(l.compact.count == 8 && l.behind.count == 8)
    #expect(OccluderLayout.slots == 8)
}

@Test func panelsFollowTheBareWindowsInTheHardSlots() {
    let zoomed = win(1, 0, 90, 500, 685), panel = WindowInfo(number: 9, frame: CGRect(x: 600, y: 300, width: 200, height: 100), occluderOnly: true)
    let l = occluderLayout(windows: [panel, zoomed], vis: vis, screen: screen, behindWindows: false, behindFar: false)
    #expect(l.hard == [zoomed.frame, panel.frame])
}

@Test func softCutFadesOnlyPrimsOutsideTheLiveRect() {
    let p = UnsafeMutablePointer<Prim>.allocate(capacity: 4); defer { p.deallocate() }
    var w = PrimWriter(p, capacity: 4)
    w.ellipse(center: SIMD2(50, 50), radii: SIMD2(5, 5), color: SIMD4(1, 1, 1, 1))
    w.ellipse(center: SIMD2(500, 50), radii: SIMD2(5, 5), color: SIMD4(1, 1, 1, 1))
    w.fadeOutside(SIMD4(0, 0, 100, 100), by: 0.25)
    #expect(p[0].color.w == 1 && p[1].color.w == 0.25)
}
