// AGENT HEADER - Sources/NeveRender/Gpu.swift  (shared Metal objects: device, queue, the three pipelines)
// Role: `Gpu` (built once per process by the app / lab): MTLDevice, command queue and the three render pipelines (flakes, prims, piles; premultiplied-alpha blend into bgra8Unorm).
//   The Metal library is compiled AT RUNTIME from source strings (flakeShaderSource + primShaderSource + pileShaderSource) because Command Line Tools have no `metal` compiler: `Gpu.init?` returns nil on any
//   compile/pipeline failure (the app then logs once and shows "Sem neve: este Mac não consegue desenhá-la"; NEVE_SHADER_CHECK=1 surfaces the error on stderr).
// No AppKit, no side effects: the light/dark AppearanceWatcher is started by the app (Sources/Neve/AppearanceWatcher.swift) before it builds the Gpu.
// Related: FrameData.swift (buffers + frame encoding), the three *Shader.swift files.

import Foundation
import Metal
import NeveCore

/// Shared Metal objects, built once: one library (runtime-compiled from the shader strings), the flake, prim and pile pipelines.
public struct Gpu {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    let flakes: MTLRenderPipelineState
    let prims: MTLRenderPipelineState
    let piles: MTLRenderPipelineState

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: flakeShaderSource + primShaderSource + pileShaderSource, options: nil) }
        catch { FileHandle.standardError.write(Data("Neve: shader compile failed: \(error)\n".utf8)); return nil }   // NEVE_SHADER_CHECK=1 surfaces this
        guard let flakes = Gpu.pipeline(device, library, "flakeVertex", "flakeFragment"),
              let prims = Gpu.pipeline(device, library, "primVertex", "primFragment"),
              let piles = Gpu.pipeline(device, library, "pileVertex", "pileFragment") else { return nil }
        self.device = device
        self.queue = queue
        self.flakes = flakes
        self.prims = prims
        self.piles = piles
    }

    /// Premultiplied-alpha blending into a bgra8 target.
    private static func pipeline(_ device: MTLDevice, _ lib: MTLLibrary, _ v: String, _ f: String) -> MTLRenderPipelineState? {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: v)
        d.fragmentFunction = lib.makeFunction(name: f)
        let c = d.colorAttachments[0]!
        c.pixelFormat = .bgra8Unorm
        c.isBlendingEnabled = true
        c.sourceRGBBlendFactor = .one
        c.sourceAlphaBlendFactor = .one
        c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do { return try device.makeRenderPipelineState(descriptor: d) }
        catch { FileHandle.standardError.write(Data("Neve: pipeline \(v)/\(f) failed: \(error)\n".utf8)); return nil }
    }
}
