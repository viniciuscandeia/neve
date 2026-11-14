// AGENT HEADER - Sources/NeveLabCore/LabWorld.swift  (the Neve Lab world model: a deterministic virtual desktop driving one SnowField like the app does)
// Role: `LabConfig` (screen 1280x800 pt, scale 1, light or dark (`dark`, start value), a virtual bottom Dock (`dock`, `dockIcons`), silent audio, fixed calendar day, ONE seed -> SnowField's seeds, prefs) and `LabWorld` (final class): virtual windows in z-order (front first), virtual cursor / left button / Option, `InteractionPolicy`,
//   fixed 1/60 s steps (`advance`), `apply(_ actionJSON:) throws -> String` (strict JSON actions, see `actionKeys`; any invalid action throws BEFORE touching the world) and `state() -> String` (canonical JSON, read-only), `digest()` (hash of the observable + inner state, for determinism tests),
//   `restarted()` (new world, same config + seed), `prepareFrame` (placeholder for the renderer, see below), `package let field` (for the future renderer / tests; never mutate it from outside).
// Coordinates: commands and state use IMAGE coordinates (origin top-left, y down, pt). `Coords` is the ONLY place that flips to the simulation's y-up AppKit coordinates (the screen origin is (0,0), so global == local).
// Time: the world is frozen between commands. A step = `field.step(dt: 1/60)`; step n runs at time n/60. `advance` / timed moves (`duration`, rounded to whole steps) run steps; instant commands run none. No wall clock anywhere.
// Per step (mirrors Overlay.tick order): [poll windows if dirty or every 2nd step ~30 Hz] -> cursor/button input (policy.tick: sweep, pointer, optionHeld, drop rules) -> field.step -> step += 1 -> prepareFrame?(step).
// Window poll mirrors AppController.pollWindows (Sources/Neve/WindowPoller.swift) + WindowList.swift: minimized windows are not "on screen"; RawWindow list (CG = image coords) -> NeveCore `filterWindows` (>= 40x20, alpha > 0.3, conversion to y-up) -> DragTracker.read (mouse delta since the previous read) ->
//   `mostlyOffscreen` windows removed unless exempt -> `behindWindows` pref => no surfaces (windows = []) -> [Dock rect = WindowInfo number 0 inserted FIRST (glass rect from the AX list rect via Tuning.dockGlass, radius height*0.3; not when `behindWindows`) like WindowPoller.pollWindows] -> fullscreen test (`coversScreen`) skips the update like Overlay -> field.setDragTarget + field.update(windows:now:).
//   Differences from the app: polls at a fixed 30 Hz instead of PollScheduler's bursts / 2 s safety poll; no Mission Control gate; no Space / stale protocol; no DockWatcher (AX read, DockDebounce, animation settling: the Dock rect is exact and changes instantly, the sim eases its ends at Tuning.dockSpeed); no CompactState / coverage compaction of the app (Overlay.measureCover); under a fullscreen window the sim keeps stepping (the app pauses the link); drag pile shift (render-only) not modelled.
// Dock (VDock): floating bar 84 pt tall, glass 5 pt above the screen bottom (AX list 10 pt, macOS 26 offset fixed), width 20 + 58 pt per icon (max screen-40), ground raised to `VDock.ground` 85 pt (calibration knob for visibleFrame.minY) via field.setBounds (piles kept). Actions `set_dock {position bottom|none, icons}` and `set_appearance {light|dark}`; state has "dock" {position, icons, frame, ground} and screen.appearance. Appearance never touches the sim (the lab adapter applies it to the global Palette).
// Preparation commands (`fill_pile`, `drop_tree`, `set_dock`, `set_appearance`) return "preparation": true; they use package-only NeveCore helpers (LabAccess.swift), never arbitrary writes.
// Renderer note (plan): `Pile.shown` easing is mutated by SnowField.writePiles(dt:) -> frame data must be prepared ONCE per canonical step (in `prepareFrame`) and reused by every capture; capture must never step physics or call writePiles again.
// The policy is the app's own (NeveCore/InteractionPolicy.swift; remaining differences listed there). Tests: Tests/NeveLabCoreTests.

import CoreGraphics
import Foundation
import NeveCore

