import Foundation

/// SwiftPM's generated `Bundle.module` looks for the resource bundle at the .app root (unsealed, breaks codesign), so the app keeps it in Contents/Resources
/// (scripts/make-app.sh) and it is looked up there first; `Bundle.module` is only the fallback for `swift run` and tests.
let l10nBundle = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("Neve_NeveCore.bundle")) } ?? Bundle.module

/// Every user-visible string goes through here. Keys are the Portuguese text (the development language); `Resources/<lang>.lproj/Localizable.strings` holds pt-BR and en.
public func tr(_ key: String.LocalizationValue) -> String { String(localized: key, bundle: l10nBundle) }
