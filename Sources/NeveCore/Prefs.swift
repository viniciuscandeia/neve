// AGENT HEADER - Sources/NeveCore/Prefs.swift  (option model shared by the app and the overlays)
// Role: `Pref` (String raw value = the stored UserDefaults key: NEVER rename; defaults ON: enabled, snowman, walk, visitors, sleigh, christmasTree, lights, adaptiveFps, pointerPush; the rest default OFF), `changedPrefs` (diff of two snapshots; drives AppController.prefChanged) and `OverlayPrefs`
//   (what an Overlay renders: economy, behind, behindLarge, still, snowman, walk, visitors, sleigh, tree, lights, showInCaptures, adaptive, music, pointerPush, intensity), built by `init(_ flag:)` so defaults live ONLY in `Pref.defaultValue`. Adding an option: new case here, a UI row in
//   Sources/Neve/SettingsView.swift, a branch in AppController.prefChanged, an OverlayPrefs field + Overlay.apply wiring, and tr() strings in both languages.

import Foundation

/// UserDefaults keys of the on / off options (raw values are the stored keys: never rename). Defaults on: Nevar, Boneco de neve, Andam e brigam, Visitantes, Trenó, Árvore de Natal, Luzes de Natal, Quadros adaptativos, Cursor empurra os flocos; the rest off.
public enum Pref: String, CaseIterable, Sendable {
    case enabled, economy, ambient, behindWindows, behindLarge, stillSnow, snowman, walk, visitors, sleigh, christmasTree, lights, showInCaptures, adaptiveFps, music, pointerPush
    public var defaultValue: Bool { [.enabled, .snowman, .walk, .visitors, .sleigh, .christmasTree, .lights, .adaptiveFps, .pointerPush].contains(self) }
}

/// Which Bool prefs differ between two snapshots (drives `AppController.prefChanged`).
public func changedPrefs(old: [Pref: Bool], new: [Pref: Bool]) -> [Pref] { changedKeys(old: old, new: new) }

/// The user options an overlay renders; the controller owns them (UserDefaults) and pushes them to every overlay.
/// `init(_:)` reads every flag through `flag` (default: `Pref.defaultValue`), so the defaults live in `Pref` only.
public struct OverlayPrefs: Equatable {
    public var economy, behind, behindLarge, still, snowman, walk, visitors, sleigh, tree, lights, showInCaptures, adaptive, music, pointerPush: Bool
    public var intensity = Intensity.media
    public init(_ flag: (Pref) -> Bool = { $0.defaultValue }) {
        economy = flag(.economy); behind = flag(.behindWindows); behindLarge = flag(.behindLarge); still = flag(.stillSnow)
        snowman = flag(.snowman); walk = flag(.walk); visitors = flag(.visitors); sleigh = flag(.sleigh); tree = flag(.christmasTree); lights = flag(.lights)
        showInCaptures = flag(.showInCaptures); adaptive = flag(.adaptiveFps); music = flag(.music); pointerPush = flag(.pointerPush)
    }
}
