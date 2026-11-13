// AGENT HEADER - Sources/NeveLabCore/LabJSON.swift  (strict JSON argument reader + canonical serializer for the lab's apply()/state())
// Role: `LabError` (invalid action: the world is left untouched), `Args` (typed, strict access to one action object: wrong type / missing key / non-finite number / unknown key => LabError; Bool is never accepted as a number) and `canonicalJSON` (sorted keys, so equal worlds serialize to equal strings).
// Used by: LabWorld.swift. No state here.

import Foundation

public struct LabError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public init(_ m: String) { message = m }
    public var description: String { message }
}

struct Args {
    let d: [String: Any]
    let type: String

    init(json: String, allowed: [String: Set<String>]) throws {
        guard let data = json.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data), let d = obj as? [String: Any] else { throw LabError("action must be a JSON object") }
        guard let t = d["type"] as? String else { throw LabError("missing string \"type\"") }
        guard let keys = allowed[t] else { throw LabError("unknown action type \"\(t)\"") }
        if let bad = d.keys.filter({ $0 != "type" && !keys.contains($0) }).sorted().first { throw LabError("unknown key \"\(bad)\" for \"\(t)\"") }
        self.d = d; type = t
    }

    private func isBool(_ v: Any) -> Bool { CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() }
    func has(_ k: String) -> Bool { d[k] != nil }
    func double(_ k: String) throws -> Double {
        guard let v = d[k] else { throw LabError("missing \"\(k)\"") }
        guard !isBool(v), let n = v as? Double, n.isFinite, abs(n) <= 1e6 else { throw LabError("\"\(k)\" must be a finite number") }
        return n
    }
    func optDouble(_ k: String) throws -> Double? { has(k) ? try double(k) : nil }
    func int(_ k: String) throws -> Int {
        let n = try double(k)
        guard n == n.rounded() else { throw LabError("\"\(k)\" must be an integer") }
        return Int(n)
    }
    func string(_ k: String) throws -> String {
        guard let s = d[k] as? String else { throw LabError("\"\(k)\" must be a string") }
        return s
    }
    func bool(_ k: String, or def: Bool) throws -> Bool {
        guard let v = d[k] else { return def }
        guard isBool(v), let b = v as? Bool else { throw LabError("\"\(k)\" must be true or false") }
        return b
    }
}

func canonicalJSON(_ o: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), let s = String(data: data, encoding: .utf8) else { return "{}" }
    return s
}
