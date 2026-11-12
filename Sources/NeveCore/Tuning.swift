// AGENT HEADER - Sources/NeveCore/Tuning.swift  (every simulation constant, Intensity, SimConfig)
// Role: `Tuning` = static knobs, all in points (pt), seconds, pt/s, or pt^2 for areas, y-up. Groups: snow field (flakes per 1440x900 screen, backgroundFraction, binWidth = 2 pt per pile bin, slope = max step between neighbouring
//   bins, dustSlope/dustDepth/speck* = how thin snow stays in mounds, cornerInset), pile caps (maxPileHeight = window tops, groundMaxHeight, moundMax = sanity bound on cursor-pushed heaps), Dock bank (bankSlope/bankShelf/bankLimit/
//   bankLevelMax, dockGlassOffset: the visible glass is 5 pt BELOW the AX list frame on macOS >= 26 (CG y-down), windowRadius 22 pt on macOS >= 26 else 10, dock* plow constants), drift/peel against front windows, wind, debris/puffs/glints/
//   drops caps, shed (a moved window sheds snow from shedStart to shedFull pt/s), snowman/ball sizes, pointer push radius, frame-rate floors (calmFloorFPS 30, economy 20), `interpolateCalm` (env NEVE_INTERP=1, default off: measured costlier).
//   Drawn contour knobs (crestSlope, crestMaxStep, snowyMin, stretchGap, ownerGapMax, capBlend*, bridge*) and the Pile relax window (relaxReach, relaxPasses, moundReach) are here too.
// `Intensity` (leve, media, forte, nevasca; UserDefaults key "intensity", Int raw value; multiplier on flake count, windGain; titles via tr()). `SimConfig` (Sendable): knobs the APP injects (snowman/ice/director speed, demo flags) so NeveCore never reads env.
// Snow age (ageSlope, ageFull, ageFresh: Pile.age / reposeStep). Rules: constants only; behaviour lives elsewhere. Many are `static let` internal (tests use @testable import). Changing binWidth / slope / maxPileHeight shifts pile behaviour everywhere and invalidates tuned tests (PileLogicTests, SurfaceMapTests, WritePiles*).
// Public surface used by the app target: flakes, plowFloor, interpolateCalm, dockGlass(fromAX:), windowRadius(for:), defaultWindowRadius, maxBalls, snowmanDepth, shedRefDt, Intensity, SimConfig.
// Gotcha: the `dockGlassOffset` / `windowRadius` values were measured on macOS 26 (calibration knobs, not derived).

import CoreGraphics
import Foundation


