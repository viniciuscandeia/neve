// AGENT HEADER - Tests/NeveLabCoreTests/LabDockTests.swift  (the virtual Dock and the appearance of the Neve Lab world)
// Role: `LabWorld` with a Dock (default) mirrors the app: the bar is WindowInfo number 0 (surface id 0) over a raised ground (VDock.ground, like visibleFrame.minY), so after snowfall the ground bank rises beside the bar,
//   snow collects in the gap under it and on its top (the Dock pile); the Dock growing fast (set_dock with more icons, ends move at Tuning.dockSpeed > dockOverSpeed) into a high bank crests ground snow onto the Dock pile far above the calm rate.
//   Also: config / state / actions (`set_dock`, `set_appearance`, validation, preparation flag), the Dock-less world keeps the old flat ground, and the appearance never changes the simulation (digest equal).
// Helpers `act`, `snap`, `volume` live in LabWorldTests.swift. Snowfall runs are minutes of simulated time (cheap in release; debug takes longer).

import Foundation
import NeveCore
import Testing
@testable import NeveLabCore

private func dockWorld(seed: UInt64 = 3, dock: Bool = true, dark: Bool = false) -> LabWorld {
    var c = LabConfig()
    c.seed = seed; c.dock = dock; c.dark = dark
    c.prefs = [.visitors: false, .sleigh: false, .snowman: false, .walk: false]
    return LabWorld(config: c)
}
private func heights(_ w: LabWorld, _ id: Int) -> [Double] { (w.field.labSurfaces.first { $0.id == id }?.heights ?? []).map(Double.init) }
private func vol(_ w: LabWorld, _ id: Int) -> Double { Double(w.field.labSurfaces.first { $0.id == id }?.volume ?? 0) }

@Test func stateReportsDockAndAppearance() throws {
    let w = dockWorld()
    let s = snap(w), d = s["dock"] as! [String: Any], f = d["frame"] as! [String: Any]
    #expect(d["position"] as? String == "bottom" && d["icons"] as? Int == 12 && d["ground"] as? Double == 85)
    #expect(f["h"] as? Double == 84 && f["w"] as? Double == 716 && f["x"] as? Double == 282)
    #expect(f["y"] as? Double == 711)   // glass: AX list 10 pt above the bottom + the 5 pt glass offset (Tuning.dockGlass) => bottom 5 pt above the screen edge
    #expect((s["screen"] as! [String: Any])["appearance"] as? String == "light")
    try act(w, #"{"type":"advance","steps":1}"#)
    #expect(volume(w, 0) != nil, "the Dock is surface 0")
    let n = snap(dockWorld(dock: false))["dock"] as! [String: Any]
    #expect(n["position"] as? String == "none" && n["frame"] is NSNull)
    #expect((snap(dockWorld(dark: true))["screen"] as! [String: Any])["appearance"] as? String == "dark")
}

@Test func dockAndAppearanceActions() throws {
    let w = dockWorld()
    #expect(try act(w, #"{"type":"set_dock","position":"none"}"#)["preparation"] as? Bool == true)
    #expect((snap(w)["dock"] as! [String: Any])["position"] as? String == "none" && volume(w, 0) == nil)
    try act(w, #"{"type":"set_dock","position":"bottom","icons":5}"#)
    let f = (snap(w)["dock"] as! [String: Any])["frame"] as! [String: Any]
    #expect(f["w"] as? Double == 310)
    #expect(try act(w, #"{"type":"set_appearance","appearance":"dark"}"#)["preparation"] as? Bool == true)
    #expect(w.dark && (snap(w)["screen"] as! [String: Any])["appearance"] as? String == "dark")
    let before = w.state()
    for bad in [#"{"type":"set_dock","position":"left"}"#, #"{"type":"set_dock","position":"bottom","icons":0}"#, #"{"type":"set_dock"}"#, #"{"type":"set_appearance","appearance":"sepia"}"#, #"{"type":"set_appearance"}"#] {
        #expect(throws: LabError.self) { try w.apply(bad) }
    }
    #expect(w.state() == before)
}

@Test func appearanceDoesNotChangeTheSimulation() throws {
    let a = dockWorld(), b = dockWorld(dark: true)
    for w in [a, b] { try act(w, #"{"type":"advance","seconds":20}"#) }
    #expect(a.digest() == b.digest())
}

@Test func snowfallBuildsGroundBankBesideTheBarAndSnowUnderIt() throws {
    let w = dockWorld()
    try act(w, #"{"type":"advance","seconds":120}"#)
    let g = heights(w, -1), bin = 1280.0 / Double(g.count)
    func h(_ x: Double) -> Double { g[Int(x / bin)] }
    // bar spans x 282...998: the bank beside its ends is higher than the open ground far away, and snow lies in the gap under the flat
    #expect(h(270) > h(60) + 3, "bank beside the left end \(h(270)) vs open ground \(h(60))")
    #expect(h(1010) > h(1230) + 3, "bank beside the right end \(h(1010)) vs open ground \(h(1230))")
    let span = g.indices.filter { Double($0) * bin >= 282 && Double($0) * bin < 998 }
    #expect(span.filter { g[$0] > 0.5 }.count >= 10, "snow flows into the gap under the bar's ends")
    #expect(span.filter { Double($0) * bin > 340 && Double($0) * bin < 940 }.allSatisfy { g[$0] <= 5.001 }, "along the flat the gap snow stays below the glass bottom (5 pt)")
    #expect(vol(w, 0) > 1000, "snow on the Dock top")
    // without a Dock the ground is the flat ground: no bank, nothing under a bar
    let n = dockWorld(dock: false); try act(n, #"{"type":"advance","seconds":120}"#)
    #expect(heights(n, -1).max()! < 28.5 && volume(n, 0) == nil)
}

@Test func aFastPushIntoTheDockCrestsSnowOntoTheDockPile() throws {
    // The "push" is the Dock itself growing fast (more icons: each end moves at Tuning.dockSpeed 800 pt/s > dockOverSpeed 500) into a high ground bank: what rises above the bar's top arcs onto the Dock pile.
    let w = dockWorld()
    try act(w, #"{"type":"advance","seconds":400}"#)
    let v0 = vol(w, 0), g0 = vol(w, -1)
    try act(w, #"{"type":"advance","seconds":1}"#)
    let idle = vol(w, 0) - v0, v1 = vol(w, 0), g1 = vol(w, -1)
    try act(w, #"{"type":"set_dock","position":"bottom","icons":16}"#)
    try act(w, #"{"type":"advance","seconds":1}"#)
    let crest = vol(w, 0) - v1
    #expect(crest > 300 && crest > 20 * max(idle, 1), "Dock pile +\(crest) after the push vs +\(idle) in a calm second")
    #expect(vol(w, -1) - g1 < g1 - g0 - 100, "the ground bank gave the snow up")
}
