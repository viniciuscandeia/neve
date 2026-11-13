// AGENT HEADER - Tests/NeveCoreTests/LocalizationTests.swift  (every tr("...") literal in Sources is in both tables and no table key is unused; every Localizable.strings key has an English translation with matching format specifiers. If this fails you added/changed a tr() string in only one of Sources/NeveCore/Resources/{pt-BR,en}.lproj/Localizable.strings.)

import Testing
import Foundation
@testable import NeveCore

private func table(_ lang: String) -> [String: String] {
    guard let p = Bundle.module.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: lang),
          let d = NSDictionary(contentsOfFile: p) as? [String: String] else { return [:] }
    return d
}
private func specs(_ s: String) -> [String] {
    s.matches(of: /%(\d+\$)?[@dfsl]+/).map { String($0.output.0) }.sorted()
}

@Test func everyKeyHasAnEnglishTranslationWithMatchingFormats() {
    let pt = table("pt-BR"), en = table("en")
    #expect(!pt.isEmpty && Set(pt.keys) == Set(en.keys))
    for (k, v) in en {
        #expect(!v.isEmpty, "empty English value for \(k)")
        #expect(specs(k) == specs(v), "format mismatch for \(k)")
        #expect(specs(k) == specs(pt[k] ?? ""), "pt-BR format mismatch for \(k)")
    }
}

/// Every `tr("…")` literal in Sources is a key of both tables (an interpolation `\(x)` stands for a format specifier), and no table key is left unused.
@Test func everyTrKeyInSourcesIsInBothTablesAndNoneIsUnused() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
    func norm(_ s: String) -> String { s.replacing(/\\\([^)]*\)|%(\d+\$)?[@dfsl]+/, with: "%") }
    var used = Set<String>()
    for case let u as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)! where u.pathExtension == "swift" {
        for line in try String(contentsOf: u, encoding: .utf8).split(separator: "\n") where !line.drop(while: { $0 == " " }).hasPrefix("//") {
            for m in line.matches(of: /\btr\("((?:[^"\\]|\\.)*)"/) { used.insert(norm(String(m.output.1))) }
        }
    }
    let pt = Set(table("pt-BR").keys.map(norm)), en = Set(table("en").keys.map(norm))
    #expect(used.subtracting(pt).isEmpty && used.subtracting(en).isEmpty, "tr() keys missing from a table: \(used.subtracting(pt).union(used.subtracting(en)).sorted())")
    #expect(pt.subtracting(used).isEmpty, "table keys no tr() uses: \(pt.subtracting(used).sorted())")
    #expect(used.count > 50)
}
