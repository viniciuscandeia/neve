// AGENT HEADER - Sources/NeveLabKit/SessionWorld.swift
// Role: the seam between the session layer (this target: process, socket, history, replay) and the simulated world (NeveLabCore, built elsewhere) and its renderer.
// `SessionWorld` is what a session talks to; the session serialises all calls (never concurrent), so implementations need no locking. `StubWorld` is the placeholder used by tests and by the
// `NeveLab` executable until the real world exists: it keeps a counter and a log of accepted actions so ordering, rollback-on-error and replay are observable.
// Contract: `apply` must throw BEFORE mutating anything on invalid input (world unchanged); `state` is read-only; `capture` must not advance the simulation and writes its files into `dir`
// using `name` as base file name (e.g. name.png + name.json), returning a JSON description of what it wrote.
import Foundation

public enum SessionError: Error, CustomStringConvertible, Equatable {
    case invalid(String), timeout, io(String)
    public var description: String {
        switch self { case .invalid(let s): return s; case .timeout: return "timeout"; case .io(let s): return s }
    }
}

/// Effective session configuration (also written to config.json; dock / appearance are the START values, later set_dock / set_appearance actions live in history.jsonl).
public struct SessionConfig: Codable, Equatable, Sendable {
    public var id: String
    public var seed: UInt64
    public var width: Int
    public var height: Int
    public var dir: String
    public var socket: String
    public var build: [String: String]
    public var replayedFrom: String?
    public var dock: String          // "bottom" (floating bar, default like a real Mac) | "none"
    public var dockIcons: Int        // icon count: sets the bar width
    public var appearance: String    // "light" | "dark" at start
    public init(id: String, seed: UInt64, width: Int, height: Int, dir: String, socket: String, build: [String: String] = [:], replayedFrom: String? = nil, dock: String = "bottom", dockIcons: Int = 12, appearance: String = "light") {
        self.id = id; self.seed = seed; self.width = width; self.height = height; self.dir = dir; self.socket = socket; self.build = build; self.replayedFrom = replayedFrom
        self.dock = dock; self.dockIcons = dockIcons; self.appearance = appearance
    }
    /// Older config.json files (before dock / appearance) decode with the defaults.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), seed: try c.decode(UInt64.self, forKey: .seed), width: try c.decode(Int.self, forKey: .width), height: try c.decode(Int.self, forKey: .height),
                  dir: try c.decode(String.self, forKey: .dir), socket: try c.decode(String.self, forKey: .socket), build: try c.decode([String: String].self, forKey: .build),
                  replayedFrom: try c.decodeIfPresent(String.self, forKey: .replayedFrom), dock: try c.decodeIfPresent(String.self, forKey: .dock) ?? "bottom",
                  dockIcons: try c.decodeIfPresent(Int.self, forKey: .dockIcons) ?? 12, appearance: try c.decodeIfPresent(String.self, forKey: .appearance) ?? "light")
    }
}

public protocol SessionWorld: AnyObject, Sendable {
    func apply(_ action: JSON) throws -> JSON
    func state() -> JSON
    func capture(dir: URL, name: String) throws -> JSON
}

/// Placeholder world. Actions: {"op":"add","n":<number>} adds to the counter; {"op":"noop"}; anything else throws.
public final class StubWorld: SessionWorld, @unchecked Sendable {
    private var total = 0.0
    private var log: [JSON] = []
    public init(config: SessionConfig) {}
    public func apply(_ action: JSON) throws -> JSON {
        switch action["op"]?.string {
        case "add":
            guard let n = action["n"]?.number else { throw SessionError.invalid("add needs numeric n") }
            total += n
        case "noop": break
        default: throw SessionError.invalid("unknown op")
        }
        log.append(action)
        return .object(["total": .number(total)])
    }
    public func state() -> JSON { .object(["total": .number(total), "actions": .number(Double(log.count)), "log": .array(log)]) }
    public func capture(dir: URL, name: String) throws -> JSON {
        let f = dir.appendingPathComponent(name + ".json")
        try state().data().write(to: f)
        return .object(["files": .array([.string(f.path)])])
    }
}
