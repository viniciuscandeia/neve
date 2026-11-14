// AGENT HEADER - Sources/NeveLab/main.swift
// Role: thin CLI over NeveLabKit. `NeveLab serve --id X [--seed N] [--size WxH] [--dir D] [--dock bottom|none] [--dock-icons N] [--appearance light|dark] [--replay-from DIR]` runs ONE session in this process (foreground; replies to stop and exits);
// `create` (same flags) spawns `serve` detached (log: <dir>/serve.out) and waits for the socket; `send --id X '<action json>'`, `state --id X`, `capture --id X [--dir D]`, `stop --id X`,
// `replay --from DIR --id NEW` (= create with --replay-from, seed/size/dock/appearance taken from the source config) talk to a session over its socket. Common: `--timeout SECS` (default 30; a timeout is never retried: check `state`).
// Output: the response JSON on stdout; exit 0 if ok, 1 on {"ok":false}, 2 on usage/connection errors. Session dir default build/lab/<id>/ (relative to cwd).
// World: `LabAdapter` (LabAdapter.swift: NeveLabCore world + NeveRender capture) behind NeveLabKit's `SessionWorld`.
import Foundation
import NeveLabKit

func die(_ m: String, _ code: Int32 = 2) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(code) }

func makeWorld(_ c: SessionConfig) -> SessionWorld { LabAdapter(config: c) }

var args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else { die("usage: NeveLab serve|create|send|state|capture|replay|stop ...") }
let cmd = args.removeFirst()
var opt: [String: String] = [:], pos: [String] = []
while !args.isEmpty {
    let a = args.removeFirst()
    if a.hasPrefix("--") { guard !args.isEmpty else { die("missing value for \(a)") }; opt[String(a.dropFirst(2))] = args.removeFirst() } else { pos.append(a) }
}

@MainActor func sessionConfig(id: String) throws -> SessionConfig {
    let size = (opt["size"] ?? "1280x800").split(separator: "x").compactMap { Int($0) }
    guard size.count == 2, size.allSatisfy({ $0 > 0 }) else { die("bad --size (WxH)") }
    guard let seed = UInt64(opt["seed"] ?? "1") else { die("bad --seed") }
    let dir = URL(fileURLWithPath: opt["dir"] ?? "build/lab/\(id)").standardizedFileURL.path
    let dock = opt["dock"] ?? "bottom", appearance = opt["appearance"] ?? "light"
    guard dock == "bottom" || dock == "none" else { die("bad --dock (bottom|none)") }
    guard appearance == "light" || appearance == "dark" else { die("bad --appearance (light|dark)") }
    guard let icons = Int(opt["dock-icons"] ?? "12"), (1...60).contains(icons) else { die("bad --dock-icons (1...60)") }
    return SessionConfig(id: id, seed: seed, width: size[0], height: size[1], dir: dir, socket: try LabPaths.socket(id: id), build: BuildIdentity.current(), replayedFrom: opt["replay-from"].map { URL(fileURLWithPath: $0).standardizedFileURL.path }, dock: dock, dockIcons: icons, appearance: appearance)
}

@MainActor func send(_ req: JSON) -> Never {
    guard let id = opt["id"] else { die("--id required") }
    do {
        let r = try LabClient.request(socket: try LabPaths.socket(id: id), req, timeout: Double(opt["timeout"] ?? "30") ?? 30)
        print(r.text); exit(r["ok"] == .bool(true) ? 0 : 1)
    } catch { die("\(error)") }
}

do {
    switch cmd {
    case "serve":
        guard let id = opt["id"] else { die("--id required") }
        let cfg = try sessionConfig(id: id)
        let session = try Session(config: cfg, world: makeWorld(cfg))
        if let from = cfg.replayedFrom { try session.replay(historyOf: URL(fileURLWithPath: from)) }
        let server = LabServer(session: session)
        try server.start()
        server.wait()
    case "create", "replay":
        guard let id = opt["id"] else { die("--id required") }
        if cmd == "replay" {
            guard let from = opt["from"] else { die("--from DIR required") }
            let src = try LabConfigFile.read(dir: from)
            opt["replay-from"] = from; opt["seed"] = String(src.seed); opt["size"] = "\(src.width)x\(src.height)"
            opt["dock"] = src.dock; opt["dock-icons"] = String(src.dockIcons); opt["appearance"] = src.appearance
        }
        let cfg = try sessionConfig(id: id)
        try FileManager.default.createDirectory(atPath: cfg.dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var a = ["serve", "--id", id, "--seed", String(cfg.seed), "--size", "\(cfg.width)x\(cfg.height)", "--dir", cfg.dir, "--dock", cfg.dock, "--dock-icons", String(cfg.dockIcons), "--appearance", cfg.appearance]
        if let r = cfg.replayedFrom { a += ["--replay-from", r] }
        p.arguments = a
        let outPath = cfg.dir + "/serve.out"
        FileManager.default.createFile(atPath: outPath, contents: nil)
        let out = FileHandle(forWritingAtPath: outPath)
        p.standardOutput = out ?? FileHandle.nullDevice; p.standardError = out ?? FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        try p.run()
        for _ in 0..<200 {
            if let r = try? LabClient.request(socket: cfg.socket, .object(["cmd": .string("ping")]), timeout: 2), r["ok"] == .bool(true) {
                print(JSON.object(["ok": .bool(true), "result": .object(["id": .string(id), "dir": .string(cfg.dir), "socket": .string(cfg.socket), "pid": .number(Double(p.processIdentifier))])]).text); exit(0)
            }
            if !p.isRunning { die("session exited during startup (see \(outPath))") }
            Thread.sleep(forTimeInterval: 0.05)
        }
        die("timed out waiting for the session socket (pid \(p.processIdentifier) left running; see \(outPath))")
    case "send":
        guard let a = pos.first, let j = try? JSON.parse(a) else { die("send needs one JSON action argument") }
        send(.object(["cmd": .string("send"), "action": j]))
    case "state": send(.object(["cmd": .string("state")]))
    case "capture":
        var r: [String: JSON] = ["cmd": .string("capture")]
        if let d = opt["dir"] { r["dir"] = .string(URL(fileURLWithPath: d).standardizedFileURL.path) }
        send(.object(r))
    case "stop": send(.object(["cmd": .string("stop")]))
    default: die("unknown command \(cmd)")
    }
} catch { die("\(error)") }
