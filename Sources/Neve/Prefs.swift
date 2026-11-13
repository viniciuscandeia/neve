// AGENT HEADER - Sources/Neve/Prefs.swift  (app-side environment -> simulation config)
// Role: process-wide lets that translate the OS / env into NeveCore inputs (NeveCore itself does no I/O): `osWindowRadius` (window corner radius by macOS version, Tuning.windowRadius), `simConfig` (SimConfig built from
//   NEVE_SNOWMAN_FAST, NEVE_DIRECTOR_FAST, NEVE_DEMO_ICE, NEVE_DEMO_PENGUIN, NEVE_DEMO_SLEIGH, NEVE_DEMO_VANISH=<s>, NEVE_DEMO_AVALANCHE=<s>), `sceneKind` (NEVE_SCENE=demo|fight) and `sceneSeed` (NEVE_SEED, default 7 demo / 4 fight),
//   and `Intensity.saved(ud)` (UserDefaults key `Intensity.key`, Int, default Intensity.defaultValue = media). Evaluated once at launch: changing an env var needs a restart.
// Note: the Bool preferences (enum Pref, OverlayPrefs) live in Sources/NeveCore/Prefs.swift; this file holds only what needs ProcessInfo / UserDefaults. Readers: main.swift, Overlay.swift (init uses simConfig / sceneSeed).

import NeveCore
import Foundation

/// Everything the app reads from the OS / environment for the simulation; NeveCore does no I/O.
let osWindowRadius = Tuning.windowRadius(for: ProcessInfo.processInfo.operatingSystemVersion)

/// NEVE_SNOWMAN_FAST=1 (demos): builds 20x faster and on a shallower pile. NEVE_DIRECTOR_FAST=1: visitors come 30x as often.
/// NEVE_DEMO_SLEIGH=1 (demos): the sleigh crosses soon after launch and every ~45 s. NEVE_DEMO_ICE=1 (demos): windows freeze fast and stalactites grow 120x faster. NEVE_DEMO_AVALANCHE=<secs>: fills the piles and starts an avalanche that often.
let simConfig: SimConfig = {
    let env = ProcessInfo.processInfo.environment
    var c = SimConfig()
    if env["NEVE_SNOWMAN_FAST"] == "1" { c.snowmanSpeed = 20; c.snowmanDepth = 4 }
    if env["NEVE_DIRECTOR_FAST"] == "1" { c.directorSpeed = 30 }
    if env["NEVE_DEMO_ICE"] == "1" { c.iceSpeed = 120 }
    c.penguinDemo = env["NEVE_DEMO_PENGUIN"] == "1"
    c.sleighDemo = env["NEVE_DEMO_SLEIGH"] == "1"
    c.demoVanishAt = Float(env["NEVE_DEMO_VANISH"] ?? "")
    c.avalancheDemo = Float(env["NEVE_DEMO_AVALANCHE"] ?? "") ?? 0
    return c
}()

/// `NEVE_SCENE=demo|fight` (+ `NEVE_SEED`, default 7 / 4): a deterministic showcase scene on the main screen (NeveCore/Scene.swift, SceneStage.swift).
let sceneKind: SceneKind? = ProcessInfo.processInfo.environment["NEVE_SCENE"].flatMap(SceneKind.init(rawValue:))
let sceneSeed: UInt64? = sceneKind.map { UInt64(ProcessInfo.processInfo.environment["NEVE_SEED"] ?? "") ?? ($0 == .demo ? 7 : 4) }

extension Intensity {
    static func saved(_ ud: UserDefaults) -> Intensity { Intensity(rawValue: ud.object(forKey: key) as? Int ?? defaultValue.rawValue) ?? defaultValue }
}
