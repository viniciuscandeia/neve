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
