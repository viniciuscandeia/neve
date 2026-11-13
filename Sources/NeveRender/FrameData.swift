// AGENT HEADER - Sources/NeveRender/FrameData.swift  (frame data preparation + encoding shared by the app overlay and the headless lab)
// Role: `FrameInputs` = everything the picture depends on besides the SnowField (overlay-level state: contrast, reduce motion, effects flag, shader clock `time` (explicit: the app passes systemUptime mod 1024), drag offset, the `occ`
//   occluder buffer (OccluderLayout.bufferLength float4: compact / behind / hard rects, counts, strength), compact soft cut (coverActive / viewRect / liveLocal), frame dts). `FrameData` owns the 3-slot rings (flake Instances, actor Prims, PileSegs) and the
//   per-frame steps in the order the old Overlay.render ran them: `begin()` (advance the ring) -> `writeInstances` -> `writeActors` (= old writePrims + soft-cut fade) -> `writePiles` (only when the pile changed; ring slot of its own) -> `encode(into:)`
//   (piles -> prims -> flakes into ANY bgra8 MTLTexture: a drawable or an offscreen texture). `prepare` runs the three writes in one call for headless callers.
// The caller keeps: display link, in-flight semaphore (a ring slot is only safe to rewrite once the GPU is done with it: the app allows 3 in flight), preparation cadence, drawable size check, present / commit, perf meters, buffer growth timing (`grow` at poll rate).
// Palette stays global per process: `Palette.dark` is read at encode / in the Rig colours. Coordinates: screen-LOCAL points, y up; the viewport slides the whole-screen space under a smaller texture (`viewRect`).
// Perf: writes and encode are the per-frame hot path: no allocation after init (the occ / pile-occluder arrays are reused). Tests: Tests/NeveRenderTests (equivalence with the pre-extraction path while the bridge exists).

import CoreGraphics
import Foundation
import Metal
import NeveCore

/// Overlay-level inputs of one frame; the SnowField is the other half.
public struct FrameInputs {
    public var contrast: Float = 0                 // Increase Contrast: 1 darkens flake rims / pile bottom edge and the actors' outlines
    public var reduceMotion = false                // no flutter on the snowman, no shot trails
    public var effects = true                      // visual extras (glitter, grain, crystals, window shadow); off in economy / Low Power
    public var time: Float = 0                     // shader clock (seconds, already wrapped): pile glints / grain
    public var dragID: Int?                        // surface id of the dragged window; its pile layer, figures and balls ride `dragShift`
    public var dragShift = SIMD2<Float>.zero
    public var frameDt: Float = 1.0 / 60           // SIM frame dt: pile easing
    public var streakDt: Float = 1.0 / 60          // flake streak length = distance per sim frame (frameDt * slowmo)
    public var still = false                       // no flakes drawn
    /// 8 compact rects (faded by strength), 8 hiding background flakes, 8 hard rects, s, n (see the flake shader's `Occ`); the caller writes the rects, `encode` writes the two trailing slots from the counts / strength.
    public var occ = [SIMD4<Float>](repeating: .zero, count: OccluderLayout.bufferLength)
    public var occCount = (compact: 0, behind: 0, hard: 0)
    public var occStrength: Float = 0              // compact occluders 0...1
    public var coverActive = false                 // compact mode entered: the soft cut may fade everything outside `liveLocal`
    public var viewRect: CGRect?                   // screen-local rect the texture shows (compact mode shrinks the drawable); nil = whole screen
    public var liveLocal: CGRect?                  // the uncovered strip (compact mode)
    public var screenSize = CGSize(width: 1, height: 1)
    public init() {}
}