public struct LabConfig: Equatable {
    public var width = 1280.0, height = 800.0
    public var menuBar = 24.0              // pt at the top outside the visible frame (visibleTop = height - menuBar); the ground is the screen bottom without a Dock, `dockGround` above it with one
    public var dock = true                 // a floating bottom Dock bar (macOS 26 look), like a real Mac; false = none ("--dock none")
    public var dockIcons = 12              // bar width follows the icon count (`dockWidth`)
    public var dark = false                // appearance at start (the lab process applies it to the global Palette, see LabAdapter)
    public var seed: UInt64 = 1
    public var month = 6, day = 15         // fixed calendar day (sleigh frequency); not December by default
    public var windowRadius = Double(Tuning.defaultWindowRadius)
    public var prefs: [Pref: Bool] = [:]   // overrides of Pref.defaultValue
    public var intensity = Intensity.media
    public init() {}
}

/// The one place where image coordinates (top-left origin, y down) become simulation coordinates (y up) and back.
struct Coords {
    let height: CGFloat
    func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: height - p.y) }   // its own inverse
    func rect(_ r: CGRect) -> CGRect { appKitFrame(fromCG: r, primaryHeight: height) }   // its own inverse
    func y(_ v: Float) -> Double { Double(height) - Double(v) }
}

/// Virtual Dock geometry (macOS 26, measured: AX list 84 pt tall with 10 pt under it, glass 5 pt lower, `Tuning.dockGlass`; visibleFrame.minY above the glass bottom: `ground` is a calibration knob).
enum VDock {
    static let height = 84.0, gapBelow = 10.0, ground = 85.0, slot = 58.0, pad = 20.0, maxIcons = 60
    static func width(icons: Int, screen: Double) -> Double { min(pad + Double(icons) * slot, screen - 40) }
    /// Glass rect in image coordinates (y down), derived from the AX list rect exactly like the app (Dock.swift queryDockBar: Tuning.dockGlass(fromAX:)); the OS version is fixed to 26 so the lab is machine independent.
    static func glass(icons: Int, w: Double, h: Double) -> CGRect {
        let bw = width(icons: icons, screen: w)
        return Tuning.dockGlass(fromAX: CGRect(x: (w - bw) / 2, y: h - gapBelow - height, width: bw, height: height), for: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
    }
}

struct VWindow: Equatable {
    var id: Int
    var title: String
    var frame: CGRect   // image coordinates
    var minimized = false
}

public final class LabWorld {
    public static let dt: Float = 1.0 / 60
    static let pollEvery = 2, maxWindows = 30, maxAdvance = 216_000   // 30 Hz polls; one hour of steps per command

    public let config: LabConfig
    package let field: SnowField
    public private(set) var step = 0
    /// Placeholder for the renderer: called once at the end of every canonical step with the new step number (prepare frame data here, never in capture).
    public var prepareFrame: ((Int) -> Void)?

    private let coords: Coords
    private var windows: [VWindow] = []   // front to back
    private var nextID = 1
    private var cursor: CGPoint            // image coordinates
    private var buttonDown = false, option = false, windowDrag = false
    private var policy = InteractionPolicy()
    private var tracker = DragTracker()
    private var lastRead: [WindowInfo] = [], lastReadMouse = CGPoint.zero
    private var dirty = true
    private var flags: [Pref: Bool]
    private var intensity: Intensity
    private var lastPress = "none"
    private var dockOn: Bool, dockIcons: Int
    public private(set) var dark: Bool

    public init(config: LabConfig = LabConfig()) {
        self.config = config
        let w = CGFloat(config.width), h = CGFloat(config.height)
        coords = Coords(height: h)
        let area = Float(w * h) / (1440 * 900)
        field = SnowField(size: CGSize(width: w, height: h), origin: .zero, groundY: config.dock ? CGFloat(VDock.ground) : 0, visibleTop: h - CGFloat(config.menuBar),
                          flakeCount: max(120, Int(Float(Tuning.flakes) * area)), config: SimConfig(), seed: config.seed)
        field.calendarDay = (config.month, config.day)
        flags = config.prefs
        dockOn = config.dock; dockIcons = config.dockIcons; dark = config.dark
        intensity = config.intensity
        cursor = CGPoint(x: w / 2, y: h / 2)
        applyPrefs()
    }

    /// A new world with the same configuration and seed (nothing of this one carries over).
    public func restarted() -> LabWorld { LabWorld(config: config) }

    private func pref(_ p: Pref) -> Bool { flags[p] ?? p.defaultValue }

