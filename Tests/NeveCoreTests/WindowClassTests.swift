import CoreGraphics
import Foundation
import Testing
@testable import NeveCore

private func rw(_ n: Int, pid: Int = 10, layer: Int = 0, owner: String? = nil, _ b: CGRect = CGRect(x: 0, y: 0, width: 300, height: 200)) -> RawWindow {
    RawWindow(number: n, pid: pid, layer: layer, bounds: b, owner: owner)
}

@Test func layerZeroIsASurface() { #expect(classifyWindows([rw(1)]) == [.surface]) }

@Test func floatingPanelAloneIsASurface() {
    #expect(classifyWindows([rw(1, layer: 3)]) == [.surface])
}

@Test func tinyFloatingWindowIsAnOccluder() {
    #expect(classifyWindows([rw(1, layer: 3, CGRect(x: 0, y: 0, width: 30, height: 100))]) == [.occluder])
    #expect(classifyWindows([rw(1, layer: 3, CGRect(x: 0, y: 0, width: 100, height: 15))]) == [.occluder])
}

@Test func floatingPanelOverItsOwnLargerWindowIsAnOccluder() {
    let big = rw(2, pid: 10, CGRect(x: 0, y: 0, width: 800, height: 600))
    let pal = rw(1, pid: 10, layer: 3, CGRect(x: 700, y: 50, width: 200, height: 100))
    #expect(classifyWindows([pal, big]) == [.occluder, .surface])
    let other = rw(3, pid: 99, CGRect(x: 0, y: 0, width: 800, height: 600))   // another app's window: not its sibling
    #expect(classifyWindows([pal, other]) == [.surface, .surface])
    let apart = rw(4, pid: 10, CGRect(x: 2000, y: 0, width: 800, height: 600))   // same app, not intersecting
    #expect(classifyWindows([pal, apart]) == [.surface, .surface])
}

@Test func systemOwnersOwnWindowsAndOtherLayersAreIgnored() {
    #expect(classifyWindows([rw(1, layer: 20, owner: "Dock"), rw(2, layer: 5, owner: "Control Center"), rw(3, layer: 25), rw(4, layer: -1)]) == [.ignore, .ignore, .ignore, .ignore])
    #expect(classifyWindows([rw(1, pid: 77, layer: 5)], ownPID: 77) == [.ignore])
    #expect(classifyWindows([rw(1, pid: 77)], ownPID: 77) == [.surface])   // Neve's own normal windows (Ajustes) still count
}

@Test func filterBuildsOccluderOnlyInfos() {
    let raw = [rw(1, pid: 10, layer: 3, CGRect(x: 0, y: 0, width: 30, height: 100)), rw(2, layer: 3, owner: "Dock"), rw(3)]
    let out = filterWindows(raw, primaryHeight: 900)
    #expect(out.map(\.number) == [1, 3])
    #expect(out.map(\.occluderOnly) == [true, false])
}

@Test func missionControlIsTwoOrMoreFullScreenDockWindowsAtLayers18To20() {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
    func dock(_ l: Int, _ b: CGRect, alpha: Double = 1, _ o: String = "Dock") -> RawWindow { RawWindow(number: 1, pid: 1, layer: l, alpha: alpha, bounds: b, owner: o) }
    let wall = dock(-2147483624, screen)
    #expect(!isMissionControl([wall, dock(20, screen)], screens: [screen]))                          // normal: the "Dock" window only
    #expect(!isMissionControl([dock(20, screen)], screens: [screen]))
    #expect(isMissionControl([wall, dock(20, screen), dock(20, screen), dock(18, screen)], screens: [screen]))   // Mission Control open
    #expect(!isMissionControl([dock(20, screen), dock(20, screen, alpha: 0.1)], screens: [screen]))
    #expect(!isMissionControl([dock(20, screen), dock(19, CGRect(x: 0, y: 0, width: 400, height: 80))], screens: [screen]))
    #expect(!isMissionControl([dock(20, screen), dock(18, screen, "Finder")], screens: [screen]))
    #expect(isMissionControl([dock(20, second), dock(18, second)], screens: [screen, second]))
}

@Test func missionControlGateDebouncesReleasesAndHasAWatchdog() {
    var g = MissionControlGate()
    func r(_ p: Bool, _ t: Double) -> Bool { g.read(p, now: t) }
    #expect(!r(true, 0) && g.pending)          // one positive read: not yet
    #expect(!r(false, 0.25) && !g.pending)     // a blip resets
    #expect(!r(true, 1)); #expect(r(true, 1.25))
    #expect(r(true, 5))
    #expect(!r(false, 5.25))                   // first negative read releases
    _ = r(true, 6); #expect(r(true, 6.25))
    #expect(!r(true, 6.25 + 15.5))             // watchdog
    #expect(!r(true, 30)); #expect(!r(true, 31))   // stays off while the reads stay positive
    _ = r(false, 32)
    _ = r(true, 33); #expect(r(true, 33.25))
    g.release()                                // Esc / click
    #expect(!g.active); #expect(!r(true, 34))
}

@Test func fullScreenOverlayOfAnotherAppIsIgnored() {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let dimmer = rw(1, pid: 50, layer: 8, screen), nearly = rw(2, pid: 50, layer: 8, CGRect(x: 0, y: 0, width: 1440, height: 850)), panel = rw(3, pid: 51, layer: 8)
    #expect(classifyWindows([dimmer, nearly, panel], screens: [screen]) == [.ignore, .ignore, .surface])
    #expect(classifyWindows([dimmer], screens: []) == [.surface])
    #expect(filterWindows([dimmer, panel, rw(4, pid: 52, layer: 0, screen)], primaryHeight: 900, screens: [screen]).map(\.number) == [3, 4])   // layer 0 is untouched
}

@Test func occluderOnlyWindowsCarryNoSnow() {
    let f = makeField()
    var pal = win(5, 300, 300, 200, 100); pal.occluderOnly = true
    f.update(windows: [pal, win(6, 100, 200, 300, 200)])
    #expect(!f.surfaces.contains { $0.id == 5 })
    #expect(f.surfaces.contains { $0.id == 6 })
    f.update(windows: [win(5, 300, 300, 200, 100), win(6, 100, 200, 300, 200)], now: 1)
    #expect(f.surfaces.contains { $0.id == 5 })
}

@Test func remapHeightsKeepsProportion() {
    #expect(remapHeights([1, 2, 3, 4], to: 4) == [1, 2, 3, 4])
    #expect(remapHeights([1, 3], to: 4) == [1, 1, 3, 3])
    #expect(remapHeights([1, 1, 3, 3], to: 2) == [1, 3])
    #expect(remapHeights([2, 2, 6, 6, 4, 4], to: 3) == [2, 6, 4])
    #expect(remapHeights([], to: 3) == [0, 0, 0])
    #expect(remapHeights([5], to: 0).isEmpty)
}

@Test func resizeKeepsGroundSnowByProportionAndWindowSnowByID() {
    let f = makeField()
    f.update(windows: [win(1, 100, 200, 300, 200)])
    pileUp(f, id: 1)
    pileUp(f, id: Tuning.groundID, rounds: 3)
    let groundTotal = f.surfaces.first { $0.id == Tuning.groundID }!.pile.heights.reduce(0, +)
    let win1 = f.surfaces.first { $0.id == 1 }!.pile.heights
    f.resize(size: CGSize(width: 2000, height: 1000), origin: .zero, groundY: 100, visibleTop: 980)
    #expect(f.size.x == 2000)
    let g = f.surfaces.first { $0.id == Tuning.groundID }!.pile
    #expect(g.heights.count == f.numCols)
    #expect(groundTotal > 0)
    #expect(abs(g.heights.max()! - f.surfaces.first { $0.id == Tuning.groundID }!.pile.heights.min()!) >= 0)   // built, finite
    #expect(g.heights.reduce(0, +) > 0)
    #expect(!f.surfaces.contains { $0.id == 1 })   // stashed by id
    f.update(windows: [win(1, 100, 200, 300, 200)], now: 1)   // the window returns
    let back = f.surfaces.first { $0.id == 1 }!.pile.heights
    #expect(back == win1)
}

@Test func resizeCarriesTheDockPile() {
    let f = makeField()
    f.update(windows: [win(0, 300, 10, 600, 60)])
    pileUp(f, id: 0)
    let before = f.surfaces.first { $0.id == 0 }!.pile.heights.reduce(0, +)
    #expect(before > 0)
    f.resize(size: CGSize(width: 2000, height: 1000), origin: .zero, groundY: 100, visibleTop: 980)
    f.update(windows: [win(0, 600, 10, 1200, 60)], now: 1)
    let after = f.surfaces.first { $0.id == 0 }!.pile.heights
    #expect(after.reduce(0, +) > 0)
}

@Test func menuShortcutAndScreensaverPredicates() {
    #expect(optionClickOpensSettings(option: true, control: false, mouse: true))
    #expect(!optionClickOpensSettings(option: true, control: true, mouse: true))    // VoiceOver
    #expect(!optionClickOpensSettings(option: true, control: false, mouse: false))  // keyboard open
    #expect(!optionClickOpensSettings(option: false, control: false, mouse: true))
    #expect(isScreensaverEngine("com.apple.ScreenSaver.Engine") && !isScreensaverEngine(nil) && !isScreensaverEngine("com.apple.finder"))
}
