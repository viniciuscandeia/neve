// AGENT HEADER - Sources/NeveLab/LabAdapter.swift
// Role: `LabAdapter` = the NeveLabKit `SessionWorld` backed by the real NeveLabCore.LabWorld (JSON enum <-> String at the boundary; core LabError -> SessionError.invalid) plus the headless renderer (NeveRender, Metal).
// Config mapping: SessionConfig(id, seed, width x height, dir, build) -> core LabConfig(seed, width, height); everything else stays core defaults (1280x800 scale 1, light, silent, fixed calendar day).
// Frame data: ONE `FrameData` per session, prepared by `core.prepareFrame` once per canonical step (inputs: contrast 0, effects on, shader time = step/60, no occluders / compact) and once more after an accepted action that did not
//   step (so instant commands like fill_pile / create_window show up in the next capture); that is a function of the action history only, never of captures. `capture` never steps physics and never calls writePiles: it only `encode`s the
//   already prepared data into an offscreen bgra8 texture of the session size, composites it over a CoreGraphics background (plain sky + window rectangles with title and id, back to front, BEHIND the snow) and writes <name>.png + <name>.json
//   (step, digest, config, build, state). No Metal device / pipeline / buffers => `capture` throws an explicit error (state / send keep working).
// state(): core state JSON + "digest" (hex of LabWorld.digest(), the exact inner-state hash used by the determinism acceptance tests). The session serialises all calls.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Metal
import NeveCore
import NeveLabCore
import NeveLabKit
import NeveRender
import UniformTypeIdentifiers

final class LabAdapter: SessionWorld, @unchecked Sendable {
    let core: NeveLabCore.LabWorld
    let config: SessionConfig
    private let gpu: Gpu?
    private let frame: FrameData?

    init(config: SessionConfig) {
        self.config = config
        var c = NeveLabCore.LabConfig()
        c.seed = config.seed; c.width = Double(config.width); c.height = Double(config.height)
        let lc = NeveLabCore.LabWorld(config: c); core = lc
        let g = Gpu()
        gpu = g
        frame = g.flatMap { FrameData(gpu: $0, field: lc.field) }
        if let frame {
            frame.inputs.contrast = 0; frame.inputs.effects = true; frame.inputs.frameDt = NeveLabCore.LabWorld.dt
            frame.forcePiles()
            core.prepareFrame = { [unowned self] s in prepare(step: s) }
            prepare(step: 0)
        }
    }

    private func prepare(step: Int) {
        guard let frame else { return }
        frame.inputs.time = Float((Double(step) / 60).truncatingRemainder(dividingBy: 1024))
        frame.grow(for: core.field)
        frame.prepare(core.field)
    }

    func apply(_ action: JSON) throws -> JSON {
        let before = core.step
        do {
            let r = try JSON.parse(core.apply(action.text))
            if core.step == before { prepare(step: core.step) }
            return r
        } catch let e as NeveLabCore.LabError { throw SessionError.invalid(e.message) }
    }

    func state() -> JSON {
        guard case .object(var o) = (try? JSON.parse(core.state())) ?? .null else { return .null }
        o["digest"] = .string(String(core.digest(), radix: 16))
        return .object(o)
    }

    func capture(dir: URL, name: String) throws -> JSON {
        guard let gpu, let frame else { throw SessionError.io("Metal unavailable: no device, pipeline or buffers (capture needs a GPU)") }
        let w = config.width, h = config.height
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
        guard let tex = gpu.device.makeTexture(descriptor: td), let cmd = gpu.queue.makeCommandBuffer() else { throw SessionError.io("Metal: could not create the offscreen texture / command buffer") }
        frame.encode(into: tex, commandBuffer: cmd, field: core.field, scale: 1)
        cmd.commit(); cmd.waitUntilCompleted()
        guard cmd.status == .completed else { throw SessionError.io("Metal: command buffer failed (\(cmd.error.map { "\($0)" } ?? "status \(cmd.status.rawValue)"))") }
        var snow = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&snow, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)

        let st = state()
        let png = dir.appendingPathComponent(name + ".png"), js = dir.appendingPathComponent(name + ".json")
        try writePNG(snow: snow, windows: st["windows"], to: png)
        let meta = JSON.object(["step": .number(Double(core.step)), "digest": st["digest"] ?? .null, "config": (try? JSON.parse(JSONEncoder().encode(config))) ?? .null,
                                "build": .object(config.build.mapValues { .string($0) }), "state": st])
        try meta.data().write(to: js)
        return .object(["files": .array([.string(png.path), .string(js.path)]), "step": .number(Double(core.step))])
    }

    /// Background + windows (image coordinates, y down) drawn first, the premultiplied snow frame over them.
    private func writePNG(snow: [UInt8], windows: JSON?, to url: URL) throws {
        let w = config.width, h = config.height
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bi = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs, bitmapInfo: bi) else { throw SessionError.io("CoreGraphics: no bitmap context") }
        ctx.setFillColor(CGColor(red: 0.60, green: 0.68, blue: 0.78, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if case .array(let list) = windows {
            for win in list.reversed() where win["minimized"] != .bool(true) {   // z 0 = front, so draw from the back
                guard let f = win["frame"], let x = f["x"]?.number, let y = f["y"]?.number, let ww = f["w"]?.number, let wh = f["h"]?.number else { continue }
                let r = CGRect(x: x, y: Double(h) - y - wh, width: ww, height: wh)   // flip to CG's y-up
                let bar = min(30, wh)
                ctx.setFillColor(CGColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)); ctx.fill(r)
                ctx.setFillColor(CGColor(red: 0.84, green: 0.85, blue: 0.88, alpha: 1)); ctx.fill(CGRect(x: r.minX, y: r.maxY - bar, width: ww, height: bar))
                ctx.setStrokeColor(CGColor(red: 0.45, green: 0.47, blue: 0.52, alpha: 1)); ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
                let label = "\(win["title"]?.string ?? "") [id \(Int(win["id"]?.number ?? 0))]"
                let font = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
                let attr = CFAttributedStringCreate(nil, label as CFString, [kCTFontAttributeName: font, kCTForegroundColorFromContextAttributeName: true] as CFDictionary)!
                ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
                ctx.textPosition = CGPoint(x: r.minX + 8, y: r.maxY - bar / 2 - 5)
                CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
            }
        }
        let provider = CGDataProvider(data: Data(snow) as CFData)!
        guard let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: cs, bitmapInfo: CGBitmapInfo(rawValue: bi), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw SessionError.io("CoreGraphics: no snow image") }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw SessionError.io("ImageIO: cannot create \(url.path)") }
        CGImageDestinationAddImage(dest, out, nil)
        guard CGImageDestinationFinalize(dest) else { throw SessionError.io("ImageIO: cannot write \(url.path)") }
    }
}