    /// Same wiring as Overlay.apply (only what the simulation reads).
    private func applyPrefs() {
        let p = OverlayPrefs { self.pref($0) }
        field.snowmanEnabled = p.snowman; field.walkEnabled = p.walk; field.pointerPush = p.pointerPush
        field.visitorsEnabled = p.visitors; field.sleighEnabled = p.sleigh; field.treeEnabled = p.tree; field.lightsEnabled = p.lights
        field.groundOnlyActors = p.behind; field.economy = p.economy
        field.setIntensity(intensity)
    }

    // MARK: time

    private var now: Double { Double(step) * Double(Self.dt) }

    private func stepOnce() {
        if dirty || step % Self.pollEvery == 0 { poll() }
        let core = coords.point(cursor)
        policy.tick(cursor: core, option: option, buttonDown: buttonDown, realDt: Double(Self.dt), resumed: step == 0, screen: CGSize(width: config.width, height: config.height), on: field)
        field.step(dt: Self.dt)
        step += 1
        prepareFrame?(step)
    }

    // MARK: windows

    private var screenRect: CGRect { CGRect(x: 0, y: 0, width: config.width, height: config.height) }
    private var groundY: Double { dockOn ? VDock.ground : 0 }
    private var visibleRect: CGRect { CGRect(x: 0, y: groundY, width: config.width, height: config.height - config.menuBar - groundY) }   // like screen.visibleFrame (y-up)
    private var dockGlass: CGRect? { dockOn ? VDock.glass(icons: dockIcons, w: config.width, h: config.height) : nil }   // image coordinates

    /// One window read, mirroring AppController.pollWindows (see the file header).
    private func poll() {
        dirty = false
        let raw = windows.filter { !$0.minimized }.map { RawWindow(number: $0.id, pid: 1, layer: 0, bounds: $0.frame) }   // CG coordinates == image coordinates
        let read = filterWindows(raw, primaryHeight: coords.height, radius: CGFloat(config.windowRadius))
        let mouse = coords.point(cursor)
        let moved = buttonDown && read.contains { w in lastRead.first { $0.number == w.number }.map { $0.frame != w.frame } ?? false }
        tracker.read(down: buttonDown, moved: moved, prev: lastRead, cur: read, mouseDelta: CGVector(dx: mouse.x - lastReadMouse.x, dy: mouse.y - lastReadMouse.y), screens: [screenRect])
        lastRead = read; lastReadMouse = mouse
        var list = read
        list.removeAll { $0.number != tracker.exempt && mostlyOffscreen($0.frame, screens: [screenRect]) }
        let covering = list.map(\.frame)
        if pref(.behindWindows) { list = [] }   // snow falls behind app windows: no surfaces, no Dock pile
        else if let d = dockGlass { let r = coords.rect(d); list.insert(WindowInfo(number: 0, frame: r, radius: r.height * 0.3), at: 0) }   // Dock draws above windows (WindowPoller.pollWindows)
        if covering.contains(where: { coversScreen($0, frame: screenRect, notchTop: 0, visible: visibleRect) }) { return }   // fullscreen app: piles untouched
        field.setDragTarget(tracker.target)
        field.update(windows: list, now: now)
    }

    private func index(_ id: Int) throws -> Int {
        guard let i = windows.firstIndex(where: { $0.id == id }) else { throw LabError("no window with id \(id)") }
        return i
    }

    /// Runs `n` steps; `each(i/n)` (0 < f <= 1) positions things before step i. n == 0 does nothing.
    private func timed(_ n: Int, _ each: (Double) -> Void) {
        guard n > 0 else { return }
        for i in 1...n { each(i == n ? 1 : Double(i) / Double(n)); stepOnce() }
    }

    private func steps(for seconds: Double?) throws -> Int {
        guard let s = seconds else { return 0 }
        guard s >= 0, s <= 3600 else { throw LabError("\"duration\" must be 0...3600 seconds") }
        return Int((s * 60).rounded())
    }

    private func lerp(_ a: CGRect, _ b: CGRect, _ f: Double) -> CGRect {
        f >= 1 ? b : CGRect(x: a.minX + (b.minX - a.minX) * f, y: a.minY + (b.minY - a.minY) * f, width: a.width + (b.width - a.width) * f, height: a.height + (b.height - a.height) * f)
    }

