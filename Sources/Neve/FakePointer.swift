// AGENT HEADER - Sources/Neve/FakePointer.swift  (NEVE_FAKE_POINTER: scripted cursor for on-screen measurement)
// Role: replaces NSEvent.mouseLocation in Overlay.tick with the same path scripts/cursor-sweep.swift walks (4 s per segment, sinusoidal, peak ~600 pt/s, y wobbling 4..8 pt above the segment),
//   so pointer position + velocity feed field.sweep / snowNear / FrameRate exactly as the real mouse does, without moving the user's cursor. Real clicks/modifiers are still read from NSEvent.
// Env: NEVE_FAKE_POINTER=sweep (perf-suite's piles path: Finder windows at 100,100..700,500 / 760,160..1360,560 and the ground) | void (300,1100,620, empty space) | "x0,x1,y x0,x1,y ..." (CG top-left pt).
// Cost when unset: one branch on a static let (`active`). Callers: Overlay.tick; scripts/perf.sh --fake. Main thread only.
import AppKit

enum FakePointer {
    nonisolated static let active: Bool = ProcessInfo.processInfo.environment["NEVE_FAKE_POINTER"] != nil
    @MainActor private static var t0 = 0.0
    @MainActor private static let top = Double(NSScreen.screens.first?.frame.height ?? 900)
    @MainActor private static let segs: [(Double, Double, Double)] = {
        let spec = ProcessInfo.processInfo.environment["NEVE_FAKE_POINTER"] ?? ""
        let h = Double(NSScreen.screens.first?.frame.height ?? 900)
        let list = spec == "sweep" ? "130,670,100 790,1330,160 120,1320,\(h)" : spec == "void" ? "300,1100,620" : spec
        return list.split(separator: " ").compactMap { s in
            let v = s.split(separator: ",").compactMap { Double($0) }
            return v.count == 3 ? (v[0], v[1], v[2]) : nil
        }
    }()
    /// AppKit global location at `now` (seconds, any monotonic clock).
    @MainActor static func location(now: Double) -> CGPoint {
        guard !segs.isEmpty else { return NSEvent.mouseLocation }
        if t0 == 0 { t0 = now }
        let t = now - t0
        let (x0, x1, y) = segs[Int(t / 4) % segs.count]
        let mid = (x0 + x1) / 2, half = (x1 - x0) / 2
        let x = mid + half * sin(t * 600 / max(half, 1))
        return CGPoint(x: x, y: top - (y - 4 - 4 * sin(t * 3.1)))
    }
}