/// Tuning knobs.
public enum Tuning {
    public static let flakes = 400                 // per 1440x900 screen (scaled by area)
    static let backgroundFraction: Float = 0.35
    static let maxPileHeight: Float = 18
    static let moundMax: Float = 600        // pt: sanity bound on a cursor-pushed heap (it has no other limit but a window's cap)
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
    /// The 5pt offset was measured on macOS 26 only; earlier systems draw the glass at the AX frame.
    public static func dockGlassOffset(for v: OperatingSystemVersion) -> CGFloat { v.majorVersion >= 26 ? dockGlassOffset : 0 }
    public static func dockGlass(fromAX r: CGRect, for v: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> CGRect { r.offsetBy(dx: 0, dy: dockGlassOffset(for: v)) }
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
    static let goneGrace: Double = 0.6      // s a window may be missing from the poll before its pile is knocked off
    static let peelSpeed: Float = 180       // pt/s: a collapsing drift lets go from the wall outward
    static let minRoom: Float = 4           // columns with less room under a front window take no deposits
    static let binWidth: Float = 2
    static let slope: Float = 0.7           // max height step between neighbouring bins (~19 degree repose)
    static let ageSlope: Float = 1.1        // repose step of fully aged (compacted) snow: an old pile holds a steeper face than fresh (slope 0.7)
    static let ageFull: Float = 600         // s for snow to reach ageSlope (age rises while a bin holds snow, up to this cap)
    static let ageFresh: Float = 4          // weight of fresh snow when it lands on old snow: a dusting renews the surface faster than its volume share
    static let eaveMax: Float = 14          // pt^2 of cornice (overhang past an unsupported window end) that lets go as one block
    static let eaveRate: Float = 0.5        // pt^2/s the end of a snowy window top feeds its cornice (full depth, calm air)
    static let eaveWind: Float = 3          // extra feed factor when the sustained wind blows toward that end
    static let eaveDepth: Float = 2         // mean depth (pt) of the snow 6-12 pt inside the end below which no cornice builds (and an existing one melts away)
    static let moundSlope: Float = 1.3      // extra step allowed inside a cursor-pushed heap (slope + this = ~2.0 per 2 pt bin, ~45 degrees): pushed snow is compacted, it settles little and slowly
    static let dustSlope: Float = 2.5      // extra step allowed onto a thin bin (fades to 0 as it fills to dustDepth): fresh snow stays in small mounds where it lands instead of a wide film
    static let dustDepth: Float = 6.0
    static let speckFloor: Float = 1.5      // below this a bin neither relaxes nor counts as built up: bare snow stays as isolated specks until later landings stack on it
    static let speckStick: Float = 0.04     // share of a landing that sticks on a completely bare bin (rises to 1 as the bin reaches speckFloor)
    static let cornerInset: Float = 6       // piles taper to 0 this far from surface ends
    static let relaxReach = 8               // Pile.deposit relaxes this many bins either side of the landing (+1 for the trim) ...
    static let relaxPasses = 6              // ... in this many passes
    static let moundReach = 9               // a deposit re-checks a pushed heap's allowance this many bins either side
    // Drawn contour (Render.writePiles, Contour.writeGroups): draw only, never changes heights
    static let crestSlope: Float = 0.95     // steepest drawn crest step per bin (a gentle ramp: <= 1 pt per 2 pt step)
    static let crestMaxStep: Float = 2.0    // two owners further apart than this after the lift are not joined
    static let snowyMin: Float = 0.15       // a shown height above this is snow in the draw (less is bare: it splits stretches)
    static let stretchGap = 3               // this many bare columns split a drawn stretch
    static let ownerGapMax = 4              // columns without an owner between two owners (side-by-side windows) that are bridged
    static let capBlendRoom: Float = 1.5    // packed up to a window's underside: the crest blends onto it over the last 1.5 pt of room ...
    static let capBlendSpan: Float = 1.45   // ... (the blend is complete 0.05 pt before the cap)
    static let bridgeReach: Float = 60      // ground bank <-> Dock pile ends within this in x join in one slice ...
    static let bridgeTol: Float = 2.5       // ... when their tops differ by at most this (the top has up to 1.5 pt of noise)
    /// Window corner radius: ~22pt from macOS 26 (Tahoe) on, ~10pt before.
    public static func windowRadius(for v: OperatingSystemVersion) -> CGFloat { v.majorVersion >= 26 ? 22 : 10 }   // measured: a Finder window's bottom corner on macOS 26
    public static let defaultWindowRadius: CGFloat = 22   // the app passes the OS-dependent value via WindowInfo.radius
    static let calmSway: Float = 0.25       // Reduce Motion: share of the lateral flake sway kept
    static let calmDebrisFall: Float = 30   // Reduce Motion: uniform initial fall speed of knocked-off snow
    static let penguinGroove: Float = 2.5           // belly-slide trench depth (pt, at most 35% of the pile)
    static let penguinBerm: Float = 0.4             // share of the plowed area banked in berms on both sides of a deep cut (shallow: 0.8); the rest sprays
    static let penguinPuff: Float = 8               // plowed area (pt^2) per spray puff
    static let depositScale: Float = 0.97   // pile volume per flake size (0.8 before the small-biased sizes: mean sky size 4.75 -> 3.9, same snowfall rate)
    static let wind: Float = 6
    static let nearFraction: Float = 0.02   // out-of-focus foreground flakes: share of the active sky count
    static let nearAlpha: Float = 0.28
    static let maxDebris = 1200
    static let busyDebris = 24   // loose chunks alive before the frame rate goes up (steady Nevasca shedding peaks near 16)
    static let maxPuffs = 24
    // Frame rate (Util.swift FrameRate). Measure CPU, then pick.
    static let calmFloorFPS: Float = 30             // quiet rate (nothing fast for FrameRate.holdDown = 2.5 s after the last input / motion); 60 = smoothest, costliest
    static let calmFloorEconomyFPS: Float = 20      // same, Economy mode
    /// Option, default OFF: at the calm floor step the sim at the floor rate but let the renderer interpolate positions every display refresh
    /// (FrameRate.interpAlpha). Needs renderer wiring (prev/cur flake buffers); CPU = sim at floor + draw at display rate.
    public static let plowFloor: Float = 2   // pt of snow a cursor pass leaves on a window (a bare edge between lumps reads as dark dashes)
    static let plowSlowSpeed: Float = 40    // pt/s: cursor slower than this is a hover (gentle dent)
    static let plowHoverDepth: Float = 0.6  // pt removed per pass while hovering
    public static let plowRadius: Float = 14       // pt: effective half-width of the cursor blade; a push (>= plowSlowSpeed) scoops everything under it down to plowFloor, soft rounded edges
    public static let interpolateCalm = ProcessInfo.processInfo.environment["NEVE_INTERP"] == "1"   // off: measured 2026-11-11, render at display rate costs +3.3..3.7% CPU and +8% WindowServer (fixed per-frame present cost); NEVE_INTERP=1 to re-measure
    // Wind-blown accumulation
    static let windBiasMax: Float = 0.3     // chance a landing flake slides one bin leeward when that bin is lower (at the sustained-wind cap)
    static let windBiasRef: Float = 150     // sustained wind speed (pt/s) at which the chance reaches the cap
    static let dustWind: Float = 60         // |wind| (pt/s) above which crests shed dust (only Nevasca gusts get there)
    static let dustRate: Float = 6          // lift attempts per second at 2x the threshold
    static let dustVol: Float = 0.2         // max volume moved per lift (area, pt^2); conserved: it lands in the leeward bin
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
    static let burstSpeed: Float = 110                     // pt/s: slowest chunk of a snowman exploded by the cursor (up to 2x)
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
    public var title: String { [tr("Leve"), tr("Média"), tr("Forte"), tr("Nevasca")][rawValue] }
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