    /// Moves / resizes window `id` to `to`, instantly or over `n` steps; `grab` = the cursor holds its title bar and follows (a real window drag).
    private func setFrame(_ id: Int, to: CGRect, steps n: Int, grab: Bool) throws {
        let from = windows[try index(id)].frame
        func put(_ f: CGRect) { if let i = windows.firstIndex(where: { $0.id == id }) { windows[i].frame = f; dirty = true } }
        guard n > 0 else { put(to); poll(); return }
        var start = cursor
        if grab {
            start = CGPoint(x: from.midX, y: from.minY + min(15, from.height / 2))
            cursor = start; buttonDown = true; windowDrag = true
            tracker.pressed(at: coords.point(start), windows: lastRead)
        }
        timed(n) { f in
            let r = lerp(from, to, f); put(r)
            if grab { cursor = CGPoint(x: start.x + r.minX - from.minX, y: start.y + r.minY - from.minY) }
        }
        if grab { buttonDown = false; windowDrag = false; policy.buttonUp(now: now, on: field) }
    }

    // MARK: actions

    static let actionKeys: [String: Set<String>] = [
        "create_window": ["id", "title", "x", "y", "w", "h"], "move_window": ["id", "x", "y", "duration", "drag"], "resize_window": ["id", "w", "h", "duration"],
        "minimize_window": ["id"], "restore_window": ["id"], "close_window": ["id"], "raise_window": ["id"], "lower_window": ["id"],
        "cursor_move": ["x", "y", "duration"], "mouse_down": [], "mouse_up": [], "option_down": [], "option_up": [],
        "advance": ["steps", "seconds"], "fill_pile": ["surface", "height"], "drop_tree": ["replacing"], "set_pref": ["pref", "value"], "set_intensity": ["level"], "set_dock": ["position", "icons"], "set_appearance": ["appearance"],
    ]
    static let preparation: Set<String> = ["fill_pile", "drop_tree", "set_dock", "set_appearance"]