public final class FrameData {
    public var inputs = FrameInputs()
    private let gpu: Gpu
    private let pass = MTLRenderPassDescriptor()   // reused every frame; only the texture changes
    private var buffers: [MTLBuffer]               // flake Instances, 3-slot ring
    private var primBuffers: [MTLBuffer], primCapacity = 1000   // ~700-900 prims (tree ~145, lights ~300) / screen; grows after a frame that dropped some
    private var pileBuffers: [MTLBuffer], pileCapacity = 8192   // grows with the surfaces' bin count
    private var primWant = 0
    private var pileForce = false                  // buffers were replaced: rewrite the piles once
    private var bufferIndex = 0, pileSlot = 0, pileCount = 0
    private var pileOcc: [SIMD4<Float>] = []       // encode's occluder rects, reused every frame
    private var cur = 0                            // ring slot (instances and prims) of the current frame
    private var count = 0, actors = 0              // flake instances / prims of the current frame
    private var live = SIMD4<Float>.zero, outFade: Float = 0
    /// Prims the last `writeActors` dropped for lack of room (the ring grows at the next `grow`).
    public private(set) var primsDropped = 0
    /// Pile segments the last `writePiles` dropped (capacity).
    public private(set) var pilesDropped = 0
    public private(set) var segCount = 0

    public init?(gpu: Gpu, field: SnowField) {
        self.gpu = gpu
        func ring(_ n: Int) -> [MTLBuffer]? {
            let b = (0..<3).compactMap { _ in gpu.device.makeBuffer(length: n, options: .storageModeShared) }
            return b.count == 3 ? b : nil
        }
        guard let b = ring(field.capacity * MemoryLayout<Instance>.stride),
              let p = ring(1000 * MemoryLayout<Prim>.stride),
              let s = ring(8192 * MemoryLayout<PileSeg>.stride) else { return nil }
        buffers = b; primBuffers = p; pileBuffers = s
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        inputs.screenSize = CGSize(width: CGFloat(field.size.x), height: CGFloat(field.size.y))
    }

    /// Poll rate, outside the frame path: sizes the prim / pile rings from demand (old buffers stay alive in any in-flight command buffer). True when something was replaced (the picture must be redrawn).
    @discardableResult
    public func grow(for field: SnowField) -> Bool {
        func make<T>(_ n: Int, _: T.Type) -> [MTLBuffer]? {
            let bs = (0..<3).compactMap { _ in gpu.device.makeBuffer(length: n * MemoryLayout<T>.stride, options: .storageModeShared) }
            return bs.count == 3 ? bs : nil
        }
        var grown = false
        let pd = field.pileSegDemand
        if pd > pileCapacity, let b = make((pd * 5 / 4 + 1023) & ~1023, PileSeg.self) {
            pileBuffers = b; pileCapacity = b[0].length / MemoryLayout<PileSeg>.stride; pileForce = true; grown = true
        }
        if primWant > primCapacity, let b = make((primWant * 3 / 2 + 255) & ~255, Prim.self) {
            primBuffers = b; primCapacity = b[0].length / MemoryLayout<Prim>.stride; grown = true
        }
        return grown
    }

    /// The next `writePiles` rewrites the segments even if the pile did not change (screen geometry changed).
    public func forcePiles() { pileForce = true }

    /// Starts a frame: advances the instance / prim ring.
    public func begin() {
        cur = bufferIndex
        bufferIndex = (bufferIndex + 1) % buffers.count
        count = 0
    }

    /// Flakes, puffs, drops, glints, debris. Returns the instance count.
    @discardableResult
    public func writeInstances(_ field: SnowField) -> Int {
        count = inputs.still ? 0 : field.writeInstances(to: buffers[cur].contents().assumingMemoryBound(to: Instance.self))
        return count
    }

