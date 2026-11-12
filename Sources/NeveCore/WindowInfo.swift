// AGENT HEADER - Sources/NeveCore/WindowInfo.swift  (window snapshot model, drag tracking, poll scheduling)
// Role: `WindowInfo` (number, frame in GLOBAL AppKit y-up pt, corner radius, occluderOnly; number 0 = Dock bar), `appKitFrame(fromCG:primaryHeight:)` (CG top-left -> AppKit y-up; the flip is its own inverse), `RawWindow` (plain window-server entry) + `filterWindows` (classification via
//   classifyWindows, own-pid/exclude removal, alpha > 0.3, scene mode keeps ONLY the scene windows), `mostlyOffscreen` (show-desktop slivers count as gone; < 30 % visible), `dragTarget` (the unique window whose move matches the mouse's over the SAME interval, tol max(8, 30 %)),
//   `dragPlausible` (press in a title strip 60 pt / edge band 8 pt, or Command held), `DragTracker` (target/exempt state machine: pinned at screen edges, exempt keeps a dragged-offscreen window's snow), `PollReasons`, `PollScheduler` (pure cadence of window reads: minGap 1/30 s,
//   ~20 Hz bursts after a transition until guardTime 0.25 s + 2 identical snapshots or hardCap 1.5 s, ~25 Hz while dragging, settle tail after release, safety 2 s / 5 s after 10 s quiet, retry on failed reads) and `coversScreen` (fullscreen-app test incl. notch inset).
// The app (Sources/Neve/main.swift) is the only driver: it asks `nextDue`, sleeps via a Timer, calls `take`, performs the read and reports `didRead`. Everything here is pure and unit-tested (PollSchedulerTests, WindowClassTests, ConversionTests, EntryRhythmTests, SceneTests).

import CoreGraphics
import Foundation

public struct WindowInfo: Equatable, Sendable {
    public let number: Int     // 0 = Dock bar
    public let frame: CGRect   // global AppKit coordinates (y up)
    public var radius: CGFloat = Tuning.defaultWindowRadius
    public var occluderOnly = false   // a floating panel / HUD: hides piles and flakes but holds no snow of its own
    public init(number: Int, frame: CGRect, radius: CGFloat = Tuning.defaultWindowRadius, occluderOnly: Bool = false) {
        self.number = number; self.frame = frame; self.radius = radius; self.occluderOnly = occluderOnly
    }
}

/// CG (origin top-left of primary screen, y down) -> AppKit (y up).
public func appKitFrame(fromCG r: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(x: r.minX, y: primaryHeight - r.minY - r.height, width: r.width, height: r.height)
}

/// One raw window-server entry as plain values (nil = key missing). `alpha` defaults to 1 when absent.
public struct RawWindow {
    public var number: Int?, pid: Int?, layer: Int?
    public var alpha: Double
    public var bounds: CGRect?   // CG coordinates
    public var owner: String?, title: String?   // owner name needs no permission; the title is empty without Screen Recording
    public init(number: Int?, pid: Int?, layer: Int?, alpha: Double = 1, bounds: CGRect?, owner: String? = nil, title: String? = nil) {
        self.number = number; self.pid = pid; self.layer = layer; self.alpha = alpha; self.bounds = bounds; self.owner = owner; self.title = title
    }
}

