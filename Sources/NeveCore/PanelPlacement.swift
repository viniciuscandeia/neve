// AGENT HEADER - Sources/NeveCore/PanelPlacement.swift  (small pure helpers for the menu / Ajustes UI)
// Role: `takeOnce(key, in:)` (true the first time, persisted in the given UserDefaults store: first-launch menu, one-time hints), `restoreDefaults(in:)` (removes every stored option so each reads its default from Pref / Intensity again), `screenLabels(names:sizes:)` (names for the "Nevar em"
//   picker: identical names get the resolution then a number), `loginNote(requiresApproval:failed:)` (caption text via tr()), `steppedLevel(_:by:)` (Quantidade 0...3). Callers: Sources/Neve/main.swift, SettingsView.swift. Strings here go through tr(): keep both Localizable.strings in sync. Tests: PanelPlacementTests.

import CoreGraphics
import Foundation

/// True the first time it is asked for `key`, false after: first-launch menu, one-time hints. Persisted in `store`.
public func takeOnce(_ key: String, in store: UserDefaults) -> Bool {
    if store.bool(forKey: key) { return false }
    store.set(true, forKey: key)
    return true
}

/// "Restaurar padrões": drops every stored option (the Bool prefs, Quantidade, "Nevar em") so each reads its default again from `Pref` / `Intensity`.
public func restoreDefaults(in store: UserDefaults) {
    (Pref.allCases.map(\.rawValue) + [Intensity.key, "snowOn"]).forEach(store.removeObject(forKey:))
}

/// Names for the "Nevar em" picker: the main screen is marked, and identical names get their resolution (then a number) appended.
public func screenLabels(names: [String], sizes: [CGSize]) -> [String] {
    var out = zip(names, sizes).map { $0 }.enumerated().map { i, p in
        let dup = names.filter { $0 == p.0 }.count > 1
        return p.0 + (dup ? " (\(Int(p.1.width))×\(Int(p.1.height)))" : "") + (i == 0 ? " (" + tr("principal") + ")" : "")
    }
    for (i, l) in out.enumerated() where out.filter({ $0 == l }).count > 1 { out[i] = l + " #\(i + 1)" }
    return out
}

/// Caption under "Abrir ao iniciar sessão" after a register / unregister attempt ("" = nothing to say).
public func loginNote(requiresApproval: Bool, failed: Bool) -> String {
    requiresApproval ? tr("Aprove em Ajustes do Sistema › Itens de Início.") : failed ? tr("Não foi possível alterar; tente em Ajustes do Sistema › Itens de Início.") : ""
}

/// Quantidade stepped by an arrow key / VoiceOver adjust, clamped to 0...3.
public func steppedLevel(_ level: Int, by d: Int) -> Int { min(3, max(0, level + d)) }