    /// Balls, figures, tree, gifts, shots, icicles, lights (through `Rig`); the ones standing on the dragged window are shifted by the drag. Applies the compact soft cut.
    public func writeActors(_ field: SnowField) {
        var w = PrimWriter(primBuffers[cur].contents().assumingMemoryBound(to: Prim.self), capacity: primCapacity)
        writePrims(field, &w)
        // Soft cut: before the drawable shrinks, everything outside the live strip fades with the occluders (`Rig.a` convention: alpha only).
        outFade = 0
        live = .zero
        let sz = inputs.screenSize
        if inputs.coverActive, inputs.viewRect == nil || inputs.occStrength < 1, let r = inputs.liveLocal, r.width * r.height <= 0.5 * sz.width * sz.height {
            outFade = inputs.occStrength; live = SIMD4(Float(r.minX), Float(r.minY), Float(r.maxX), Float(r.maxY))
            w.fadeOutside(live, by: 1 - outFade)
        }
        primsDropped = w.dropped
        if w.dropped > 0 { primWant = max(primWant, primCapacity + w.dropped) }
        actors = w.n
    }

    /// Pile segments, only when the pile changed (or forced). True = written; false = the previous slot is still current. Mutates the piles' easing (`shown`): once per frame step, never per capture.
    @discardableResult
    public func writePiles(_ field: SnowField) -> Bool {
        let slot = (pileSlot + 1) % pileBuffers.count
        var dropped = 0
        defer { pileForce = false }
        let n = field.writePiles(to: pileBuffers[slot].contents().assumingMemoryBound(to: PileSeg.self), capacity: pileCapacity, dt: inputs.frameDt, force: pileForce, dropped: &dropped)
        pilesDropped = dropped
        guard let n else { return false }
        pileSlot = slot
        pileCount = n
        segCount = n
        return true
    }

    /// All writes in one call (headless callers): begin, instances, actors, piles.
    public func prepare(_ field: SnowField) { begin(); writeInstances(field); writeActors(field); writePiles(field) }