/// Keeps layer-0 (plus other window levels, see `classifyWindows`: floating panels become surfaces or occluder-only), visible (alpha > 0.3: a window fading out on close stops holding snow early), at-least-40x20 windows (Neve's own normal windows such as Ajustes included; only `exclude`, the overlay panels, is dropped); converts bounds to AppKit coordinates. Order preserved.
/// Scene mode (`NEVE_SCENE`): `scene` holds the window numbers of Neve's own scene windows; then ONLY those are kept (own pid or not),
/// so the overlay and every other app stay out of the picture.
public func filterWindows(_ raw: [RawWindow], exclude: Set<Int> = [], primaryHeight: CGFloat, radius: CGFloat = Tuning.defaultWindowRadius, scene: Set<Int>? = nil, ownPID: Int? = nil, screens: [CGRect] = []) -> [WindowInfo] {
    let kinds = classifyWindows(raw, ownPID: scene == nil ? ownPID : nil, screens: scene == nil ? screens : [])   // scene mode: only the scene windows, no other levels
    return raw.indices.compactMap { i in
        let w = raw[i]
        guard kinds[i] != .ignore, w.alpha > 0.3, let number = w.number, !exclude.contains(number), scene?.contains(number) ?? true, let r = w.bounds,
              kinds[i] == .occluder || (r.width >= 40 && r.height >= 20) else { return nil }
        return WindowInfo(number: number, frame: appKitFrame(fromCG: r, primaryHeight: primaryHeight), radius: radius, occluderOnly: kinds[i] == .occluder)
    }
}

/// Show-desktop ("click wallpaper") slides windows off the screen edge, leaving a sliver that CGWindowList still reports on-screen.
/// True when less than `minVisible` of the frame's area lies on any screen: such a window counts as gone, so its pile falls.
public func mostlyOffscreen(_ frame: CGRect, screens: [CGRect], minVisible: CGFloat = 0.3) -> Bool {
    let area = frame.width * frame.height
    guard area > 0, !screens.isEmpty else { return false }
    let seen = screens.reduce(CGFloat(0)) { acc, s in
        let i = frame.intersection(s)
        return i.isNull ? acc : acc + i.width * i.height
    }
    return seen / area < minVisible
}

/// The window the user is dragging: the unique one that moved by what the mouse moved over the SAME interval (global points,
/// |Δwindow − Δmouse| < `tol`), at a constant size. Zero or several compatible windows -> nil (no extrapolation, no exemptions).
/// The default tolerance grows with the mouse's own delta (a fast drag lags / leads the window by a fraction of it): 8 pt or 30 % of the delta.
public func dragTarget(prev: [WindowInfo], cur: [WindowInfo], mouseDelta: CGVector, tol: CGFloat? = nil) -> Int? {
    let tol = tol ?? max(8, 0.3 * hypot(mouseDelta.dx, mouseDelta.dy))
    var found: Int?
    for w in cur where w.number > 0 {
        guard let p = prev.first(where: { $0.number == w.number }),
              abs(p.frame.width - w.frame.width) < 0.5, abs(p.frame.height - w.frame.height) < 0.5 else { continue }
        let dx = w.frame.minX - p.frame.minX, dy = w.frame.minY - p.frame.minY
        guard abs(dx) > 0.5 || abs(dy) > 0.5, hypot(dx - mouseDelta.dx, dy - mouseDelta.dy) < tol else { continue }
        if found != nil { return nil }
        found = w.number
    }
    return found
}

/// Whether a press at `p` could start a window drag or resize: inside a window's top strip (title bar / toolbar) or on its edge band; with ⌘ held (⌘-drag moves a window from anywhere in it) anywhere inside a window.
/// Anything else (text selection in a window body, a click on the desktop) is no reason to poll the window list while the button is held.
public func dragPlausible(at p: CGPoint, windows: [WindowInfo], titleStrip: CGFloat = 60, edge: CGFloat = 8, command: Bool = false) -> Bool {
    windows.contains { w in
        w.number > 0 && w.frame.insetBy(dx: -edge, dy: -edge).contains(p)
            && (command || p.y >= w.frame.maxY - titleStrip || !w.frame.insetBy(dx: edge, dy: edge).contains(p))
    }
}

/// The dragged window and the "exempt from show-desktop" window, one source of truth for the poll. The target is the window whose move matched
/// the mouse's (see `dragTarget`); it is kept until the button is released unless ANOTHER window clearly matches; it is suspended while the window stands still under a moving mouse (pinned at an edge) and resumes when it moves again. The exempt window
/// (dragged mostly off screen on purpose: it keeps its snow) is cleared by a press outside it, when it is mostly back on screen, or when it is gone.
public struct DragTracker: Sendable {
    public private(set) var target: Int?, exempt: Int?
    private var pinned: Int?   // the held target while the window is not following the mouse
    private var stillReads = 0  // consecutive reads with the mouse moving and the target not (one can be a stale window-server frame)
    public init() {}

