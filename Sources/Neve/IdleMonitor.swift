// AGENT HEADER - Sources/Neve/IdleMonitor.swift  (idle melt / wake state of the app, MainActor)
// Role: owns `userIdle` (no input for `idleSecs`, after the melt: rendering paused, polling kept to notice input), `melting` (the timeout fired: snow melting away, then userIdle) and `meltGen` (guards stale melt completions).
//   `check(ambient:scene:timerGap:)` is called from AppController.pollTick: reads seconds since the last input event (CGEventSource, no Accessibility needed), asks NeveCore `idleAction` (RunState.swift) and runs startMelt / wake.
//   `cancel()` = a pref change (Neve on/off) invalidates a running melt. Idle timeout NEVE_IDLE_SECS (default 300 s) shortens for dev / recordings.
// Wiring: `overlays` (closure) and `changed` (AppController.refreshRunState) are set by AppController; the monitor never touches overlays beyond melt() / resume().
// Gotchas: wake() cancels a running melt and restarts the snow from the top edge (resume), like the intro.

import AppKit
import NeveCore

@MainActor
final class IdleMonitor {
    private(set) var userIdle = false, melting = false
    private var meltGen = 0
    let idleSecs = Double(ProcessInfo.processInfo.environment["NEVE_IDLE_SECS"] ?? "") ?? 300
    var overlays: () -> [Overlay] = { [] }
    var changed: () -> Void = {}

    /// No input for 5 min pauses rendering; input resumes it (checked here, so no Accessibility needed for keys).
    func check(ambient: Bool, scene: Bool, timerGap: Double) {
        let since = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)   // kCGAnyInputEventType
        switch idleAction(since: since, userIdle: userIdle, idleMelting: melting, ambient: ambient, scene: scene, idleSecs: idleSecs, timerGap: timerGap) {
        case .melt: startMelt()
        case .wake: wake()
        case .none: break
        }
    }

    /// Neve switched on / off: a pending melt completion must not fire.
    func cancel() { meltGen += 1; melting = false }

    /// The idle timeout: the snow melts away on every overlay, then rendering pauses (userIdle).
    private func startMelt() {
        melting = true
        meltGen += 1
        let gen = meltGen
        let all = overlays()
        var left = Countdown(all.count)
        guard !left.isDone else { melting = false; userIdle = true; return changed() }
        for o in all {
            o.melt { [weak self] in
                guard left.hit(), let self, self.meltGen == gen, self.melting else { return }
                self.melting = false
                self.userIdle = true
                self.changed()
            }
        }
    }

    /// Input is back (or Modo ambiente turned on): cancels a running melt and restarts the snow from the top edge, like the intro.
    func wake() {
        meltGen += 1
        melting = false
        userIdle = false
        overlays().forEach { $0.resume() }
        changed()
    }
}
