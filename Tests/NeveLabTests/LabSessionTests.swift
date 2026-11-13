// AGENT HEADER - Tests/NeveLabTests/LabSessionTests.swift
// Role: tests of the Neve Lab process/protocol layer against StubWorld: line framing round-trip over a socketpair, ordered execution (also across concurrent connections), invalid commands leave world and
// history unchanged, history.jsonl written and replayed into a fresh session, capture idempotence, and two sessions in parallel (in-process servers on two sockets) sharing no files or sockets (the built binary now runs the real world: see LabRealWorldTests.swift). Uses short ids under $TMPDIR/neve-lab and a per-test temp dir.
import Foundation
import Testing
@testable import NeveLabKit

private func tmpDir() -> String { NSTemporaryDirectory() + "nl-\(UUID().uuidString.prefix(8))" }

private func makeServer(_ id: String) throws -> (LabServer, SessionConfig) {
    let c = SessionConfig(id: id, seed: 1, width: 1280, height: 800, dir: tmpDir(), socket: try LabPaths.socket(id: id))
    let s = LabServer(session: try Session(config: c, world: StubWorld(config: c)))
    try s.start()
    return (s, c)
}
private func add(_ n: Double) -> JSON { .object(["cmd": .string("send"), "action": .object(["op": .string("add"), "n": .number(n)])]) }
private func req(_ c: SessionConfig, _ r: JSON) throws -> JSON { try LabClient.request(socket: c.socket, r, timeout: 5) }
private func ids() -> String { String(UUID().uuidString.prefix(8)) }

@Suite struct LabSessionTests {
    @Test func framingRoundTrip() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let big = JSON.object(["s": .string(String(repeating: "x", count: 200_000)), "n": .array([.number(1), .null, .bool(true)])])
        let w = fds[0]   // 200 KB exceeds the socket buffer, so the writer must not be the reading thread
        Thread.detachNewThread { try? writeLine(w, big.data()); try? writeLine(w, JSON.string("two").data()); close(w) }
        let rd = LineReader(fd: fds[1])
        #expect(try JSON.parse(try #require(try rd.readLine())) == big)
        #expect(try JSON.parse(try #require(try rd.readLine())) == .string("two"))
        #expect(try rd.readLine() == nil)
        close(fds[1])
    }

    @Test func orderedExecutionAndInvalidCommandsChangeNothing() throws {
        let (s, c) = try makeServer("ord" + ids()); defer { s.stop() }
        // concurrent connections are serialised; in-order on one connection
        for i in 1...5 { #expect(try req(c, add(Double(i)))["ok"] == .bool(true)) }
        #expect(try req(c, .object(["cmd": .string("state")]))["result"]?["total"] == .number(15))
        let before = try req(c, .object(["cmd": .string("state")]))
        let hist = try String(contentsOfFile: c.dir + "/history.jsonl", encoding: .utf8)
        for bad: JSON in [.object(["cmd": .string("nope")]), .object(["cmd": .string("send")]), .object(["cmd": .string("send"), "action": .string("x")]),
                          .object(["cmd": .string("send"), "action": .object(["op": .string("zap")])]), .object(["cmd": .string("send"), "action": .object(["op": .string("add")])])] {
            let r = try req(c, bad)
            #expect(r["ok"] == .bool(false)); #expect(r["error"]?.string != nil)
        }
        #expect(try req(c, .object(["cmd": .string("state")])) == before)
        #expect(try String(contentsOfFile: c.dir + "/history.jsonl", encoding: .utf8) == hist)
        // malformed JSON line gets an error response, not a dropped connection
        let fd = try LabClient.connect(socket: c.socket); defer { close(fd) }
        try writeLine(fd, Data("{oops".utf8))
        #expect(try JSON.parse(try #require(try LineReader(fd: fd).readLine()))["ok"] == .bool(false))
    }

    @Test func concurrentClientsSerialised() throws {
        let (s, c) = try makeServer("con" + ids()); defer { s.stop() }
        DispatchQueue.concurrentPerform(iterations: 20) { _ in _ = try? req(c, add(1)) }
        #expect(try req(c, .object(["cmd": .string("state")]))["result"]?["actions"] == .number(20))
        let lines = try String(contentsOfFile: c.dir + "/history.jsonl", encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 20)
        #expect(try lines.map { try JSON.parse(String($0))["seq"]?.number } == (1...20).map { Double($0) })
    }

    @Test func historyReplayedInFreshSession() throws {
        let (s, c) = try makeServer("rpa" + ids()); defer { s.stop() }
        for n in [3.0, 4, 5] { _ = try req(c, add(n)) }
        _ = try req(c, .object(["cmd": .string("send"), "action": .object(["op": .string("zap")])]))
        let cfg = try LabConfigFile.read(dir: c.dir)
        #expect(cfg == c)
        var c2 = c; c2.id = "rpb" + ids(); c2.dir = tmpDir(); c2.socket = try LabPaths.socket(id: c2.id); c2.replayedFrom = c.dir
        let s2 = try Session(config: c2, world: StubWorld(config: c2))
        try s2.replay(historyOf: URL(fileURLWithPath: c.dir))
        #expect(s2.handle(.object(["cmd": .string("state")])) == Session.ok(try #require(try req(c, .object(["cmd": .string("state")]))["result"])))
        #expect(try String(contentsOfFile: c2.dir + "/history.jsonl", encoding: .utf8) == String(contentsOfFile: c.dir + "/history.jsonl", encoding: .utf8))
    }

    @Test func captureIsRepeatableAndNotRecorded() throws {
        let (s, c) = try makeServer("cap" + ids()); defer { s.stop() }
        _ = try req(c, add(2))
        let a = try req(c, .object(["cmd": .string("capture")])), b = try req(c, .object(["cmd": .string("capture")]))
        #expect(a == b); #expect(a["result"]?["seq"] == .number(1)); #expect(a["result"]?["config"]?["id"]?.string == c.id)
        #expect(try String(contentsOfFile: c.dir + "/history.jsonl", encoding: .utf8).split(separator: "\n").count == 1)
    }

    @Test func stopEndsOnlyThatSession() throws {
        let (a, ca) = try makeServer("sa" + ids()), (b, cb) = try makeServer("sb" + ids()); defer { a.stop(); b.stop() }
        _ = try req(ca, add(1)); _ = try req(cb, add(2))
        #expect(try req(ca, .object(["cmd": .string("stop")]))["ok"] == .bool(true))
        a.wait()
        #expect((try? req(ca, .object(["cmd": .string("ping")]))) == nil)
        #expect(!FileManager.default.fileExists(atPath: ca.socket))
        #expect(FileManager.default.fileExists(atPath: ca.dir + "/history.jsonl"))   // evidence preserved
        #expect(try req(cb, .object(["cmd": .string("state")]))["result"]?["total"] == .number(2))
    }

    @Test func twoSessionsInParallelShareNothing() throws {
        let (a, ca) = try makeServer("pa" + ids()), (b, cb) = try makeServer("pb" + ids()); defer { a.stop(); b.stop() }
        #expect(ca.socket != cb.socket); #expect(ca.dir != cb.dir)
        DispatchQueue.concurrentPerform(iterations: 2) { i in for _ in 0..<25 { _ = try? req(i == 0 ? ca : cb, add(i == 0 ? 1 : 10)) } }
        #expect(try req(ca, .object(["cmd": .string("state")]))["result"]?["total"] == .number(25))
        #expect(try req(cb, .object(["cmd": .string("state")]))["result"]?["total"] == .number(250))
    }
}
