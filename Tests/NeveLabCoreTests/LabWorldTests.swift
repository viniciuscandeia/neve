// AGENT HEADER - Tests/NeveLabCoreTests/LabWorldTests.swift  (Neve Lab world model: determinism, state() purity, invalid actions, window physics, scoop/throw, tree)
// Role: drives `LabWorld` through JSON actions only (no private access except the NeveCore `package` helpers in LabAccess.swift via LabWorld.digest()). Visitors / sleigh / snowman are switched off where a test measures physics, so nothing else interferes.
// Coordinates in these tests are IMAGE coordinates (top-left origin): the ground is at y = 800, a window's top edge at its y.

import Foundation
import NeveCore
import Testing
@testable import NeveLabCore

func quietWorld(seed: UInt64 = 7) -> LabWorld {
    var c = LabConfig()
    c.seed = seed
    c.prefs = [.visitors: false, .sleigh: false, .snowman: false, .walk: false]
    return LabWorld(config: c)
}

@discardableResult func act(_ w: LabWorld, _ json: String) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(try w.apply(json).utf8)) as! [String: Any]
}
func snap(_ w: LabWorld) -> [String: Any] { try! JSONSerialization.jsonObject(with: Data(w.state().utf8)) as! [String: Any] }
func volume(_ w: LabWorld, _ id: Int) -> Double? { (snap(w)["snow"] as! [[String: Any]]).first { $0["id"] as? Int == id }?["volume"] as? Double }
func balls(_ w: LabWorld) -> [[String: Any]] { snap(w)["balls"] as! [[String: Any]] }

let script = [
    #"{"type":"create_window","id":1,"title":"A","x":100,"y":200,"w":400,"h":300}"#,
    #"{"type":"create_window","id":2,"title":"B","x":300,"y":150,"w":400,"h":300}"#,
    #"{"type":"advance","steps":120}"#,
    #"{"type":"fill_pile","surface":1,"height":15}"#,
    #"{"type":"move_window","id":2,"x":500,"y":250,"duration":0.5}"#,
    #"{"type":"minimize_window","id":1}"#,
    #"{"type":"advance","steps":90}"#,
    #"{"type":"restore_window","id":1}"#,
    #"{"type":"cursor_move","x":600,"y":400,"duration":0.3}"#,
    #"{"type":"advance","steps":60}"#,
]

