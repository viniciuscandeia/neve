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

/// Click-through snow window covering one screen.
@MainActor
final class Overlay: NSObject, CAMetalDisplayLinkDelegate {
    private static let sharedGpu = Gpu()

    let screen: NSScreen
    private let field: SnowField
    private let gpu: Gpu
    private let window: NSWindow
    private let view = NSView()
    private let pileLayer = CAShapeLayer()
    private let highlightLayer = CAShapeLayer()
    private let dragLayer = CAShapeLayer()        // the pile of a window being dragged: slid with the mouse between polls
    private let dragHighlight = CAShapeLayer()
    private let crestLayer = CAShapeLayer(), dragCrest = CAShapeLayer()
    private var crestFor: [CAShapeLayer] { [crestLayer, dragCrest] }
    private var masks: [ObjectIdentifier: CAShapeLayer] = [:]
    private func crestMask(_ l: CAShapeLayer) -> CAShapeLayer {
        if let m = masks[ObjectIdentifier(l)] { return m }
        let m = CAShapeLayer()
        m.frame = l.bounds
        m.fillColor = CGColor(gray: 0, alpha: 1)
        masks[ObjectIdentifier(l)] = m
        return m
    }
    /// Sets a pile path on a crest layer (and its mask). Runs only when the path changes.
    private func setCrest(_ l: CAShapeLayer, _ p: CGPath?) {
        l.path = p
        let m = crestMask(l)
        guard let p else { m.path = nil; return }
        let q = CGMutablePath()
        q.addPath(p)
        q.addPath(p, transform: CGAffineTransform(translationX: 0, y: -3))
        m.path = q
    }
    private var pollMouse = NSEvent.mouseLocation
    private var forcePath = false
    private let metalLayer = CAMetalLayer()
    private let buffers: [MTLBuffer]
    private var bufferIndex = 0
    private let inFlight = DispatchSemaphore(value: 3)
    private var link: CAMetalDisplayLink?
    private let pass = MTLRenderPassDescriptor()   // reused every frame; only the texture changes
    private var run = false, fullscreen = false, hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    private var occluded = false
    private var lowPower = false
    private var contrast: Float = 0
    private var stillPref = UserDefaults.standard.bool(forKey: "stillSnow")
    private var still = false   // Reduce Motion + "Neve parada": no flakes drawn or stepped, piles kept
    private var economy = UserDefaults.standard.bool(forKey: "economy")
    private var lastTimestamp: CFTimeInterval = 0
    private var lastPathTime: CFTimeInterval = 0
    private var groundY: CGFloat
    private var visibleTop: CGFloat
    private let frame: CGRect, scale: CGFloat

    init?(screen: NSScreen) {
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
        self.gpu = gpu
        self.field = field
        self.buffers = buffers
        window = NSWindow(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
        super.init()

        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.sharingType = UserDefaults.standard.bool(forKey: "showInCaptures") ? .readOnly : .none   // hidden from screenshots / recordings / sharing by default
        window.isReleasedWhenClosed = false
        // One above the Dock: over the Dock (piles) but under menu bar, status-bar popovers and menus (all .statusBar+).
        setBehind(UserDefaults.standard.bool(forKey: "behindWindows"))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.setFrame(f, display: false)

        let bounds = CGRect(origin: .zero, size: f.size)
        let root = CALayer()
        view.frame = bounds
        view.layer = root
        view.wantsLayer = true
        window.contentView = view

        // Shaded snow: bluish-gray body with soft bluish shadow, plus a white copy of the same path
        // lifted 1.5pt so only a thin bluish band stays visible at the bottom edge.
        for (body, highlight) in [(pileLayer, highlightLayer), (dragLayer, dragHighlight)] {
            body.frame = bounds
            body.fillColor = CGColor(red: 0.84, green: 0.90, blue: 0.98, alpha: 0.97)
            body.shadowColor = CGColor(red: 0.25, green: 0.4, blue: 0.65, alpha: 1)
            body.shadowOpacity = 0.4
            body.shadowRadius = 3
            body.shadowOffset = CGSize(width: 0, height: -1.5)
            root.addSublayer(body)
            highlight.frame = bounds.offsetBy(dx: 0, dy: 1.5)
            highlight.fillColor = CGColor(red: 0.88, green: 0.93, blue: 0.99, alpha: 0.97)
            root.addSublayer(highlight)
            // Crest: pure white, masked to a ~3pt sliver along the top edge (path minus itself shifted down).
            let crest = crestFor[body === pileLayer ? 0 : 1]
            crest.frame = bounds
            crest.fillColor = CGColor(gray: 1, alpha: 0.95)
            crestMask(crest).fillRule = .evenOdd
            crest.mask = crestMask(crest)
            root.addSublayer(crest)
        }

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
        accessibilityChanged()
        setLowPower(ProcessInfo.processInfo.isLowPowerModeEnabled)
        field.setIntensity(Intensity.saved, immediate: true)
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
        field.setCalm(ws.accessibilityDisplayShouldReduceMotion)
        still = stillPref && ws.accessibilityDisplayShouldReduceMotion
        let hc = ws.accessibilityDisplayShouldIncreaseContrast
        contrast = hc ? 1 : 0
        pileLayer.shadowOpacity = hc ? 0.8 : 0.45
        pileLayer.shadowColor = hc ? CGColor(red: 0.15, green: 0.28, blue: 0.5, alpha: 1) : CGColor(red: 0.25, green: 0.4, blue: 0.65, alpha: 1)
        dragLayer.shadowOpacity = pileLayer.shadowOpacity
        dragLayer.shadowColor = pileLayer.shadowColor
    }


    func update(windows: [WindowInfo]) {
        field.update(windows: windows)
        pollMouse = NSEvent.mouseLocation   // reference for the per-frame drag offset; the poll's real bounds win
        forcePath = true                    // re-place the piles at once, dropping any drag offset
    }
    func clear() { field.clear() }
    func dropPiles() { field.dropPiles() }
    func setLowPower(_ on: Bool) {
        lowPower = on
        field.setLowPower(on)
        link?.preferredFrameRateRange = frameRange
    }
    func setEconomy(_ on: Bool) {
        economy = on
        link?.preferredFrameRateRange = frameRange
    }
    private var frameRange: CAFrameRateRange {
        lowPower || economy ? CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30) : CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    }

