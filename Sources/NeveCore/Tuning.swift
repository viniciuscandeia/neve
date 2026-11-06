import CoreGraphics
import Foundation


/// Tuning knobs.
public enum Tuning {
    public static let flakes = 400                 // per 1440x900 screen (scaled by area)
    static let backgroundFraction: Float = 0.35
    static let maxPileHeight: Float = 18
    static let pileEase: Float = 0.25               // time constant of the drawn pile height rising toward the real one
    static let groundMaxHeight: Float = 24  // screen-bottom pile (lower-traffic, wide open, can sit deeper)
    static let groundID = -1
    static let bankSlope: Float = 0.35      // repose slope (pt per pt) of the ground snowbank rising toward a bottom Dock bar
    static let minHeadroom: Float = 18      // a window top needs this much free space below the menu bar to carry snow
    static let minRoom: Float = 4           // columns with less room under a front window take no deposits
    static let binWidth: Float = 2
    static let slope: Float = 0.7           // max height step between neighbouring bins (~19 degree repose)
    static let cornerInset: Float = 6       // piles taper to 0 this far from surface ends
    /// Window corner radius: ~20pt from macOS 26 (Tahoe) on, ~10pt before.
    public static func windowRadius(for v: OperatingSystemVersion) -> CGFloat { v.majorVersion >= 26 ? 20 : 10 }
    public static let defaultWindowRadius: CGFloat = 20   // the app passes the OS-dependent value via WindowInfo.radius
    static let calmSway: Float = 0.25       // Reduce Motion: share of the lateral flake sway kept
    static let calmDebrisFall: Float = 30   // Reduce Motion: uniform initial fall speed of knocked-off snow
    static let depositScale: Float = 1.2    // pile volume per flake size
    static let wind: Float = 6
    static let maxDebris = 1200
    public static let snowmanDepth: Float = 14              // average pile height over the stretch that triggers a build (SimConfig default)
    static let snowmanStretch: Float = 70                   // pt of visible ground the snowman needs
    static let snowmanClearance: Float = 20                 // pt kept free to the Dock ends, covering windows and screen edges
    static let ballStart: Float = 5                         // scooped snowball radius (10pt across)
    static let ballMax: Float = 20                          // rolled snowball radius cap (40pt across)
    static let ballGrowth: Float = 0.1                      // radius per pt rolled
    public static let maxBalls = 6
    static let snowmanCooldown: Float = 120                 // s of snowfall after a collapse
    static let pointerRadius: Float = 60     // falling snow avoids the cursor within this distance
    static let pointerPush: Float = 450      // pt/s radial speed at point blank (scaled by (1 - d/R)^2)
    static let pointerSwirl: Float = 250     // tangential counterpart
    static let debrisGravity: Float = 1400   // pt/s^2: packed snow accelerates instead of floating
    static let debrisTerminal: Float = 1700  // pt/s
    // Moving a window: the pile travels with it; `shed` (0...1) of it falls off, rising smoothly with speed.
    static let shedStart: Float = 400        // pt/s: below this nothing falls off
    static let shedFull: Float = 2500        // pt/s: at or above this everything falls off
    static let velSmoothing: Float = 0.1     // s: window velocity low-pass time constant
    public static let shedRefDt: Float = 0.1        // s: update interval the shed fractions are calibrated for
    static let shedUp: Float = 0.8           // upward speed counts less (snow is pressed onto the roof) ...
    static let shedDown: Float = 1.3         // ... downward counts more (faster than gravity: snow floats off)
    static let shakeGain: Float = 0.7        // direction reversal: effective speed = this * |velocity change|
    static let shedEdgeBias: Float = 1.5     // extra shed at the window ends ...
    static let shedEdgeZone: Float = 0.15    // ... within this fraction of the width
}

/// Snow amount; `multiplier` scales the base flake count. Nevasca adds strong gusty wind.
public enum Intensity: Int, CaseIterable {
    case leve, media, forte, nevasca
    public static let key = "intensity"
    public var title: String { ["Leve", "Média", "Forte", "Nevasca"][rawValue] }
    var multiplier: Float { [0.4, 1.0, 1.8, 3.0][rawValue] }
    var windGain: Float { self == .nevasca ? 100 : 8 }   // peak sideways speed, points/s
}

/// Knobs injected by the app (it reads env / OS); the simulation itself never looks outside.
public struct SimConfig: Sendable {
    public var snowmanSpeed: Float = 1                    // build / cooldown time scale (demos: 20)
    public var snowmanDepth: Float = Tuning.snowmanDepth  // average pile height over the stretch that triggers a build
    public init(snowmanSpeed: Float = 1, snowmanDepth: Float = Tuning.snowmanDepth) {
        self.snowmanSpeed = snowmanSpeed; self.snowmanDepth = snowmanDepth
    }
}
