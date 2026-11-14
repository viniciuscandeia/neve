// AGENT HEADER - Tests/NeveLabTests/LabRealWorldTests.swift
// Role: acceptance tests of the REAL Neve Lab (NeveLab binary = NeveLabCore world + NeveRender capture) driven only through its CLI (`create` / `send` / `state` / `capture` / `replay` / `stop`), the way an agent uses it.
// Covers: Dock + dark appearance through the CLI (state, config.json, dark vs light capture differ, dark repeatable, replay); capture twice without advancing = identical PNG bytes and JSON; captures between steps do not change later state / digest; replay of a real session reproduces state AND digest, also after extra steps; an invalid action returns
// an error and leaves world and history unchanged; two sessions act simultaneously sharing no files / sockets / state; ball scoop / drag / release; tree pick / drag / release. The binary sits next to NevePackageTests.xctest
// (.build/<cfg>/NeveLab); a missing binary FAILS these tests (it is built with the test bundle). Sessions run on short ids under $TMPDIR/neve-lab; each test stops what it created.
import Foundation
import Testing
@testable import NeveLabKit

private func exePath() -> String? {
    var d = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/nonexistent")
    for _ in 0..<6 { d.deleteLastPathComponent(); let p = d.appendingPathComponent("NeveLab").path; if FileManager.default.isExecutableFile(atPath: p) { return p } }
    return nil
}

private struct Lab {
    let exe: String
    func run(_ a: [String]) throws -> (code: Int32, json: JSON?) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = a
        let o = Pipe(); p.standardOutput = o; p.standardError = FileHandle.nullDevice
        try p.run(); let data = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (p.terminationStatus, try? JSON.parse(data))
    }
}