    /// Executes one JSON action. Invalid actions throw `LabError` and leave the world exactly as it was (every check precedes the first mutation).
    @discardableResult
    public func apply(_ actionJSON: String) throws -> String {
        let a = try Args(json: actionJSON, allowed: Self.actionKeys)
        var out: [String: Any] = [:]
        let before = step
        switch a.type {
        case "create_window":
            guard windows.count < Self.maxWindows else { throw LabError("at most \(Self.maxWindows) windows") }
            let id = a.has("id") ? try a.int("id") : nextID
            guard id > 0 else { throw LabError("\"id\" must be > 0") }
            guard !windows.contains(where: { $0.id == id }) else { throw LabError("window id \(id) exists") }
            let f = try frame(a, x: a.double("x"), y: a.double("y"))
            let title = try a.string("title")
            guard title.count <= 200 else { throw LabError("\"title\" too long") }
            windows.insert(VWindow(id: id, title: title, frame: f), at: 0)
            nextID = max(nextID, id + 1); dirty = true; poll()
            out["id"] = id
        case "move_window":
            let id = try a.int("id"), i = try index(id), n = try steps(for: a.optDouble("duration")), drag = try a.bool("drag", or: false)
            let f = windows[i].frame, to = try frame(a, x: a.double("x"), y: a.double("y"), w: f.width, h: f.height)
            if drag {
                guard n > 0 else { throw LabError("drag needs a \"duration\" > 0") }
                guard !windows[i].minimized else { throw LabError("window \(id) is minimized") }
                guard !buttonDown, !option else { throw LabError("drag needs the button and Option up") }
            }
            try setFrame(id, to: to, steps: n, grab: drag)
        case "resize_window":
            let id = try a.int("id"), i = try index(id), n = try steps(for: a.optDouble("duration"))
            let f = windows[i].frame
            try setFrame(id, to: frame(a, x: f.minX, y: f.minY, w: a.double("w"), h: a.double("h")), steps: n, grab: false)
        case "minimize_window": try setMin(a.int("id"), true)
        case "restore_window": let id = try a.int("id"); try setMin(id, false); let w = windows.remove(at: try index(id)); windows.insert(w, at: 0)
        case "close_window": windows.remove(at: try index(a.int("id"))); dirty = true; poll()
        case "raise_window": let w = windows.remove(at: try index(a.int("id"))); windows.insert(w, at: 0); dirty = true; poll()
        case "lower_window": let w = windows.remove(at: try index(a.int("id"))); windows.append(w); dirty = true; poll()
        case "cursor_move":
            let to = CGPoint(x: try a.double("x"), y: try a.double("y")), n = try steps(for: a.optDouble("duration"))
            let from = cursor
            func place(_ p: CGPoint) {
                cursor = p
                if buttonDown { policy.mouseDragged(to: coords.point(p), now: now, on: field) }
            }
            if n == 0 { place(to) } else {
                timed(n) { f in place(f >= 1 ? to : CGPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f)) }
            }
        case "mouse_down":
            guard !buttonDown else { throw LabError("button already down") }
            buttonDown = true
            tracker.pressed(at: coords.point(cursor), windows: lastRead)
            let r = policy.mouseDown(at: coords.point(cursor), option: option, now: now, on: field)
            switch r {
            case .passThrough: out["outcome"] = "passThrough"
            case .gift: out["outcome"] = "gift"
            case .tree: out["outcome"] = "tree"
            case .ball(let id): out["outcome"] = "ball"; out["ball"] = id
            case .scoop(let id): out["outcome"] = "scoop"; out["ball"] = id
            case .nothing: out["outcome"] = "nothing"
            }
            lastPress = out["outcome"] as? String ?? "none"
        case "mouse_up":
            guard buttonDown else { throw LabError("button is not down") }
            buttonDown = false
            policy.buttonUp(now: now, on: field)
        case "option_down": option = true
        case "option_up": option = false
        case "advance":
            guard a.has("steps") != a.has("seconds") else { throw LabError("give exactly one of \"steps\" / \"seconds\"") }
            let n = a.has("steps") ? try a.int("steps") : try steps(for: a.double("seconds"))
            guard n >= 0, n <= Self.maxAdvance else { throw LabError("steps must be 0...\(Self.maxAdvance)") }
            timed(n) { _ in }
        case "fill_pile":
            let id: Int
            if let name = a.d["surface"] as? String {
                guard name == "ground" else { throw LabError("\"surface\" must be \"ground\" or a window id") }
                id = SnowField.labGroundID
            } else { id = try a.int("surface") }
            let h = try a.double("height")
            guard h >= 0, h <= 1000 else { throw LabError("\"height\" must be 0...1000") }
            guard field.labFill(surface: id, height: Float(h)) else { throw LabError("no snow surface \(id)") }
            out["surface"] = id
        case "drop_tree":
            guard field.dropTree(replacing: try a.bool("replacing", or: false)) else { throw LabError("tree drop refused (disabled, snow leaving or a tree exists)") }
        case "set_pref":
            let name = try a.string("pref")
            guard let p = Pref(rawValue: name) else { throw LabError("unknown pref \"\(name)\"") }
            guard a.has("value") else { throw LabError("missing \"value\"") }
            flags[p] = try a.bool("value", or: false); applyPrefs(); dirty = true
        case "set_intensity":
            let l = try a.string("level")
            guard let i = Intensity.allCases.first(where: { String(describing: $0) == l }) else { throw LabError("level must be leve|media|forte|nevasca") }
            intensity = i; applyPrefs()
        case "set_dock":
            let pos = try a.string("position")
            guard pos == "bottom" || pos == "none" else { throw LabError("\"position\" must be bottom|none") }
            let n = a.has("icons") ? try a.int("icons") : dockIcons
            guard n >= 1, n <= VDock.maxIcons else { throw LabError("\"icons\" must be 1...\(VDock.maxIcons)") }
            dockOn = pos == "bottom"; dockIcons = n
            field.setBounds(groundY: CGFloat(groundY), visibleTop: CGFloat(config.height - config.menuBar))   // like Overlay.refreshBounds when visibleFrame changes: piles kept
            dirty = true; poll()
        case "set_appearance":
            let v = try a.string("appearance")
            guard v == "light" || v == "dark" else { throw LabError("\"appearance\" must be light|dark") }
            dark = v == "dark"
        default: throw LabError("unknown action type")
        }
        out["ok"] = true; out["type"] = a.type; out["step"] = step; out["stepsRun"] = step - before; out["preparation"] = Self.preparation.contains(a.type)
        return canonicalJSON(out)
    }

    private func setMin(_ id: Int, _ on: Bool) throws {
        windows[try index(id)].minimized = on; dirty = true; poll()
    }

