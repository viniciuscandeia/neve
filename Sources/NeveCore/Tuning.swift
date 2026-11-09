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
    static let bankShelf: Float = 400       // widest level shelf the bank may grow beside a Dock end; beyond it the ground falls away at the repose slope
    /// Height limit of the ground bank at `distance` pt from a Dock bar end: a repose-slope ramp that starts at `level` at the bar, floored at the open ground
    /// limit and capped at the Dock top (a shelf flush with it). `level` rises as the bank fills (SnowField.stepBank), so the ramp grows into a shelf.
    static func bankLimit(dockTop: Float, distance d: Float, level: Float) -> Float {
        min(max(level - bankSlope * d, groundMaxHeight), max(dockTop, groundMaxHeight))
    }
    /// The `level` at which the shelf is complete: flush with the Dock top across the gap (up to `bankShelf`).
    static func bankLevelMax(dockTop: Float, gap: Float) -> Float { max(dockTop, groundMaxHeight) + bankSlope * min(gap, bankShelf) }
    /// Underside of a floating Dock bar's rounded rect at `x` (nil outside it): minY along the flat, rising along the corner arcs.
    static func barUnderside(x: Float, minX: Float, maxX: Float, minY: Float, radius: Float) -> Float? {
        guard x >= minX, x < maxX else { return nil }
        let r = max(min(radius, (maxX - minX) / 2), 0), dx = max(minX + r - x, x - (maxX - r), 0)
        return max(minY, 0) + r - (max(r * r - dx * dx, 0)).squareRoot()
    }
    /// The visible Dock glass sits this many pt below the AX list's frame (CG coordinates, y down), same size. Measured on macOS 26 by capturing the
    /// Dock window alone: AX list y 806..890, opaque glass y 811..895. Calibration knob if a later macOS moves it.
    public static let dockGlassOffset: CGFloat = 5
    public static func dockGlass(fromAX r: CGRect) -> CGRect { r.offsetBy(dx: 0, dy: dockGlassOffset) }
    static let dockSpeed: Float = 800       // pt/s: the sim moves each Dock end toward the read frame at most this fast (a visible plow)
    static let dockSlumpTime: Float = 3   // s the bank keeps relaxing near the Dock ends after one moved
    static let dockPushReach: Float = 40    // pt behind a moving Dock end still counted as swept (the old rounded corner)
    static let dockKick: Float = 0.25       // share of plowed snow thrown up as debris (none in calm mode)
    static let barMargin: Float = 1         // ground snow stays this far below the bar's underside
    static let minHeadroom: Float = 18      // a window top needs this much free space below the menu bar to carry snow
    static let maxDrift: Float = 24         // snow banked against a front window reaches its top up to this step (and no higher)
    static let driftFar: Float = 120        // step beyond which the drift is only a small ramp
    static let driftFarRamp: Float = 4
    static let driftSlope: Float = 0.3      // pt per pt of the drift profile (below the 0.35 repose)
    static let driftMinWidth: Float = 30
    static let peelSpeed: Float = 180       // pt/s: a collapsing drift lets go from the wall outward
    static let minRoom: Float = 4           // columns with less room under a front window take no deposits
    static let binWidth: Float = 2
    static let slope: Float = 0.7           // max height step between neighbouring bins (~19 degree repose)
    static let dustSlope: Float = 2.5      // extra step allowed onto a thin bin (fades to 0 as it fills to dustDepth): fresh snow stays in small mounds where it lands instead of a wide film
    static let dustDepth: Float = 6.0
    static let speckFloor: Float = 1.5      // below this a bin neither relaxes nor counts as built up: bare snow stays as isolated specks until later landings stack on it
    static let speckStick: Float = 0.04     // share of a landing that sticks on a completely bare bin (rises to 1 as the bin reaches speckFloor)
    static let cornerInset: Float = 6       // piles taper to 0 this far from surface ends
    /// Window corner radius: ~20pt from macOS 26 (Tahoe) on, ~10pt before.
    public static func windowRadius(for v: OperatingSystemVersion) -> CGFloat { v.majorVersion >= 26 ? 20 : 10 }
    public static let defaultWindowRadius: CGFloat = 20   // the app passes the OS-dependent value via WindowInfo.radius
    static let calmSway: Float = 0.25       // Reduce Motion: share of the lateral flake sway kept
    static let calmDebrisFall: Float = 30   // Reduce Motion: uniform initial fall speed of knocked-off snow
    static let penguinGroove: Float = 2.5           // belly-slide trench depth (pt, at most 35% of the pile)
    static let penguinBerm: Float = 0.4             // share of the plowed area banked in berms on both sides of a deep cut (shallow: 0.8); the rest sprays
    static let penguinPuff: Float = 8               // plowed area (pt^2) per spray puff
    static let depositScale: Float = 0.8    // pile volume per flake size
    static let wind: Float = 6
    static let nearFraction: Float = 0.02   // out-of-focus foreground flakes: share of the active sky count
    static let nearAlpha: Float = 0.28
    static let maxDebris = 1200
    static let busyDebris = 24   // loose chunks alive before the frame rate goes up (steady Nevasca shedding peaks near 16)
    static let maxPuffs = 24
    static let maxGlints = 6
    static let maxDrops = 16                // meltwater droplets alive at once (Drips.swift)
    static let dripRate: Float = 5          // new droplets per second while melting
    static let heavyFall: Float = 350       // impact speed and carried volume that dig a crater (Effects.swift)
    static let heavyVol: Float = 6
    static let rippleSpeed: Float = 900     // pt/s: a vanished pile lets go chunk by chunk along this front (Effects.swift)
    static let puffLife: Float = 0.6
    static let glintLife: Float = 0.6
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
    public var iceSpeed: Float = 1                        // ice time scale (freeze + stalactite growth) (demos: 120)
    public var avalancheDemo: Float = 0                   // > 0: fills the piles and starts an avalanche every this many seconds (demos)
    public var penguinDemo = false                        // NEVE_DEMO_PENGUIN: a penguin visit every ~12 s (cap and cooldown aside)
    public var sleighDemo = false                         // NEVE_DEMO_SLEIGH: a crossing starts as soon as there is a pile to drop on, then every ~45 s (the director gap)
    public var demoVanishAt: Float?                       // NEVE_DEMO_VANISH: scene time at which the top window is treated as minimised (visual checks)
    public var directorSpeed: Float = 1                   // EventDirector intervals / gaps / cooldowns are divided by this (demos: 30)
    public init(snowmanSpeed: Float = 1, snowmanDepth: Float = Tuning.snowmanDepth, iceSpeed: Float = 1, avalancheDemo: Float = 0, directorSpeed: Float = 1, sleighDemo: Bool = false) {
        self.snowmanSpeed = snowmanSpeed; self.snowmanDepth = snowmanDepth; self.iceSpeed = iceSpeed; self.avalancheDemo = avalancheDemo; self.directorSpeed = directorSpeed; self.sleighDemo = sleighDemo
    }
}
