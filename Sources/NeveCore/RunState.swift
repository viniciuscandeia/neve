// AGENT HEADER - Sources/NeveCore/RunState.swift  (pure run / idle decisions of the app controller, testable without AppKit)
// Role: `RunState` = the pause reasons that are plain flags (outro playing, screens asleep, session inactive, screen saver; thermal `hot` is passed in) and the derived predicates the app uses everywhere:
//   running(enabled:) = (enabled || outroing) && !screensAsleep && !sessionInactive && !screensaver; polling = running && !hot; rendering = polling && !userIdle (overlays run only then).
//   `IdleMonitor.decide` (Sources/Neve/IdleMonitor.swift) calls `idleAction`: start the melt after `idleSecs` of no input (unless Modo ambiente / scene / already idle), wake on input newer than max(2, timerGap + 0.5) s.
//   `musicWanted` = the audio-capture rule: option on, not calm (Reduce Motion / economy / Low Power / scene) and the snow actually rendering (not off, idle, locked, asleep, hot).
// Used by: AppController (main.swift) and IdleMonitor. Tests: RunStateTests.

public struct RunState: Equatable, Sendable {
    public var outroing = false, screensAsleep = false, sessionInactive = false, screensaver = false
    public init() {}
    public func running(enabled: Bool) -> Bool { (enabled || outroing) && !screensAsleep && !sessionInactive && !screensaver }
    /// Polling timers only run while snow is actually shown (not disabled / asleep / locked / hot).
    /// `hot` = thermal state >= serious, read live by the caller.
    public func polling(enabled: Bool, hot: Bool) -> Bool { running(enabled: enabled) && !hot }
    /// Overlays render only when polling and the user is not idle.
    public func rendering(enabled: Bool, hot: Bool, userIdle: Bool) -> Bool { polling(enabled: enabled, hot: hot) && !userIdle }
}

/// Audio capture runs only while the snow runs: `rendering` = RunState.rendering(...). Off / idle / locked / asleep => the capture (and its menu-bar indicator) is torn down.
public func musicWanted(pref: Bool, reduceMotion: Bool, calm: Bool, scene: Bool, rendering: Bool) -> Bool {
    pref && !reduceMotion && !calm && !scene && rendering
}

public enum IdleAction: Equatable, Sendable { case none, melt, wake }

/// What the idle check should do given the seconds since the last input (`since`), the idle state and the safety timer gap.
public func idleAction(since: Double, userIdle: Bool, idleMelting: Bool, ambient: Bool, scene: Bool, idleSecs: Double, timerGap: Double) -> IdleAction {
    if !userIdle && !idleMelting && !ambient && !scene && since >= idleSecs { return .melt }
    if (userIdle || idleMelting) && since < max(2, timerGap + 0.5) { return .wake }
    return .none
}