    /// Validates a frame (image coordinates, at most 20000 pt wide / tall, positive size).
    private func frame(_ a: Args, x: Double, y: Double, w: Double? = nil, h: Double? = nil) throws -> CGRect {
        let w = try w ?? a.double("w"), h = try h ?? a.double("h")
        guard w >= 1, h >= 1, w <= 20000, h <= 20000 else { throw LabError("window size must be 1...20000") }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: state

    private func r3(_ v: Float) -> Double { (Double(v) * 1000).rounded() / 1000 }
    private func rect(_ r: CGRect) -> [String: Any] { ["x": r.minX, "y": r.minY, "w": r.width, "h": r.height] }
    private func pt(_ p: SIMD2<Float>) -> [String: Any] { ["x": r3(p.x), "y": r3(Float(coords.y(p.y)))] }

    /// Read-only observable state as canonical JSON (image coordinates). Never changes the world.
    public func state() -> String {
        var s: [String: Any] = ["step": step, "time": now, "screen": ["w": config.width, "h": config.height, "scale": 1, "appearance": dark ? "dark" : "light"], "seed": String(config.seed)]
        s["dock"] = dockGlass.map { ["position": "bottom", "icons": dockIcons, "frame": rect($0), "ground": groundY] as [String: Any] } ?? ["position": "none", "icons": dockIcons, "frame": NSNull(), "ground": groundY] as [String: Any]
        s["windows"] = windows.enumerated().map { ["id": $1.id, "title": $1.title, "frame": rect($1.frame), "minimized": $1.minimized, "z": $0] as [String: Any] }
        s["cursor"] = ["x": cursor.x, "y": cursor.y, "down": buttonDown, "option": option, "interactive": policy.interactive, "windowDrag": windowDrag, "lastPress": lastPress]
        switch policy.held {
        case .ball(let id): s["held"] = ["kind": "ball", "id": id]
        case .tree: s["held"] = ["kind": "tree"]
        case nil: s["held"] = NSNull()
        }
        s["balls"] = field.balls.map { b -> [String: Any] in
            var d = pt(b.pos); d["id"] = b.id; d["r"] = r3(b.radius); d["state"] = String(describing: b.state); d["surface"] = b.surfaceID ?? NSNull(); d["parent"] = b.parent ?? NSNull(); d["melting"] = b.fade < 1
            return d
        }
        s["figures"] = field.figures.map { f -> [String: Any] in
            var d = pt(f.foot); d["id"] = f.id; d["kind"] = String(describing: f.kind); d["phase"] = String(describing: f.phase); d["built"] = f.built; d["headless"] = f.headless; d["fromBalls"] = f.fromBalls
            if case .surface(let sid, _) = f.at { d["surface"] = sid }
            return d
        }
        if let t = field.labTree { var d = pt(t.pos); d["state"] = String(describing: t.state); d["surface"] = t.surface ?? NSNull(); s["tree"] = d } else { s["tree"] = NSNull() }
        s["hasTree"] = field.hasTree
        s["gifts"] = field.gifts.map { g -> [String: Any] in var d = pt(g.pos); d["surface"] = g.surface ?? NSNull(); d["opened"] = g.opened >= 0; return d }
        s["snow"] = field.labSurfaces.map { ["id": $0.id, "volume": r3($0.volume), "maxHeight": r3($0.maxHeight)] as [String: Any] }
        s["pendingGone"] = field.labPending
        s["flakes"] = field.flakes.count; s["debris"] = field.debris.count
        s["prefs"] = Dictionary(uniqueKeysWithValues: Pref.allCases.map { ($0.rawValue, pref($0)) })
        s["intensity"] = String(describing: intensity)
        return canonicalJSON(s)
    }

    /// FNV-1a over the exact bit patterns of the inner simulation state that matters (piles, flakes, debris, balls, figures, tree, gifts) + lab inputs: equal digests = equal worlds, beyond the rounded JSON.
    public func digest() -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        func mix(_ v: UInt64) { h = (h ^ v) &* 0x100000001b3 }
        func mix(_ f: Float) { mix(UInt64(f.bitPattern)) }
        func mix(_ p: SIMD2<Float>) { mix(p.x); mix(p.y) }
        mix(UInt64(step)); mix(UInt64(cursor.x.bitPattern)); mix(UInt64(cursor.y.bitPattern))
        for s in field.labSurfaces { mix(UInt64(bitPattern: Int64(s.id))); for v in s.heights { mix(v) } }
        for f in field.flakes { mix(f.pos) }
        for f in field.debris { mix(f.pos) }
        for b in field.balls { mix(b.pos); mix(b.radius) }
        for f in field.figures { mix(f.foot); mix(UInt64(f.built)) }
        for g in field.gifts { mix(g.pos) }
        if let t = field.labTree { mix(t.pos); mix(t.snow.x) }
        return h
    }
}