    public mutating func pressed(at p: CGPoint, windows: [WindowInfo]) {
        if let e = exempt, !(windows.first { $0.number == e }?.frame.contains(p) ?? false) { exempt = nil }
    }

    /// One window read. `moved` = some frame changed since `prev`; `mouseDelta` = mouse movement over the same interval.
    public mutating func read(down: Bool, moved: Bool, prev: [WindowInfo], cur: [WindowInfo], mouseDelta: CGVector, screens: [CGRect]) {
        if !down { target = nil; pinned = nil; stillReads = 0 }
        else if moved, let d = dragTarget(prev: prev, cur: cur, mouseDelta: mouseDelta) { target = d; pinned = nil; exempt = d; stillReads = 0 }
        else if let t = target ?? pinned, let p = prev.first(where: { $0.number == t }), let c = cur.first(where: { $0.number == t }),
                abs(c.frame.minX - p.frame.minX) < 0.5, abs(c.frame.minY - p.frame.minY) < 0.5, hypot(mouseDelta.dx, mouseDelta.dy) > 8 {
            // The mouse moved but the window did not (stopped at the menu bar / a screen edge): no pile offset until it moves again.
            // Two reads in a row: the window server can hand back the same frame once during a fast drag.
            stillReads += 1
            if stillReads >= 2 { pinned = t; target = nil }
        } else { stillReads = 0 }
        if let e = exempt {
            if let w = cur.first(where: { $0.number == e }), mostlyOffscreen(w.frame, screens: screens) { return }
            exempt = nil
        }
    }
}

public struct PollReasons: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let windows = PollReasons(rawValue: 1), dock = PollReasons(rawValue: 2), geometry = PollReasons(rawValue: 4)
}

/// Pure cadence of window reads. Everything funnels through here: at most one read per `minGap` (30/s cap), whoever asks.
/// Idle: only explicit requests (events, the 2 s safety poll). A transition (AX event, app activate / hide / launch, Space change,
/// click on the desktop) starts a ~20 Hz burst that ends after a `guardTime` AND two identical snapshots in a row, or at `hardCap`.
/// A drag (a frame moved while the button is held) samples at ~25 Hz for as long as movement continues; releasing runs the settle tail.
/// The caller asks `nextDue`, sleeps until then, calls `take`, performs the read and reports it with `didRead`.
public struct PollScheduler: Sendable {
    public static let minGap = 1.0 / 30, burstGap = 0.05, dragGap = 0.04, guardTime = 0.25, hardCap = 1.5, maxRetries = 3
    public private(set) var pending: PollReasons = []
    public private(set) var held = false, dragging = false
    private var plausible = true, extraAt: Double?
    private var lastRead = -Double.infinity, burstStart = -Double.infinity, burstOn = false, identical = 0, failures = 0, lastEvent: Double?
    public static let safetyGap = 2.0, safetyGapQuiet = 5.0, quietAfter = 10.0
    public init() {}

    public mutating func request(_ r: PollReasons) { pending.formUnion(r) }

    /// Fresh baseline: the burst clock and the identical-snapshot count restart.
    public mutating func transition(now: Double) { lastEvent = now; pending.insert(.windows); burstStart = now; burstOn = true; identical = 0 }

    /// Period of the safety poll: 2 s, stretched to 5 s once Accessibility is active and nothing (AX event, activation, Space change...) called
    /// `transition` for 10 s; the next event brings it back to 2 s. The first call starts the quiet clock.
    public mutating func safetyInterval(now: Double, ax: Bool) -> Double {
        let last = lastEvent ?? now
        lastEvent = last
        return ax && now - last >= Self.quietAfter ? Self.safetyGapQuiet : Self.safetyGap
    }

