// AGENT HEADER - Sources/NeveLabKit/JSON.swift
// Role: minimal Sendable/Codable/Equatable JSON value used by every Neve Lab message (requests, responses, actions, history lines). No dependencies beyond Foundation.
// Output is compact, single-line, sorted keys (deterministic; one JSON value per line is the wire/history framing). Numbers are Double.
import Foundation

public enum JSON: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSON]), object([String: JSON])

    public init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }
    public func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public subscript(key: String) -> JSON? { if case .object(let o) = self { return o[key] }; return nil }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var number: Double? { if case .number(let n) = self { return n }; return nil }

    public func data() -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(self)) ?? Data("null".utf8)
    }
    public static func parse(_ d: Data) throws -> JSON { try JSONDecoder().decode(JSON.self, from: d) }
    public static func parse(_ s: String) throws -> JSON { try parse(Data(s.utf8)) }
    public var text: String { String(decoding: data(), as: UTF8.self) }
}