@Test func sameSeedSameActionsSameWorld() throws {
    func run() throws -> LabWorld { let w = LabWorld(config: { var c = LabConfig(); c.seed = 99; return c }()); for a in script { try w.apply(a) }; return w }
    let a = try run(), b = try run()
    #expect(a.state() == b.state())
    #expect(a.digest() == b.digest())
    try act(a, #"{"type":"advance","steps":300}"#); try act(b, #"{"type":"advance","steps":300}"#)
    #expect(a.state() == b.state())
    #expect(a.digest() == b.digest())
    #expect(a.restarted().digest() == LabWorld(config: a.config).digest())
}

@Test func differentSeedsDiffer() throws {
    let a = quietWorld(seed: 1), b = quietWorld(seed: 2)
    try act(a, #"{"type":"advance","steps":30}"#); try act(b, #"{"type":"advance","steps":30}"#)
    #expect(a.digest() != b.digest())
}

@Test func stateCallsDoNotChangeEvolution() throws {
    let a = quietWorld(), b = quietWorld()
    for s in script { try a.apply(s); try b.apply(s); _ = b.state(); _ = b.digest() }
    for _ in 0..<50 { try a.apply(#"{"type":"advance","steps":3}"#); try b.apply(#"{"type":"advance","steps":3}"#); _ = b.state() }
    #expect(a.digest() == b.digest())
    #expect(a.state() == b.state())
}

@Test func invalidActionsLeaveTheWorldUnchanged() throws {
    let w = quietWorld()
    try act(w, #"{"type":"create_window","id":1,"title":"A","x":100,"y":200,"w":400,"h":300}"#)
    try act(w, #"{"type":"advance","steps":30}"#)
    let s0 = w.state(), d0 = w.digest()
    let bad = [
        "not json", "[]", #"{"type":"nope"}"#, #"{"title":"x"}"#,
        #"{"type":"create_window","id":1,"title":"dup","x":0,"y":0,"w":10,"h":10}"#,
        #"{"type":"create_window","title":"t","x":0,"y":0,"w":0,"h":10}"#,
        #"{"type":"create_window","title":"t","x":"a","y":0,"w":10,"h":10}"#,
        #"{"type":"create_window","title":"t","x":true,"y":0,"w":10,"h":10}"#,
        #"{"type":"create_window","title":"t","x":0,"y":0,"w":10,"h":10,"extra":1}"#,
        #"{"type":"move_window","id":9,"x":0,"y":0}"#,
        #"{"type":"move_window","id":1,"x":0,"y":0,"drag":true}"#,
        #"{"type":"move_window","id":1,"x":0,"y":0,"duration":-1}"#,
        #"{"type":"close_window","id":42}"#, #"{"type":"restore_window","id":42}"#,
        #"{"type":"mouse_up"}"#, #"{"type":"advance"}"#, #"{"type":"advance","steps":1,"seconds":1}"#, #"{"type":"advance","steps":-1}"#, #"{"type":"advance","steps":1.5}"#,
        #"{"type":"fill_pile","surface":77,"height":5}"#, #"{"type":"fill_pile","surface":"sky","height":5}"#,
        #"{"type":"set_pref","pref":"zzz","value":true}"#, #"{"type":"set_pref","pref":"snowman"}"#, #"{"type":"set_intensity","level":"x"}"#,
        #"{"type":"drop_tree","replacing":"yes"}"#,
    ]
    for a in bad {
        #expect(throws: LabError.self) { try w.apply(a) }
        #expect(w.state() == s0, "state changed by \(a)")
        #expect(w.digest() == d0, "digest changed by \(a)")
    }
    try act(w, #"{"type":"mouse_down"}"#)
    #expect(throws: LabError.self) { try w.apply(#"{"type":"mouse_down"}"#) }
}

@Test func coordinatesAreImageCoordinates() throws {
    let w = quietWorld()
    try act(w, #"{"type":"create_window","id":5,"title":"T","x":100,"y":100,"w":300,"h":200}"#)
    let win = (snap(w)["windows"] as! [[String: Any]])[0]
    #expect((win["frame"] as! [String: Double])["y"] == 100)
    try act(w, #"{"type":"fill_pile","surface":5,"height":10}"#)
    // The pile sits on the window's TOP edge (image y = 100): a press just below the top is over snow, one far below the window is not.
    try act(w, #"{"type":"option_down"}"#)
    try act(w, #"{"type":"cursor_move","x":250,"y":97}"#)
    var r = try act(w, #"{"type":"mouse_down"}"#)
    #expect(r["outcome"] as? String == "scoop")
    try act(w, #"{"type":"mouse_up"}"#)
    try act(w, #"{"type":"cursor_move","x":250,"y":600}"#)
    r = try act(w, #"{"type":"mouse_down"}"#)
    #expect(r["outcome"] as? String == "passThrough")
}

@Test func closingAWindowDropsItsSnowAfterGoneGrace() throws {
    let w = quietWorld()
    try act(w, #"{"type":"create_window","id":1,"title":"A","x":300,"y":300,"w":400,"h":200}"#)
    try act(w, #"{"type":"advance","steps":30}"#)
    let r = try act(w, #"{"type":"fill_pile","surface":1,"height":20}"#)
    #expect(r["preparation"] as? Bool == true)
    try act(w, #"{"type":"advance","steps":30}"#)
    let onWindow = try #require(volume(w, 1)), ground0 = try #require(volume(w, -1))
    #expect(onWindow > 1000)
    try act(w, #"{"type":"close_window","id":1}"#)
    try act(w, #"{"type":"advance","steps":20}"#)   // 0.33 s: inside goneGrace, the ghost keeps its snow
    #expect(volume(w, 1) != nil)
    #expect((snap(w)["pendingGone"] as! [Int]) == [1])
    try act(w, #"{"type":"advance","steps":60}"#)   // past 0.6 s
    #expect(volume(w, 1) == nil)
    try act(w, #"{"type":"advance","steps":300}"#)
    #expect(try #require(volume(w, -1)) > ground0 + onWindow * 0.3, "the knocked-off snow lands on the ground")
}

@Test func minimizeDropsSnowAndRestoreBringsAnEmptyWindowBack() throws {
    let w = quietWorld()
    try act(w, #"{"type":"create_window","id":1,"title":"A","x":300,"y":300,"w":400,"h":200}"#)
    try act(w, #"{"type":"advance","steps":30}"#)
    try act(w, #"{"type":"fill_pile","surface":1,"height":20}"#)
    try act(w, #"{"type":"minimize_window","id":1}"#)
    #expect((snap(w)["windows"] as! [[String: Any]])[0]["minimized"] as? Bool == true)
    try act(w, #"{"type":"advance","steps":90}"#)
    #expect(volume(w, 1) == nil)
    try act(w, #"{"type":"restore_window","id":1}"#)
    #expect(try #require(volume(w, 1)) < 1)   // a fresh, empty pile
}

@Test func movingAWindowKeepsPartOfItsPile() throws {
    let w = quietWorld()
    try act(w, #"{"type":"create_window","id":1,"title":"A","x":100,"y":300,"w":400,"h":200}"#)
    try act(w, #"{"type":"advance","steps":30}"#)
    try act(w, #"{"type":"fill_pile","surface":1,"height":20}"#)
    let v0 = try #require(volume(w, 1))
    try act(w, #"{"type":"move_window","id":1,"x":700,"y":300,"duration":1}"#)
    let win = (snap(w)["windows"] as! [[String: Any]])[0]["frame"] as! [String: Double]
    #expect(win["x"] == 700)
    let v1 = try #require(volume(w, 1))
    #expect(v1 > 0 && v1 < v0, "a fast move shakes some snow off but the pile travels with the window")
}

@Test func windowDragTracksTheCursorAndConfirmsTheTarget() throws {
    let w = quietWorld()
    try act(w, #"{"type":"create_window","id":1,"title":"A","x":100,"y":300,"w":400,"h":200}"#)
    try act(w, #"{"type":"advance","steps":30}"#)
    try act(w, #"{"type":"move_window","id":1,"x":300,"y":320,"duration":0.5,"drag":true}"#)
    let s = snap(w), c = s["cursor"] as! [String: Any]
    #expect(c["down"] as? Bool == false)
    #expect(c["x"] as? Double == Double(300 + 200))   // grabbed at the title bar centre, followed the window by the same delta
    #expect(c["y"] as? Double == Double(320 + 15))
}

@Test func scoopRollDragAndThrow() throws {
    let w = quietWorld()
    try act(w, #"{"type":"advance","steps":10}"#)
    try act(w, #"{"type":"fill_pile","surface":"ground","height":12}"#)
    try act(w, #"{"type":"option_down"}"#)
    try act(w, #"{"type":"cursor_move","x":400,"y":795}"#)
    let r = try act(w, #"{"type":"mouse_down"}"#)
    #expect(r["outcome"] as? String == "scoop")
    let id = try #require(r["ball"] as? Int)
    #expect((snap(w)["held"] as! [String: Any])["id"] as? Int == id)
    try act(w, #"{"type":"cursor_move","x":500,"y":795,"duration":0.5}"#)   // rolled along the ground: grows
    let grown = try #require(balls(w).first)["r"] as! Double
    #expect(grown > 5)
    try act(w, #"{"type":"cursor_move","x":700,"y":500,"duration":0.4}"#)   // lifted and carried
    try act(w, #"{"type":"mouse_up"}"#)   // released while moving: a throw
    let x0 = try #require(balls(w).first)["x"] as! Double
    #expect(balls(w).first?["state"] as? String == "falling")
    try act(w, #"{"type":"advance","steps":12}"#)
    let x1 = try #require(balls(w).first)["x"] as! Double
    #expect(x1 > x0 + 20, "thrown to the right")
    try act(w, #"{"type":"advance","steps":300}"#)
    #expect(balls(w).first?["state"] as? String == "resting")
    #expect(snap(w)["held"] is NSNull)
}

@Test func pausingBeforeReleaseDropsStraightDown() throws {
    let w = quietWorld()
    try act(w, #"{"type":"advance","steps":10}"#)
    try act(w, #"{"type":"fill_pile","surface":"ground","height":12}"#)
    try act(w, #"{"type":"option_down"}"#)
    try act(w, #"{"type":"cursor_move","x":400,"y":795}"#)
    try act(w, #"{"type":"mouse_down"}"#)
    try act(w, #"{"type":"cursor_move","x":700,"y":500,"duration":0.4}"#)
    try act(w, #"{"type":"advance","steps":12}"#)   // 0.2 s still: no throw
    try act(w, #"{"type":"mouse_up"}"#)
    let x0 = try #require(balls(w).first)["x"] as! Double
    try act(w, #"{"type":"advance","steps":12}"#)
    let x1 = try #require(balls(w).first)["x"] as! Double
    #expect(abs(x1 - x0) < 5)
}

@Test func releasingOptionMidDragLetsGoAtTheNextTick() throws {
    let w = quietWorld()
    try act(w, #"{"type":"advance","steps":10}"#)
    try act(w, #"{"type":"fill_pile","surface":"ground","height":12}"#)
    try act(w, #"{"type":"option_down"}"#)
    try act(w, #"{"type":"cursor_move","x":400,"y":795}"#)
    try act(w, #"{"type":"mouse_down"}"#)
    try act(w, #"{"type":"option_up"}"#)
    #expect((snap(w)["held"] as! [String: Any])["kind"] as? String == "ball")   // the app also lets go at its next frame
    try act(w, #"{"type":"advance","steps":1}"#)
    #expect(snap(w)["held"] is NSNull)
}

@Test func treePickDragRelease() throws {
    let w = quietWorld(seed: 3)
    try act(w, #"{"type":"advance","steps":10}"#)
    try act(w, #"{"type":"fill_pile","surface":"ground","height":10}"#)
    let r = try act(w, #"{"type":"drop_tree"}"#)
    #expect(r["preparation"] as? Bool == true)
    #expect(snap(w)["hasTree"] as? Bool == true)
    #expect(throws: LabError.self) { try w.apply(#"{"type":"drop_tree"}"#) }   // one tree at a time
    try act(w, #"{"type":"advance","steps":600}"#)
    var tree = try #require(snap(w)["tree"] as? [String: Any])
    #expect(tree["state"] as? String == "resting")
    let tx = tree["x"] as! Double, ty = tree["y"] as! Double
    try act(w, #"{"type":"option_down"}"#)
    try act(w, #"{"type":"cursor_move","x":\#(tx),"y":\#(ty - 70)}"#)
    let press = try act(w, #"{"type":"mouse_down"}"#)
    #expect(press["outcome"] as? String == "tree")
    #expect((snap(w)["held"] as! [String: Any])["kind"] as? String == "tree")
    try act(w, #"{"type":"cursor_move","x":\#(tx + 200),"y":\#(ty - 120),"duration":0.5}"#)
    tree = try #require(snap(w)["tree"] as? [String: Any])
    #expect(tree["state"] as? String == "held")
    #expect(abs((tree["x"] as! Double) - (tx + 200)) < 30)
    try act(w, #"{"type":"advance","steps":12}"#)
    try act(w, #"{"type":"mouse_up"}"#)
    #expect(snap(w)["held"] is NSNull)
    try act(w, #"{"type":"advance","steps":300}"#)
    tree = try #require(snap(w)["tree"] as? [String: Any])
    #expect(tree["state"] as? String == "resting")
    #expect(abs((tree["x"] as! Double) - (tx + 200)) < 60, "it landed where it was dropped")
}

@Test func prefsAndRestart() throws {
    let w = quietWorld()
    try act(w, #"{"type":"set_pref","pref":"snowman","value":true}"#)
    try act(w, #"{"type":"set_intensity","level":"forte"}"#)
    let s = snap(w)
    #expect((s["prefs"] as! [String: Bool])["snowman"] == true)
    #expect(s["intensity"] as? String == "forte")
    try act(w, #"{"type":"advance","steps":5}"#)
    let r = w.restarted()
    #expect(snap(r)["step"] as? Int == 0)
    #expect((snap(r)["prefs"] as! [String: Bool])["snowman"] == false)   // same config, not the session's later changes
}

@Test func prepareFrameRunsOncePerStep() throws {
    let w = quietWorld()
    nonisolated(unsafe) var seen: [Int] = []
    w.prepareFrame = { seen.append($0) }
    try act(w, #"{"type":"advance","steps":4}"#)
    _ = w.state()
    #expect(seen == [1, 2, 3, 4])
}