    /// One extra read `settleDelay` after a minimize / hide / close / zoom: the animation outlasts the burst, and a window that went missing is only knocked off (its snow falls) by a read at least `Tuning.goneGrace` after the one that
    /// first missed it, so the delay is grace + margin; without it the snow would hang in the air until the safety poll (up to ~2.6 s).
    public static let settleDelay = Tuning.goneGrace + 0.25
    public mutating func settleRead(now: Double) { extraAt = now + Self.settleDelay }

    /// `dragPlausible`: the press could start a window drag; if not, held-button movement asks for no reads until a frame actually moves.
    public mutating func mouseDown(now: Double, onDesktop: Bool, dragPlausible: Bool = true) {
        held = true
        plausible = dragPlausible
        if onDesktop { transition(now: now) } else { request(.windows) }
    }
    public mutating func mouseDragged() { if held, plausible || dragging { request(.windows) } }
    public mutating func mouseUp(now: Double, onDesktop: Bool) {
        held = false
        if dragging { dragging = false; transition(now: now) }
        else if onDesktop { transition(now: now) } else { request(.windows) }
    }

    public func burstActive(now: Double) -> Bool {
        dragging || (burstOn && now - burstStart < Self.hardCap && !(now - burstStart >= Self.guardTime && identical >= 2))
    }

    /// Earliest time the next read may run; nil = nothing wanted.
    public func nextDue(now: Double) -> Double? {
        var want = Double.infinity
        if !pending.isEmpty { want = lastRead + Self.minGap }
        if burstActive(now: now) { want = min(want, lastRead + (dragging ? Self.dragGap : Self.burstGap)) }
        if let e = extraAt { want = min(want, e) }
        return want < .infinity ? max(want, lastRead + Self.minGap) : nil
    }

    /// The reasons to act on now (a burst tick always reads the windows), or nil if not yet due.
    public mutating func take(now: Double) -> PollReasons? {
        guard let due = nextDue(now: now), now >= due - 0.0005 else { return nil }
        var r = pending
        if burstActive(now: now) { r.insert(.windows) }
        if let e = extraAt, now >= e - 0.0005 { r.insert(.windows); extraAt = nil }
        pending = []; lastRead = now
        return r
    }

    /// `ok` false = CGWindowList failed (not an empty list): keep the last snapshot and retry a few times.
    /// `changed` = differs from the previous snapshot; `frameMoved` = some window's frame changed (same id).
    public mutating func didRead(ok: Bool, changed: Bool, frameMoved: Bool) {
        guard ok else {
            failures += 1
            if failures <= Self.maxRetries { pending.insert(.windows) } else { failures = 0 }
            return
        }
        failures = 0
        identical = changed ? 0 : identical + 1
        if held, frameMoved { dragging = true }
        else if dragging, held, identical >= 3 { dragging = false }   // stopped moving mid-hold: back to events only
    }
}

/// A window (AppKit coords) covers the screen when it holds the whole frame (1pt slack) or, on a notched display, the frame minus the
/// camera housing: a fullscreen app lives below the notch band (`notchTop` = safeAreaInsets.top). A zoomed window ends at `visible`'s
/// top (below the menu bar) and fills `visible`: with `visible` given, a window that is not taller than it is never fullscreen.
public func coversScreen(_ r: CGRect, frame: CGRect, notchTop: CGFloat, visible: CGRect? = nil) -> Bool {
    let slack = r.insetBy(dx: -1, dy: -1)
    if slack.contains(frame) { return true }
    guard notchTop > 0, slack.contains(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - notchTop)),
          r.maxY >= frame.maxY - notchTop - 1, r.maxY <= frame.maxY - notchTop + 1 else { return false }
    // A zoomed window fills the visible frame (its top is the menu bar's bottom, which can sit at the notch line): not fullscreen.
    // ponytail: a fullscreen app whose visibleFrame also excludes the notch band looks the same; the caller's settle/fullscreen state covers it.
    if let v = visible, abs(r.maxY - v.maxY) <= 1, abs(r.minY - v.minY) <= 1, abs(r.width - v.width) <= 2 { return false }
    return true
}