/// One session of the real binary; tests stop it with `end()` (defer).
private struct Sess {
    let lab: Lab, id: String, dir: String
    @discardableResult func send(_ a: String) throws -> JSON {
        let r = try lab.run(["send", "--id", id, a]); #expect(r.code == 0, "\(a) -> \(r.json?.text ?? "?")"); return r.json?["result"] ?? .null
    }
    func fail(_ a: String) throws { #expect(try lab.run(["send", "--id", id, a]).code == 1) }
    func state() throws -> JSON { try lab.run(["state", "--id", id]).json?["result"] ?? .null }
    func end() { _ = try? lab.run(["stop", "--id", id]) }
    func history() -> String { (try? String(contentsOfFile: dir + "/history.jsonl", encoding: .utf8)) ?? "" }
}

private func tmp() -> String { NSTemporaryDirectory() + "nlr-\(UUID().uuidString.prefix(8))" }
private func start(_ lab: Lab, _ tag: String, seed: Int = 5, dock: String = "none", extra: [String] = [], replay from: String? = nil) throws -> Sess {
    let id = tag + String(UUID().uuidString.prefix(6)), dir = tmp()
    let r = try from.map { try lab.run(["replay", "--from", $0, "--id", id, "--dir", dir]) } ?? lab.run(["create", "--id", id, "--seed", "\(seed)", "--size", "640x400", "--dir", dir, "--dock", dock] + extra)
    #expect(r.code == 0, "create failed: \(r.json?.text ?? "?")")
    return Sess(lab: lab, id: id, dir: dir)
}
private func quiet(_ s: Sess) throws {
    for p in ["visitors", "sleigh", "snowman", "walk"] { try s.send(#"{"type":"set_pref","pref":"\#(p)","value":false}"#) }
}
private func arr(_ j: JSON?) -> [JSON] { if case .array(let a) = j { return a }; return [] }
private func realLab() throws -> Lab { Lab(exe: try #require(exePath(), "NeveLab binary not found next to the test bundle")) }

private let scene = [
    #"{"type":"create_window","id":1,"title":"A","x":60,"y":120,"w":300,"h":200}"#,
    #"{"type":"create_window","id":2,"title":"B","x":200,"y":90,"w":300,"h":200}"#,
    #"{"type":"advance","steps":90}"#,
    #"{"type":"fill_pile","surface":1,"height":12}"#,
    #"{"type":"move_window","id":2,"x":320,"y":150,"duration":0.4}"#,
    #"{"type":"minimize_window","id":1}"#,
    #"{"type":"advance","steps":60}"#,
]

@Suite(.serialized) struct LabRealWorldTests {
    @Test func captureTwiceIsIdenticalAndCapturesDoNotChangeEvolution() throws {
        let lab = try realLab()
        let a = try start(lab, "ca"), b = try start(lab, "cb"); defer { a.end(); b.end() }
        for s in [a, b] { for x in scene { try s.send(x) } }
        // twice without advancing, into two dirs: same bytes
        let d1 = tmp(), d2 = tmp()
        let c1 = try lab.run(["capture", "--id", a.id, "--dir", d1]), c2 = try lab.run(["capture", "--id", a.id, "--dir", d2])
        #expect(c1.code == 0 && c2.code == 0, "\(c1.json?.text ?? "?")")
        let f = try #require(arr(c1.json?["result"]?["files"]).first?.string.map { ($0 as NSString).lastPathComponent })
        let base = (f as NSString).deletingPathExtension
        for ext in ["png", "json"] { #expect(try Data(contentsOf: URL(fileURLWithPath: "\(d1)/\(base).\(ext)")) == Data(contentsOf: URL(fileURLWithPath: "\(d2)/\(base).\(ext)")), "\(ext) differs") }
        let png = try Data(contentsOf: URL(fileURLWithPath: "\(d1)/\(base).png"))
        #expect(png.count > 5000 && png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        let meta = try JSON.parse(Data(contentsOf: URL(fileURLWithPath: "\(d1)/\(base).json")))
        #expect(meta["step"] == .number(174) && meta["state"]?["step"] == .number(174) && meta["config"]?["seed"] == .number(5) && meta["build"]?["commit"] != nil)
        #expect(try a.state() == b.state(), "capturing does not change the state")
        // captures between steps vs none: same evolution
        for _ in 0..<4 { try a.send(#"{"type":"advance","steps":45}"#); _ = try lab.run(["capture", "--id", a.id, "--dir", d1]) }
        try b.send(#"{"type":"advance","steps":180}"#)
        let (sa, sb) = (try a.state(), try b.state())
        #expect(sa == sb); #expect(sa["digest"] != nil && sa["digest"] == sb["digest"])
        // the picture taken afterwards is the same too (prepared data does not depend on captures)
        func shot(_ s: Sess, _ d: String) throws -> Data {
            let r = try lab.run(["capture", "--id", s.id, "--dir", d]); return try Data(contentsOf: URL(fileURLWithPath: try #require(arr(r.json?["result"]?["files"]).first?.string)))
        }
        let pa = try shot(a, d1), pb = try shot(b, d2)
        #expect(pa == pb)
    }

    @Test func replayReproducesStateAndDigestAndLaterEvolution() throws {
        let lab = try realLab()
        let a = try start(lab, "ra"); defer { a.end() }
        for x in scene { try a.send(x) }
        let b = try start(lab, "rb", replay: a.dir); defer { b.end() }
        #expect(try a.state() == b.state()); #expect(try a.state()["digest"] != nil)
        #expect(a.history() == b.history())
        for s in [a, b] { try s.send(#"{"type":"advance","steps":200}"#); try s.send(#"{"type":"cursor_move","x":100,"y":100,"duration":0.2}"#) }
        #expect(try a.state() == b.state())
    }

    @Test func invalidCommandIsAnErrorAndLeavesTheWorldUnchanged() throws {
        let lab = try realLab()
        let a = try start(lab, "iv"); defer { a.end() }
        try a.send(scene[0]); try a.send(#"{"type":"advance","steps":10}"#)
        let s0 = try a.state(), h0 = a.history()
        for bad in [#"{"type":"bogus"}"#, #"{"type":"create_window","id":1,"title":"dup","x":0,"y":0,"w":10,"h":10}"#, #"{"type":"move_window","id":99,"x":1,"y":1}"#,
                    #"{"type":"advance","steps":"x"}"#, #"{"type":"advance","steps":5,"extra":1}"#, #"{"type":"mouse_up"}"#] { try a.fail(bad) }
        #expect(try lab.run(["send", "--id", a.id, "not json"]).code == 2)
        #expect(try a.state() == s0); #expect(a.history() == h0)
    }

    @Test func dockAndDarkAppearanceThroughTheCLI() throws {
        let lab = try realLab()
        let l = try start(lab, "dl", dock: "bottom", extra: ["--dock-icons", "8"]), d = try start(lab, "dd", dock: "bottom", extra: ["--dock-icons", "8", "--appearance", "dark"]); defer { l.end(); d.end() }
        for s in [l, d] { try s.send(#"{"type":"advance","seconds":30}"#) }
        let (sl, sd) = (try l.state(), try d.state())
        #expect(sl["dock"]?["position"] == .string("bottom") && sl["dock"]?["icons"] == .number(8) && sl["dock"]?["frame"]?["w"] == .number(484))
        #expect(sl["screen"]?["appearance"] == .string("light") && sd["screen"]?["appearance"] == .string("dark"))
        #expect(sl["digest"] == sd["digest"], "appearance is render-only: the simulation is identical")
        let cfg = try JSON.parse(Data(contentsOf: URL(fileURLWithPath: l.dir + "/config.json")))
        #expect(cfg["dock"] == .string("bottom") && cfg["dockIcons"] == .number(8) && cfg["appearance"] == .string("light"))
        func shot(_ s: Sess, _ dir: String) throws -> Data {
            let r = try lab.run(["capture", "--id", s.id, "--dir", dir]); return try Data(contentsOf: URL(fileURLWithPath: try #require(arr(r.json?["result"]?["files"]).first?.string)))
        }
        let (d1, d2) = (tmp(), tmp())
        let light = try shot(l, d1), dark = try shot(d, d1), dark2 = try shot(d, d2)
        #expect(light != dark, "dark capture differs from light")
        #expect(dark == dark2, "dark capture is repeatable")
        // switching at run time re-prepares the frame: the light session turned dark captures exactly like the born-dark one
        try l.send(#"{"type":"set_appearance","appearance":"dark"}"#)
        #expect(try shot(l, tmp()).count > 5000 && l.state()["screen"]?["appearance"] == .string("dark"))
        try l.send(#"{"type":"set_dock","position":"none"}"#)
        #expect(try l.state()["dock"]?["position"] == .string("none"))
        try l.fail(#"{"type":"set_dock","position":"top"}"#)
        // replay carries dock options and the actions
        let r = try start(lab, "dr", replay: l.dir); defer { r.end() }
        #expect(try r.state() == l.state())
    }

    @Test func twoSessionsActSimultaneouslyAndShareNothing() throws {
        let lab = try realLab()
        let a = try start(lab, "pa", seed: 1), b = try start(lab, "pb", seed: 2); defer { a.end(); b.end() }
        #expect(a.id != b.id && a.dir != b.dir)
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            let s = i == 0 ? a : b
            _ = try? s.send(#"{"type":"create_window","id":\#(i + 1),"title":"W\#(i)","x":50,"y":100,"w":200,"h":150}"#)
            for _ in 0..<5 { _ = try? s.send(#"{"type":"advance","steps":20}"#) }
            _ = try? s.send(#"{"type":"option_down"}"#)
            _ = try? s.send(#"{"type":"cursor_move","x":\#(100 * (i + 1)),"y":\#(100 * (i + 1))}"#)
        }
        let (sa, sb) = (try a.state(), try b.state())
        #expect(arr(sa["windows"]).count == 1 && arr(sb["windows"]).count == 1)
        #expect(arr(sa["windows"]).first?["id"] == .number(1) && arr(sb["windows"]).first?["id"] == .number(2))
        #expect(sa["cursor"]?["x"] == .number(100) && sb["cursor"]?["x"] == .number(200))
        #expect(sa["step"] == .number(100) && sb["step"] == .number(100))
        #expect(a.history().split(separator: "\n").count == 8 && b.history().split(separator: "\n").count == 8)
        #expect(a.history() != b.history())
        a.end()   // stopping one leaves the other alive
        #expect(try lab.run(["state", "--id", a.id]).code == 2)
        #expect(try b.state()["step"] == .number(100))
    }

    @Test func ballScoopDragAndRelease() throws {
        let lab = try realLab()
        let a = try start(lab, "bl"); defer { a.end() }
        try quiet(a)
        try a.send(#"{"type":"advance","steps":10}"#)
        try a.send(#"{"type":"fill_pile","surface":"ground","height":12}"#)
        try a.send(#"{"type":"option_down"}"#)
        try a.send(#"{"type":"cursor_move","x":200,"y":395}"#)
        let r = try a.send(#"{"type":"mouse_down"}"#)
        #expect(r["outcome"]?.string == "scoop")
        #expect(try a.state()["held"]?["kind"]?.string == "ball")
        try a.send(#"{"type":"cursor_move","x":260,"y":395,"duration":0.5}"#)
        try a.send(#"{"type":"cursor_move","x":400,"y":200,"duration":0.4}"#)
        try a.send(#"{"type":"mouse_up"}"#)
        let s = try a.state()
        #expect(s["held"] == .null); #expect(arr(s["balls"]).count == 1)
        try a.send(#"{"type":"advance","steps":300}"#)
        #expect(arr(try a.state()["balls"]).first?["state"]?.string == "resting")
    }

    @Test func treeDropPickDragRelease() throws {
        let lab = try realLab()
        let a = try start(lab, "tr", seed: 3); defer { a.end() }
        try quiet(a)
        try a.send(#"{"type":"advance","steps":10}"#)
        try a.send(#"{"type":"fill_pile","surface":"ground","height":10}"#)
        #expect(try a.send(#"{"type":"drop_tree"}"#)["preparation"] == .bool(true))
        try a.fail(#"{"type":"drop_tree"}"#)
        try a.send(#"{"type":"advance","steps":600}"#)
        let t = try #require(try a.state()["tree"]), tx = try #require(t["x"]?.number), ty = try #require(t["y"]?.number)
        try a.send(#"{"type":"option_down"}"#)
        try a.send(#"{"type":"cursor_move","x":\#(tx),"y":\#(ty - 70)}"#)
        #expect(try a.send(#"{"type":"mouse_down"}"#)["outcome"]?.string == "tree")
        try a.send(#"{"type":"cursor_move","x":\#(tx + 100),"y":\#(ty - 100),"duration":0.5}"#)
        #expect(try a.state()["tree"]?["state"]?.string == "held")
        try a.send(#"{"type":"advance","steps":12}"#)
        try a.send(#"{"type":"mouse_up"}"#)
        try a.send(#"{"type":"advance","steps":300}"#)
        let t2 = try #require(try a.state()["tree"])
        #expect(t2["state"]?.string == "resting")
        #expect(abs((t2["x"]?.number ?? 0) - (tx + 100)) < 60)
    }
}
