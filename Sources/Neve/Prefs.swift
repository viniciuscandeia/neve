import NeveCore
import Foundation

/// UserDefaults keys of the on / off options. Defaults: Nevar and Boneco de neve on, the rest off.
enum Pref: String {
    case enabled, economy, ambient, behindWindows, stillSnow, snowman, walk, showInCaptures, behindLarge   // behindLarge: windows >= 35% of the usable area hide only the background flakes
    var defaultValue: Bool { self == .enabled || self == .snowman || self == .walk }
}

/// The user options an overlay renders; the controller owns them (UserDefaults) and pushes them to every overlay.
struct OverlayPrefs: Equatable {
    var economy = false, behind = false, still = false, snowman = true, walk = true, showInCaptures = false, behindLarge = false
    var intensity = Intensity.media
}

/// Everything the app reads from the OS / environment for the simulation; NeveCore does no I/O.
let osWindowRadius = Tuning.windowRadius(for: ProcessInfo.processInfo.operatingSystemVersion)

/// NEVE_SNOWMAN_FAST=1 (demos): builds 20x faster and on a shallower pile.
let simConfig: SimConfig = ProcessInfo.processInfo.environment["NEVE_SNOWMAN_FAST"] == "1"
    ? SimConfig(snowmanSpeed: 20, snowmanDepth: 4) : SimConfig()

extension Intensity {
    static func saved(_ ud: UserDefaults) -> Intensity { Intensity(rawValue: ud.object(forKey: key) as? Int ?? 1) ?? .media }
}
