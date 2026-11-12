// AGENT HEADER - Tests/NeveCoreTests/ShaderLayoutTests.swift  (Swift GPU structs vs the MSL struct text)
// Covers: the `Occ` slot count (3 x OccluderLayout.slots rects + s + n), `Instance`, `Prim`, `PileSeg` (Render.swift) against the MSL struct definitions in `ShaderStructs` (NeveCore), the very strings the shader sources in Sources/Neve interpolate (the test target cannot see the Neve executable, hence the text lives in NeveCore).
//   The MSL text is parsed (float / uint = 4 B, float2 = 8 B, float4 = 16 B, each aligned to its size; struct size rounded up to its alignment) and compared with MemoryLayout size, stride, alignment and every field offset, in order.
// Related: Render.swift, ShaderStructs.swift, PolishATests (instanceLayoutMatchesTheShader), PileLogicTests (PileSeg stride).

import Foundation
import Testing
@testable import NeveCore

private struct MSLField { let name: String, offset: Int }

/// Parses `struct Name { type field; ... };` into (name, fields with offsets, size, alignment) with MSL packing rules.
private func parseMSL(_ text: String) -> (name: String, fields: [MSLField], size: Int, align: Int) {
    let parts = text.split(whereSeparator: { "{}".contains($0) }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    let name = parts[0].replacingOccurrences(of: "struct ", with: "")
    let sizes = ["float": 4, "uint": 4, "float2": 8, "float4": 16]
    var off = 0, align = 1, out: [MSLField] = []
    for decl in parts[1].split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where !decl.isEmpty {
        let w = decl.split(separator: " ").map(String.init)
        let sz = sizes[w[0]]!
        off = (off + sz - 1) / sz * sz
        out.append(MSLField(name: w[1], offset: off))
        off += sz; align = max(align, sz)
    }
    return (name, out, (off + align - 1) / align * align, align)
}

private func check<T>(_ text: String, _: T.Type, _ swift: [(String, Int?)]) {
    let m = parseMSL(text)
    #expect(m.size == MemoryLayout<T>.size && m.size == MemoryLayout<T>.stride, "\(m.name): MSL size \(m.size) vs Swift size \(MemoryLayout<T>.size) / stride \(MemoryLayout<T>.stride)")
    #expect(m.align == MemoryLayout<T>.alignment, "\(m.name): MSL alignment \(m.align) vs Swift \(MemoryLayout<T>.alignment)")
    #expect(m.fields.count == swift.count, "\(m.name): \(m.fields.count) MSL fields vs \(swift.count) Swift fields")
    for (f, s) in zip(m.fields, swift) {
        #expect(f.name == s.0, "\(m.name): field order / name \(f.name) vs \(s.0)")
        #expect(f.offset == s.1, "\(m.name).\(f.name): MSL offset \(f.offset) vs Swift \(String(describing: s.1))")
    }
}

@Test func instanceMatchesItsMSLStruct() {
    typealias T = Instance
    check(ShaderStructs.instance, T.self, [("pos", MemoryLayout<T>.offset(of: \T.pos)), ("size", MemoryLayout<T>.offset(of: \T.size)), ("alpha", MemoryLayout<T>.offset(of: \T.alpha)), ("seed", MemoryLayout<T>.offset(of: \T.seed)),
                                           ("rot", MemoryLayout<T>.offset(of: \T.rot)), ("kind", MemoryLayout<T>.offset(of: \T.kind)), ("vel", MemoryLayout<T>.offset(of: \T.vel))])
}

@Test func primMatchesItsMSLStruct() {
    typealias T = Prim
    check(ShaderStructs.prim, T.self, [("a", MemoryLayout<T>.offset(of: \T.a)), ("b", MemoryLayout<T>.offset(of: \T.b)), ("c", MemoryLayout<T>.offset(of: \T.c)), ("d", MemoryLayout<T>.offset(of: \T.d)),
                                       ("color", MemoryLayout<T>.offset(of: \T.color)), ("kind", MemoryLayout<T>.offset(of: \T.kind)), ("soft", MemoryLayout<T>.offset(of: \T.soft)), ("width", MemoryLayout<T>.offset(of: \T.width)),
                                       ("pad", MemoryLayout<T>.offset(of: \T._pad))])   // Swift's `_pad` is the MSL `pad`
}

@Test func pileSegMatchesItsMSLStruct() {
    typealias T = PileSeg
    check(ShaderStructs.pileSeg, T.self, [("x0", MemoryLayout<T>.offset(of: \T.x0)), ("x1", MemoryLayout<T>.offset(of: \T.x1)), ("top0", MemoryLayout<T>.offset(of: \T.top0)), ("top1", MemoryLayout<T>.offset(of: \T.top1)),
                                          ("base0", MemoryLayout<T>.offset(of: \T.base0)), ("base1", MemoryLayout<T>.offset(of: \T.base1)), ("slope", MemoryLayout<T>.offset(of: \T.slope)), ("dragged", MemoryLayout<T>.offset(of: \T.dragged)),
                                          ("n0", MemoryLayout<T>.offset(of: \T.n0)), ("n1", MemoryLayout<T>.offset(of: \T.n1)), ("inset", MemoryLayout<T>.offset(of: \T.inset)), ("z", MemoryLayout<T>.offset(of: \T.z))])
}

@Test func occBufferHoldsEveryOccluderSlot() {   // Overlay.occ = 3 groups of slots + s + n float4s; the MSL array must match
    let n = OccluderLayout.slots
    #expect(ShaderStructs.occ.contains("float4 r[\(3 * n)];") && ShaderStructs.occ.contains("float4 s;") && ShaderStructs.occ.contains("float4 n;"))
}
