import NeveCore
import Foundation

/// UserDefaults keys of the on / off options. Defaults: Nevar and Boneco de neve on, the rest off.
enum Pref: String {
    case enabled, economy, ambient, behindWindows, stillSnow, snowman, walk, showInCaptures
    var defaultValue: Bool { self == .enabled || self == .snowman || self == .walk }
}

/// The user options an overlay renders; the controller owns them (UserDefaults) and pushes them to every overlay.
struct OverlayPrefs: Equatable {
    var economy = false, behind = false, still = false, snowman = true, walk = true, showInCaptures = false
    var intensity = Intensity.media
}

extension Intensity {
    static func saved(_ ud: UserDefaults) -> Intensity { Intensity(rawValue: ud.object(forKey: key) as? Int ?? 1) ?? .media }
}
