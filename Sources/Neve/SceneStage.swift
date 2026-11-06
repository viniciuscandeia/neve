import AppKit
import NeveCore

/// Scene mode (`NEVE_SCENE=demo`): Neve's own light-neutral windows on the main screen, in front of a plain backdrop that hides whatever
/// the user has open there. Frames follow `DemoScene.windows` by simulation time, so the fast move at 25 s is part of the script.
@MainActor
final class SceneStage {
    private var windows: [NSWindow] = []
    private let backdrop: NSWindow, strip: NSWindow
    private let area: CGRect
    /// Window numbers of the scene windows (the only ones the overlay sees in scene mode).
    var numbers: Set<Int> { Set(windows.map { $0.windowNumber }) }

    init(screen: NSScreen) {
        area = screen.visibleFrame
        // The backdrop covers the visible area; a strip at the Dock's level continues it down over the Dock, so no app icons show.
        let full = CGRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: area.maxY - screen.frame.minY)
        let dockH = area.minY - full.minY
        backdrop = NSWindow(contentRect: area, styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.contentView = Backdrop(frame: CGRect(origin: .zero, size: area.size), full: CGRect(x: 0, y: -dockH, width: area.width, height: full.height))
        let low = CGRect(x: full.minX, y: full.minY, width: full.width, height: dockH)
        strip = NSWindow(contentRect: low, styleMask: .borderless, backing: .buffered, defer: false)
        strip.contentView = Backdrop(frame: CGRect(origin: .zero, size: low.size), full: CGRect(x: 0, y: 0, width: full.width, height: full.height))
        strip.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        strip.isReleasedWhenClosed = false; strip.ignoresMouseEvents = true; strip.hasShadow = false
        strip.collectionBehavior = [.stationary, .ignoresCycle, .canJoinAllSpaces]
        strip.orderFrontRegardless()
        backdrop.isReleasedWhenClosed = false; backdrop.ignoresMouseEvents = true; backdrop.hasShadow = false
        backdrop.collectionBehavior = [.stationary, .ignoresCycle]
        backdrop.orderFrontRegardless()
        for w in DemoScene.windows(in: area, t: 0).reversed() {   // back to front: the first of the list ends up in front
            let win = NSWindow(contentRect: w.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            win.title = w.title
            win.isReleasedWhenClosed = false
            win.contentView = PaperView(frame: CGRect(origin: .zero, size: w.frame.size), terminal: w.title == "Terminal")
            win.collectionBehavior = [.stationary, .ignoresCycle]
            win.setFrame(w.frame, display: true)
            win.orderFrontRegardless()
            windows.append(win)
        }
        windows.reverse()   // front to back, like the frames
    }

    /// Moves every window to where the script wants it at scene time `t` (cheap when nothing changed).
    func place(t: Float) {
        for (win, w) in zip(windows, DemoScene.windows(in: area, t: t)) where win.frame != w.frame { win.setFrame(w.frame, display: true) }
    }

    func close() { windows.forEach { $0.close() }; backdrop.close(); strip.close() }
}

/// A calm winter-dusk backdrop.
private final class Backdrop: NSView {
    let full: CGRect   // the gradient spans this rect (in this view's coordinates), so the strip and the backdrop match
    init(frame: NSRect, full: CGRect) { self.full = full; super.init(frame: frame) }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [NSColor(red: 0.18, green: 0.26, blue: 0.40, alpha: 1), NSColor(red: 0.45, green: 0.58, blue: 0.74, alpha: 1)])?.draw(in: full, angle: 90)
    }
}

/// Neutral stand-in app content: a light page with a sidebar and rows of text bars (a dark one for the "Terminal").
private final class PaperView: NSView {
    let terminal: Bool
    init(frame: NSRect, terminal: Bool) { self.terminal = terminal; super.init(frame: frame) }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        (terminal ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill()
        bounds.fill()
        let ink = terminal ? NSColor(red: 0.55, green: 0.85, blue: 0.6, alpha: 0.85) : NSColor(white: 0.80, alpha: 1)
        let side = min(110, bounds.width * 0.25)
        if !terminal { NSColor(white: 0.92, alpha: 1).setFill(); CGRect(x: 0, y: 0, width: side, height: bounds.height).fill() }
        ink.setFill()
        let x0: CGFloat = terminal ? 16 : side + 18
        var y = bounds.height - 30, k = 0
        while y > 14 {
            let w = (bounds.width - x0 - 24) * [0.9, 0.55, 0.75, 0.35, 0.8, 0.6, 0.45][k % 7]
            NSBezierPath(roundedRect: CGRect(x: x0, y: y, width: max(w, 20), height: 7), xRadius: 3.5, yRadius: 3.5).fill()
            y -= terminal ? 18 : 22; k += 1
        }
    }
}
