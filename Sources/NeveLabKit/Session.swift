// AGENT HEADER - Sources/NeveLabKit/Session.swift
// Role: one Neve Lab session = a LabWorld + its directory + a Unix-socket server. `Session.handle(request)` is the whole protocol (pure, testable); `LabServer` just frames lines to it.
// Protocol (one JSON object per line each way): requests {"cmd":"ping"|"state"|"stop"} | {"cmd":"send","action":{...}} | {"cmd":"capture","dir":"optional"}; responses {"ok":true,"result":{...}} or {"ok":false,"error":"msg"}.
// Ordering: every request executes under one lock in arrival order; an invalid request (bad cmd/JSON, or world.apply throwing) returns an error and leaves the world and history untouched.
// Files in the session dir: config.json (effective config + build identity), history.jsonl ({"seq":n,"action":{...}} per ACCEPTED send, appended after apply succeeds), lab.log, captures/. capture and state are not recorded.
// Replay: `Session.replay(historyOf:)` re-applies a previous history through the new world (and so records it in the new history). Stop: replies, then `wait()` returns; files stay.
import Foundation
import Darwin

public final class Session: @unchecked Sendable {
    public let config: LabConfig
    let world: LabWorld
    let dir: URL
    private let lock = NSLock()
    private var seq = 0
    public private(set) var stopRequested = false

    public init(config: LabConfig, world: LabWorld) throws {
        self.config = config; self.world = world; dir = URL(fileURLWithPath: config.dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("captures"), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        try e.encode(config).write(to: dir.appendingPathComponent("config.json"))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("history.jsonl").path, contents: nil)
    }

    public static func ok(_ r: JSON = .object([:])) -> JSON { .object(["ok": .bool(true), "result": r]) }
    public static func fail(_ m: String) -> JSON { .object(["ok": .bool(false), "error": .string(m)]) }

    public func log(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: dir.appendingPathComponent("lab.log")) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: dir.appendingPathComponent("lab.log")) }
    }

    private func appendHistory(_ action: JSON) throws {
        let line = JSON.object(["seq": .number(Double(seq + 1)), "action": action]).data() + Data([10])
        let h = try FileHandle(forWritingTo: dir.appendingPathComponent("history.jsonl"))
        defer { try? h.close() }
        h.seekToEndOfFile(); h.write(line)
        seq += 1
    }

    public func handle(_ req: JSON) -> JSON {
        lock.lock(); defer { lock.unlock() }
        do {
            switch req["cmd"]?.string {
            case "ping": return Session.ok()
            case "state": return Session.ok(world.state())
            case "stop": stopRequested = true; log("stop"); return Session.ok()
            case "send":
                guard let action = req["action"], case .object = action else { throw LabError.invalid("send needs an object \"action\"") }
                let r = try world.apply(action)
                try appendHistory(action)
                return Session.ok(r)
            case "capture":
                let d = req["dir"]?.string.map { URL(fileURLWithPath: $0) } ?? dir.appendingPathComponent("captures")
                try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                let name = String(format: "capture-%04d", seq)   // seq = actions accepted so far; recapturing without advancing overwrites the same files
                var r = try world.capture(dir: d, name: name)
                if case .object(var o) = r { o["config"] = (try? JSON.parse(JSONEncoder().encode(config))) ?? .null; o["seq"] = .number(Double(seq)); r = .object(o) }
                return Session.ok(r)
            default: throw LabError.invalid("unknown cmd")
            }
        } catch {
            log("error: \(error)")
            return Session.fail("\(error)")
        }
    }

    /// Re-apply the actions of another session's history.jsonl, in order. Stops at the first failure.
    public func replay(historyOf source: URL) throws {
        let text = try String(contentsOf: source.appendingPathComponent("history.jsonl"), encoding: .utf8)
        for l in text.split(separator: "\n") {
            guard let a = try JSON.parse(String(l))["action"] else { throw LabError.invalid("bad history line") }
            let r = handle(.object(["cmd": .string("send"), "action": a]))
            if r["ok"] != .bool(true) { throw LabError.invalid("replay failed: \(r["error"]?.string ?? "?")") }
        }
    }
}

public final class LabServer: @unchecked Sendable {
    public let session: Session
    let path: String
    var listenFD: Int32 = -1
    private let done = DispatchSemaphore(value: 0)

    public init(session: Session) { self.session = session; path = session.config.socket }

    public func start() throws {
        signal(SIGPIPE, SIG_IGN)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let fd = try? LabClient.connect(socket: path) { close(fd); throw LabError.invalid("socket already in use: \(path)") }
        unlink(path)   // stale socket from a crashed session
        let fd = try makeSocket(); var a = try sockAddr(path)
        let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard r == 0, listen(fd, 16) == 0 else { let e = String(cString: strerror(errno)); close(fd); throw LabError.io("bind/listen \(path): \(e)") }
        listenFD = fd
        session.log("listening \(path)")
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { if errno == EINTR { continue }; break }
                Thread.detachNewThread { [self] in serve(c) }
            }
        }
    }

    func serve(_ fd: Int32) {
        defer { close(fd) }
        let rd = LineReader(fd: fd)
        while let line = try? rd.readLine() {
            let resp: JSON
            do { resp = session.handle(try JSON.parse(line)) } catch { resp = Session.fail("bad JSON: \(error)") }
            try? writeLine(fd, resp.data())
            if session.stopRequested { stop(); return }
        }
    }

    public func stop() { if listenFD >= 0 { close(listenFD); listenFD = -1; unlink(path); done.signal() } }
    /// Blocks until a `stop` command (or `stop()`).
    public func wait() { done.wait() }
}
