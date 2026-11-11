// AGENT HEADER - Sources/NeveCore/Localization.swift  (the ONE localisation entry point)
// Role: `l10nBundle` (Bundle: Contents/Resources/Neve_NeveCore.bundle first - scripts/make-app.sh copies it there because SwiftPM's Bundle.module location at the .app root breaks codesign - else Bundle.module for `swift run` / tests) and `tr(_:)`, which EVERY user-visible string must use.
// Keys are the Portuguese text (development language); translations live in Sources/NeveCore/Resources/pt-BR.lproj/Localizable.strings and .../en.lproj/Localizable.strings: add a key to BOTH. Tests: LocalizationTests (same key set in both tables, format specifiers match).

import Foundation

/// SwiftPM's generated `Bundle.module` looks for the resource bundle at the .app root (unsealed, breaks codesign), so the app keeps it in Contents/Resources
/// (scripts/make-app.sh) and it is looked up there first; `Bundle.module` is only the fallback for `swift run` and tests.
let l10nBundle = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("Neve_NeveCore.bundle")) } ?? Bundle.module

/// Every user-visible string goes through here. Keys are the Portuguese text (the development language); `Resources/<lang>.lproj/Localizable.strings` holds pt-BR and en.
public func tr(_ key: String.LocalizationValue) -> String { String(localized: key, bundle: l10nBundle) }
