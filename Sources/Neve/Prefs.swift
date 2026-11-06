import NeveCore
import Foundation

/// UserDefaults keys of the on / off options. Defaults: Nevar and Boneco de neve on, the rest off.
enum Pref: String, CaseIterable {
    case enabled, economy, ambient, behindWindows, behindLarge, stillSnow, snowman, walk, visitors, sleigh, showInCaptures, adaptiveFps
    var defaultValue: Bool { [.enabled, .snowman, .walk, .visitors, .sleigh, .adaptiveFps].contains(self) }
}

/// Which Bool prefs differ between two snapshots (drives `AppController.prefChanged`).
func changedPrefs(old: [Pref: Bool], new: [Pref: Bool]) -> [Pref] { changedKeys(old: old, new: new) }

/// The user options an overlay renders; the controller owns them (UserDefaults) and pushes them to every overlay.
struct OverlayPrefs: Equatable {
    var economy = false, behind = false, behindLarge = false, still = false, snowman = true, walk = true, visitors = true, sleigh = true, showInCaptures = false, adaptive = true
    var intensity = Intensity.media
}

/// Everything the app reads from the OS / environment for the simulation; NeveCore does no I/O.
let osWindowRadius = Tuning.windowRadius(for: ProcessInfo.processInfo.operatingSystemVersion)

/// NEVE_SNOWMAN_FAST=1 (demos): builds 20x faster and on a shallower pile. NEVE_DIRECTOR_FAST=1: visitors come 30x as often.
let simConfig: SimConfig = {
    let env = ProcessInfo.processInfo.environment
    var c = SimConfig()
    if env["NEVE_SNOWMAN_FAST"] == "1" { c.snowmanSpeed = 20; c.snowmanDepth = 4 }
    if env["NEVE_DIRECTOR_FAST"] == "1" { c.directorSpeed = 30 }
    return c
}()

extension Intensity {
    static func saved(_ ud: UserDefaults) -> Intensity { Intensity(rawValue: ud.object(forKey: key) as? Int ?? 1) ?? .media }
}
