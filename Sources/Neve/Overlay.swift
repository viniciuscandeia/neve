import NeveCore
import AppKit
import Metal
import QuartzCore

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;
struct Instance { float2 pos; float size; float alpha; float seed; };
struct VOut { float4 position [[position]]; float2 uv; float alpha; float size; float seed; };
vertex VOut flakeVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                        constant Instance *inst [[buffer(0)]], constant float2 &viewSize [[buffer(1)]]) {
    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    Instance i = inst[iid];
    float2 p = i.pos + corner * i.size * 0.5;
    VOut o;
    o.position = float4(p / viewSize * 2.0 - 1.0, 0.0, 1.0);
    o.uv = corner;
    o.alpha = i.alpha;
    o.size = i.size;
    o.seed = i.seed;
    return o;
}
// White core, cool blue-gray rim: reads on white pages, still looks like snow on dark ones.
// `contrast` (Increase Contrast) = 1 darkens the rim and keeps it opaque.
fragment float4 flakeFragment(VOut in [[stage_in]], constant float &contrast [[buffer(0)]]) {
    float d = length(in.uv);
    // Flakes >= ~5pt: faint 6-fold crystal hint + a little per-flake irregularity. Small ones stay round dots.
    float big = smoothstep(3.5, 5.5, in.size);
    if (big > 0.0) {
        float th = atan2(in.uv.y, in.uv.x) + in.seed * 6.2832;
        float wob = cos(6.0 * th) * 0.13 + cos(3.0 * th + in.seed * 17.0) * 0.07 * fract(in.seed * 7.0);
        d *= 1.0 - big * (wob + 0.04);
    }
    float core = 1.0 - smoothstep(0.1, 0.45, d);
    float3 rim = mix(float3(0.56, 0.65, 0.80), float3(0.40, 0.50, 0.70), contrast);
    float a = (1.0 - smoothstep(0.55, 1.0, d)) * in.alpha;
    return float4(mix(rim, float3(1.0), core) * a, a);
}
"""

/// Shared Metal objects, built once.
private struct Gpu {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: shaderSource, options: nil) else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "flakeVertex")
        d.fragmentFunction = library.makeFunction(name: "flakeFragment")
        let c = d.colorAttachments[0]!
        c.pixelFormat = .bgra8Unorm
        c.isBlendingEnabled = true
        c.sourceRGBBlendFactor = .one
        c.sourceAlphaBlendFactor = .one
        c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
    }
}

/// Content view that hands mouse events to the overlay (only delivered while the window is interactive: ⌥ over snow).
final class InteractView: NSView {
    var onDown: ((NSEvent) -> Void)?, onDrag: ((NSEvent) -> Void)?, onUp: ((NSEvent) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onDown?(event) }
    override func mouseDragged(with event: NSEvent) { onDrag?(event) }
    override func mouseUp(with event: NSEvent) { onUp?(event) }
}

/// The user options an overlay renders; the controller owns them (UserDefaults) and pushes them to every overlay.
struct OverlayPrefs: Equatable {
    var economy = false, behind = false, still = false, snowman = true, walk = true, showInCaptures = false
    var intensity = Intensity.media
}

/// Click-through snow window covering one screen (interactive only while ⌥ is held over snow or a snowball).
@MainActor
final class Overlay: NSObject, CAMetalDisplayLinkDelegate {
    private static let sharedGpu = Gpu()

    let screen: NSScreen
    private let field: SnowField
    private let gpu: Gpu
    private let window: NSWindow
    private let view = InteractView()
    private let ballLayers = BallLayers()
    private let fightLayers = FightLayers()   // thrown snowballs
    private var held: Int?                // snowball being dragged
    private var lastDragTime: CFTimeInterval = 0
    private var piles: PileLayers!
    private var dragPile: PileLayers!   // the pile of a window being dragged: slid with the mouse between polls
    private var pollMouse = NSEvent.mouseLocation
    private var forcePath = false
    private var lastCursor: CGPoint?
    private let metalLayer = CAMetalLayer()
    private let buffers: [MTLBuffer]
    private var bufferIndex = 0
    private let inFlight = DispatchSemaphore(value: 3)
    private var link: CAMetalDisplayLink?
    private let pass = MTLRenderPassDescriptor()   // reused every frame; only the texture changes
    private var run = false, fullscreen = false   // run: the controller's single decision (enabled, awake, not hot, user active)
    private var occluded = false
    private var lowPower = false
    private var contrast: Float = 0
    private let snowmanLayers = SnowmanLayers()
    private var reduceMotion = false
    private var prefs: OverlayPrefs
    private var still = false   // Reduce Motion + "Neve parada": no flakes drawn or stepped, piles kept
    private var lastTimestamp: CFTimeInterval = 0
    private var lastPathTime: CFTimeInterval = 0
    private var groundY: CGFloat
    private var visibleTop: CGFloat
    private let frame: CGRect, scale: CGFloat

    init?(screen: NSScreen, prefs: OverlayPrefs) {
        guard let gpu = Overlay.sharedGpu else { return nil }
        let f = screen.frame, v = screen.visibleFrame
        frame = f
        scale = screen.backingScaleFactor
        groundY = v.minY - f.minY
        visibleTop = v.maxY - f.minY
        let areaScale = Float(f.width * f.height) / (1440 * 900)
        let field = SnowField(size: f.size, origin: f.origin, groundY: groundY, visibleTop: visibleTop,
                              flakeCount: max(120, Int(Float(Tuning.flakes) * areaScale)))
        var buffers: [MTLBuffer] = []
        for _ in 0..<3 {
            guard let b = gpu.device.makeBuffer(length: field.capacity * MemoryLayout<Instance>.stride, options: .storageModeShared) else { return nil }
            buffers.append(b)
        }
        self.screen = screen
        self.prefs = prefs
        self.gpu = gpu
        self.field = field
        self.buffers = buffers
        // A non-activating panel: clicking a snowball must not pull Neve (and its menu bar) in front of the user's app.
        let panel = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        window = panel
        super.init()
        view.onDown = { [weak self] e in MainActor.assumeIsolated { self?.mouseDown(e) } }
        view.onDrag = { [weak self] e in MainActor.assumeIsolated { self?.mouseDragged(e) } }
        view.onUp = { [weak self] e in MainActor.assumeIsolated { self?.mouseUp(throwing: e.timestamp - (self?.lastDragTime ?? 0) < 0.08) } }

        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.setFrame(f, display: false)

        let bounds = CGRect(origin: .zero, size: f.size)
        let root = CALayer()
        view.frame = bounds
        view.layer = root
        view.wantsLayer = true
        window.contentView = view

        piles = PileLayers(in: root, bounds: bounds)
        dragPile = PileLayers(in: root, bounds: bounds)

        root.addSublayer(snowmanLayers.root)   // above the piles, under the flakes
        root.addSublayer(ballLayers.root)
        root.addSublayer(fightLayers.root)

        let scale = screen.backingScaleFactor
        metalLayer.device = gpu.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.contentsScale = scale
        metalLayer.frame = bounds
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        root.addSublayer(metalLayer)

        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)

        window.setAccessibilityElement(false)   // decoration: VoiceOver must not announce it
        window.setAccessibilityHidden(true)
        view.setAccessibilityElement(false)
        view.setAccessibilityHidden(true)
        window.isExcludedFromWindowsMenu = true
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        apply(prefs)
        setLowPower(ProcessInfo.processInfo.isLowPowerModeEnabled)
        field.setIntensity(prefs.intensity, immediate: true)
        intro()
    }

    /// True when the screen's frame or scale differs from creation: needs a full rebuild.
    func screenChanged(_ s: NSScreen) -> Bool { s.frame != frame || s.backingScaleFactor != scale }

    /// Dock / menu bar moved (visibleFrame changed, frame unchanged): updated in place, piles kept.
    func refreshBounds() {
        let g = screen.visibleFrame.minY - frame.minY, t = screen.visibleFrame.maxY - frame.minY
        guard g != groundY || t != visibleTop else { return }
        groundY = g
        visibleTop = t
        field.setBounds(groundY: g, visibleTop: t)
    }

    /// Reduce Motion: calmer snow. Increase Contrast: stronger flake rim and pile bottom edge. (Reduce Transparency: nothing to change, the overlay has no blur.)
    @objc private func accessibilityChanged() {
        let ws = NSWorkspace.shared
        let motion = ws.accessibilityDisplayShouldReduceMotion, hc = ws.accessibilityDisplayShouldIncreaseContrast
        field.setCalm(motion)
        reduceMotion = motion
        still = prefs.still && motion
        contrast = hc ? 1 : 0
        snowmanLayers.setContrast(hc)
        ballLayers.setContrast(hc)
        piles.setContrast(hc)
        dragPile.setContrast(hc)
    }

    func update(windows: [WindowInfo]) {
        field.update(windows: windows)
        pollMouse = NSEvent.mouseLocation   // reference for the per-frame drag offset; the poll's real bounds win
        forcePath = true                    // re-place the piles at once, dropping any drag offset
    }
    func clear() { field.clear() }
    func stage(_ s: Scenario) { field.stage(s) }

    private var outroGen = 0   // bumped by intro() / outro(): a stale outro step does nothing
    /// Snow starts gradually (no flakes pre-scattered): launch and "Nevar" turned back on. Reduce Motion keeps the plain window fade-in.
    func intro() {
        outroGen += 1
        if !reduceMotion { field.beginIntro(duration: 2.5) }
    }
    /// Being shown right now (the only state an outro makes sense in).
    var showing: Bool { run && !fullscreen && window.isVisible }
    /// Piles, balls and the snowman collapse into falling snow, then the window fades; `done` runs ~1.4s later.
    /// Reduce Motion / still snow: just a 0.4s fade.
    func outro(_ done: @escaping @MainActor () -> Void) {
        outroGen += 1
        let gen = outroGen, fade = reduceMotion || still
        if !fade { field.collapseAll(spread: 0.3) }
        DispatchQueue.main.asyncAfter(deadline: .now() + (fade ? 0 : 1.0)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.outroGen == gen else { return }
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; self.window.animator().alphaValue = 0 }) {
                    MainActor.assumeIsolated { if self.outroGen == gen { done() } }
                }
            }
        }
    }
    func dropPiles() { field.dropPiles() }
    func setLowPower(_ on: Bool) {
        lowPower = on
        field.setLowPower(on)
        link?.preferredFrameRateRange = frameRange
    }
    /// Applies the user options (idempotent; the controller calls it on every change).
    func apply(_ p: OverlayPrefs) {
        prefs = p
        // Behind windows: just above the desktop icons (snow over the wallpaper only); else one above the Dock:
        // over the Dock (piles) but under menu bar, status-bar popovers and menus (all .statusBar+).
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(p.behind ? .desktopIconWindow : .dockWindow)) + 1)
        window.sharingType = p.showInCaptures ? .readOnly : .none   // hidden from screenshots / recordings / sharing by default
        field.snowmanEnabled = p.snowman
        field.walk.enabled = p.walk
        field.setIntensity(p.intensity)
        link?.preferredFrameRateRange = frameRange
        accessibilityChanged()   // `still` follows the pref
    }
    private var frameRange: CAFrameRateRange {
        lowPower || prefs.economy ? CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30) : CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    }

    /// True when `r` (a window frame, AppKit coords) covers this whole screen, menu bar included = a fullscreen app.
    func covers(_ r: CGRect) -> Bool { r.insetBy(dx: -1, dy: -1).contains(screen.frame) }
    var isFullscreen: Bool { fullscreen }
    func setFullscreen(_ on: Bool) { if on != fullscreen { fullscreen = on; present() } }

    /// The controller's decision: enabled, awake, session active, not thermally throttled, user not idle.
    func setRun(_ on: Bool) { run = on; present() }

    /// Presents only when `run` and not under a fullscreen app. Piles are kept while paused.
    private func present() {
        guard run && !fullscreen else {
            guard window.isVisible else { link?.isPaused = true; return }
            // Fade out (~0.4s), then hide; the link keeps running meanwhile. Fullscreen/thermal hides are the same path.
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; window.animator().alphaValue = 0 }) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !(self.run && !self.fullscreen) else { return }
                    self.link?.isPaused = true
                    self.window.orderOut(nil)
                }
            }
            return
        }
        if !window.isVisible { occluded = false; window.alphaValue = 0; window.orderFrontRegardless(); lastTimestamp = 0 }
        if window.alphaValue < 1 { NSAnimationContext.runAnimationGroup { $0.duration = 0.4; window.animator().alphaValue = 1 } }
        if link == nil {
            // CAMetalDisplayLink hands over a ready drawable, so the main thread never blocks in nextDrawable.
            let l = CAMetalDisplayLink(metalLayer: metalLayer)
            l.delegate = self
            l.preferredFrameLatency = 2
            l.preferredFrameRateRange = frameRange
            l.add(to: .main, forMode: .common)
            link = l
        }
        link?.isPaused = occluded
    }

    /// Only meaningful while ordered in (orderOut also reports "not visible"); pauses the link, never the window.
    @objc private func occlusionChanged() {
        guard window.isVisible else { return }
        occluded = !window.occlusionState.contains(.visible)
        if !occluded { lastTimestamp = 0 }
        link?.isPaused = occluded
    }

    func teardown() {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        link?.invalidate()
        link = nil
        window.orderOut(nil)
        window.contentView = nil
    }

    /// The SDK declares this nonisolated. The link is added to RunLoop.main, so it always fires on the main thread:
    /// assumeIsolated is therefore sound (and traps if that ever changes).
    nonisolated func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        // Update/drawable are not Sendable, but never leave the main thread here.
        nonisolated(unsafe) let drawable = update.drawable
        let time = update.targetTimestamp
        MainActor.assumeIsolated { tick(drawable, time) }
    }

    private func tick(_ drawable: CAMetalDrawable, _ time: CFTimeInterval) {
        guard window.isVisible else { return }
        let now = time, resumed = lastTimestamp == 0
        let dt = lastTimestamp == 0 ? 1.0 / 60 : min(now - lastTimestamp, 1.0 / 30)
        lastTimestamp = now
        if !still { field.step(dt: Float(dt)) }
        // Cursor wipe: one sweep per frame from the last position (polling needs no event monitor). Drags are window physics.
        let cursor = NSEvent.mouseLocation
        let option = NSEvent.modifierFlags.contains(.option)
        let o = frame.origin
        let here = CGPoint(x: cursor.x - o.x, y: cursor.y - o.y)
        if held != nil, !option { mouseUp() }   // ⌥ released mid-drag: let go
        // Interactive only where there is snow or a snowball (and ⌥ is down): everywhere else clicks pass through.
        let interactive = held != nil || (option && frame.contains(cursor) && field.hitTest(point: here))
        if window.ignoresMouseEvents == interactive { window.ignoresMouseEvents = !interactive }
        if !resumed, !still, let prev = lastCursor, prev != cursor, NSEvent.pressedMouseButtons & 1 == 0, !option, held == nil {
            field.sweep(from: CGPoint(x: prev.x - o.x, y: prev.y - o.y), to: CGPoint(x: cursor.x - o.x, y: cursor.y - o.y), dt: Float(dt))
        }
        let local = SIMD2(Float(cursor.x - frame.origin.x), Float(cursor.y - frame.origin.y))
        let moved = lastCursor.map { SIMD2(Float(cursor.x - $0.x), Float(cursor.y - $0.y)) / Float(dt) } ?? .zero
        field.setPointer(frame.contains(cursor) ? local : nil, velocity: resumed ? .zero : moved)
        lastCursor = cursor
        let drag = field.draggingID
        if field.pilesDirty, forcePath || now - lastPathTime >= 1.0 / 15 {
            lastPathTime = now
            field.pilesDirty = false
            forcePath = false
            let path = field.pilePath(dragging: drag ?? -1)
            let dpath = drag == nil ? nil : field.pilePath(dragging: drag!, forDrag: true)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            piles.set(path: path)
            dragPile.set(path: dpath)
            dragPile.setTransform(.identity)
            CATransaction.commit()
        }
        // A dragged window follows the mouse 1:1: slide its pile layer by the mouse delta since the last poll.
        // After release the last offset is held until the next poll reconciles with the real bounds.
        if drag != nil, NSEvent.pressedMouseButtons != 0 {
            let m = NSEvent.mouseLocation
            let t = CGAffineTransform(translationX: m.x - pollMouse.x, y: m.y - pollMouse.y)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dragPile.setTransform(t)
            CATransaction.commit()
        }
        snowmanLayers.update(field, reduceMotion: reduceMotion)
        ballLayers.update(field, reduceMotion: reduceMotion)
        fightLayers.update(field)
        render(drawable)   // after the drag transform: a skipped Metal frame never starves the pile
    }

    private func mouseDown(_ e: NSEvent) {
        guard e.modifierFlags.contains(.option) || NSEvent.modifierFlags.contains(.option) else { return }
        held = field.pickSnowball(at: e.locationInWindow) ?? field.scoop(at: e.locationInWindow)
        lastDragTime = e.timestamp
    }

    private func mouseDragged(_ e: NSEvent) {
        guard let id = held else { return }
        field.drag(id, to: e.locationInWindow, dt: Float(max(e.timestamp - lastDragTime, 1.0 / 240)))
        lastDragTime = e.timestamp
    }

    private func mouseUp(throwing: Bool = false) {   // a pause before letting go is not a throw
        guard let id = held else { return }
        held = nil
        field.drop(id, throwing: throwing)
    }

    private func render(_ drawable: CAMetalDrawable) {
        guard inFlight.wait(timeout: .now()) == .success else { return }   // never block the main thread
        guard let cmd = gpu.queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        let buffer = buffers[bufferIndex]
        bufferIndex = (bufferIndex + 1) % buffers.count
        let count = still ? 0 : field.writeInstances(to: buffer.contents().assumingMemoryBound(to: Instance.self))

        pass.colorAttachments[0].texture = drawable.texture
        if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
            var viewSize = field.size
            enc.setRenderPipelineState(gpu.pipeline)
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setVertexBytes(&viewSize, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            enc.setFragmentBytes(&contrast, length: MemoryLayout<Float>.size, index: 0)
            if count > 0 { enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count) }
            enc.endEncoding()
        }
        cmd.present(drawable)
        let sem = inFlight
        cmd.addCompletedHandler { _ in sem.signal() }
        cmd.commit()
    }
}