    /// Encodes piles -> actors -> flakes into `texture` (bgra8Unorm; its size = the visible rect x `scale`); the command buffer stays uncommitted (present / commit belong to the caller).
    public func encode(into texture: MTLTexture, commandBuffer cmd: MTLCommandBuffer, field: SnowField, scale: CGFloat) {
        pass.colorAttachments[0].texture = texture
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        let g = inputs.viewRect ?? CGRect(origin: .zero, size: inputs.screenSize)
        var viewSize = field.size
        let fx: Float = inputs.effects ? 1 : 0
        // Shaders always work in whole-screen coordinates; the viewport slides the screen under the (smaller) texture.
        enc.setViewport(MTLViewport(originX: Double(-g.minX * scale), originY: Double(-(CGFloat(field.size.y) - g.maxY) * scale),
                                    width: Double(CGFloat(field.size.x) * scale), height: Double(CGFloat(field.size.y) * scale), znear: 0, zfar: 1))
        if pileCount > 0 {   // piles under the actors
            var dragOffset = inputs.dragID == nil ? SIMD2<Float>.zero : inputs.dragShift
            enc.setRenderPipelineState(gpu.piles)
            enc.setVertexBuffer(pileBuffers[pileSlot], offset: 0, index: 0)
            enc.setVertexBytes(&viewSize, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            enc.setVertexBytes(&dragOffset, length: MemoryLayout<SIMD2<Float>>.size, index: 2)
            enc.setFragmentBuffer(pileBuffers[pileSlot], offset: 0, index: 0)
            var tone = SIMD4<Float>(inputs.contrast, Palette.dark, inputs.time, fx)   // (increase contrast, dark blend, clock, effects)
            enc.setFragmentBytes(&tone, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
            pileOcc.removeAll(keepingCapacity: true)   // 2 x float4 per window in front-to-back order; the dragged one rides the mouse like its pile
            for o in field.occluders {
                var rc = o.rect
                if o.id == inputs.dragID { let s = inputs.dragShift; rc += SIMD4<Float>(s.x, s.y, s.x, s.y) }
                pileOcc.append(rc); pileOcc.append(SIMD4<Float>(o.radius, 0, 0, 0))
            }
            var occN = UInt32(field.occluders.count)
            if pileOcc.isEmpty { pileOcc = [.zero, .zero] }
            enc.setFragmentBytes(&pileOcc, length: pileOcc.count * MemoryLayout<SIMD4<Float>>.stride, index: 2)
            enc.setFragmentBytes(&live, length: MemoryLayout<SIMD4<Float>>.size, index: 4)
            enc.setFragmentBytes(&outFade, length: MemoryLayout<Float>.size, index: 5)
            enc.setFragmentBytes(&occN, length: MemoryLayout<UInt32>.size, index: 3)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: pileCount)
        }
        if actors > 0 {   // actors under the flakes
            enc.setRenderPipelineState(gpu.prims)
            enc.setVertexBuffer(primBuffers[cur], offset: 0, index: 0)
            enc.setVertexBytes(&viewSize, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            enc.setFragmentBuffer(primBuffers[cur], offset: 0, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: actors)
        }
        enc.setRenderPipelineState(gpu.flakes)
        enc.setVertexBuffer(buffers[cur], offset: 0, index: 0)
        enc.setVertexBytes(&viewSize, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        var streakDt = inputs.streakDt   // streak length = distance per SIM frame, so it matches the (slowed) velocity
        enc.setVertexBytes(&streakDt, length: MemoryLayout<Float>.size, index: 2)
        var cf = SIMD2<Float>(inputs.contrast, fx)
        enc.setFragmentBytes(&cf, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        let s = 3 * OccluderLayout.slots
        inputs.occ[s] = SIMD4(inputs.occStrength, inputs.occStrength > 0 ? Float(inputs.occCount.compact) : 0, Float(inputs.occCount.hard), Palette.dark)   // compact rects only mask with strength > 0; behind / hard always
        inputs.occ[s + 1] = SIMD4(Float(inputs.occCount.behind), 0, 0, 0)
        inputs.occ.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        if count > 0 { enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count) }
        enc.endEncoding()
    }

    /// Balls, figures and shots through `Rig`; the ones standing on the dragged window are shifted by the drag.
    private func writePrims(_ field: SnowField, _ w: inout PrimWriter) {
        let hc = inputs.contrast > 0
        let dragID = inputs.dragID, shift = inputs.dragShift
        func d(_ sid: Int?) -> SIMD2<Float> { sid != nil && sid == dragID ? shift : .zero }
        field.writeBallPrims(&w, contrast: hc, shift: d)
        for f in field.figures where f.phase != .hidden {
            if f.kind == .sleigh { Rig.sleigh(field.sleighLook(of: f), contrast: hc, into: &w); continue }
            if f.kind == .rabbit {
                var l = field.rabbitLook(of: f)
                let o = d(f.surfaceID)
                l.foot += o
                if let fl = l.flight { l.flight = fl + SIMD3(o.x, o.y, 0) }
                Rig.rabbit(l, contrast: hc, into: &w)
                continue
            }
            if f.kind == .penguin {
                var l = field.penguinLook(of: f)
                l.foot += d(f.surfaceID)
                Rig.penguin(l, contrast: hc, into: &w)
                continue
            }
            if f.kind == .robin {
                var l = field.robinLook(of: f)
                l.foot += d(f.surfaceID)
                Rig.robin(l, contrast: hc, into: &w)
                continue
            }
            var look = field.look(of: f)
            look.foot += d(f.surfaceID)
            if inputs.reduceMotion { look.pose.flutter = Flutter(); look.newest = 1 }
            Rig.snowman(look, contrast: hc, into: &w)
        }
        field.writeTreePrims(&w, contrast: hc, shift: d)
        field.writeCarrotPrims(&w, shift: d)
        field.writeGiftPrims(&w, contrast: hc, shift: d)
        field.writeShotPrims(&w, trails: !inputs.reduceMotion, shift: d)
        field.writeIciclePrims(&w, contrast: hc, shift: d)
        field.writeLightPrims(&w, shift: d)
    }
}