    /// True when `r` (a window frame, AppKit coords) covers this whole screen, menu bar included = a fullscreen app.
    func covers(_ r: CGRect) -> Bool { r.insetBy(dx: -1, dy: -1).contains(screen.frame) }
    var isFullscreen: Bool { fullscreen }
    func setFullscreen(_ on: Bool) { if on != fullscreen { fullscreen = on; apply() } }
    func setStill(_ on: Bool) { stillPref = on; accessibilityChanged() }
    /// Behind windows: just above the desktop icons (snow over the wallpaper only); else one above the Dock.
    func setBehind(_ on: Bool) {
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(on ? .desktopIconWindow : .dockWindow)) + 1)
    }
    func setShowInCaptures(_ on: Bool) { window.sharingType = on ? .readOnly : .none }
    func setHot(_ on: Bool) { if on != hot { hot = on; apply() } }
    func setIntensity(_ v: Intensity) { field.setIntensity(v) }

    func start() { run = true; apply() }
    func pause() { run = false; apply() }

    /// Presents only when enabled, not under a fullscreen app, not thermally throttled. Piles are kept while paused.
    private func apply() {
        guard run && !fullscreen && !hot else {
            guard window.isVisible else { link?.isPaused = true; return }
            // Fade out (~0.4s), then hide; the link keeps running meanwhile. Fullscreen/thermal hides are the same path.
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; window.animator().alphaValue = 0 }) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !(self.run && !self.fullscreen && !self.hot) else { return }
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
        let now = time
        let dt = lastTimestamp == 0 ? 1.0 / 60 : min(now - lastTimestamp, 1.0 / 30)
        lastTimestamp = now
        if !still { field.step(dt: Float(dt)) }
        let drag = field.draggingID
        if field.pilesDirty, forcePath || now - lastPathTime >= 1.0 / 15 {
            lastPathTime = now
            field.pilesDirty = false
            forcePath = false
            let path = field.pilePath(dragging: drag ?? -1)
            let dpath = drag == nil ? nil : field.pilePath(dragging: drag!, forDrag: true)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pileLayer.path = path
            pileLayer.shadowPath = path
            highlightLayer.path = path
            setCrest(crestLayer, path)
            setCrest(dragCrest, dpath)
            dragLayer.path = dpath
            dragLayer.shadowPath = dpath
            dragHighlight.path = dpath
            for l in [dragLayer, dragHighlight, dragCrest] { l.setAffineTransform(.identity) }
            CATransaction.commit()
        }
        // A dragged window follows the mouse 1:1: slide its pile layer by the mouse delta since the last poll.
        // After release the last offset is held until the next poll reconciles with the real bounds.
        if drag != nil, NSEvent.pressedMouseButtons != 0 {
            let m = NSEvent.mouseLocation
            let t = CGAffineTransform(translationX: m.x - pollMouse.x, y: m.y - pollMouse.y)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dragLayer.setAffineTransform(t)
            dragHighlight.setAffineTransform(t)
            dragCrest.setAffineTransform(t)
            CATransaction.commit()
        }
        render(drawable)   // after the drag transform: a skipped Metal frame never starves the pile
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
