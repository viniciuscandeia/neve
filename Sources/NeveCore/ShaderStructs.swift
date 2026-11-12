// AGENT HEADER - Sources/NeveCore/ShaderStructs.swift  (the MSL text of the three GPU structs the CPU fills)
// Role: the single source of the Metal struct definitions that mirror `Instance`, `Prim` and `PileSeg` (plus `occ`, the flake fragment's occluder buffer, checked by its slot count) (Render.swift). The shader source strings in Sources/Neve (Renderer.swift flakeShaderSource, PrimShader.swift, PileShader.swift) interpolate these
//   strings instead of repeating them, and ShaderLayoutTests parses exactly this text and compares size / alignment / field offsets with Swift's MemoryLayout, so a field added on one side only fails the suite instead of rendering garbage.
//   Each string is one `struct Name { type field; ... };` line (no comments inside: the test parses it). Types used: float, uint, float2, float4.
// Edit both sides together: Swift struct in Render.swift <-> the string here.

public enum ShaderStructs {
    public static let instance = "struct Instance { float2 pos; float size; float alpha; float seed; float rot; uint kind; float2 vel; };"
    public static let prim = "struct Prim { float2 a; float2 b; float2 c; float2 d; float4 color; uint kind; float soft; float width; float pad; };"
    public static let occ = "struct Occ { float4 r[24]; float4 s; float4 n; };"   // flake fragment: 3 groups of OccluderLayout.slots rects, then s, n (Overlay.occ has OccluderLayout.bufferLength float4)
    public static let pileSeg = "struct PileSeg { float x0; float x1; float top0; float top1; float base0; float base1; float slope; uint dragged; float n0; float n1; float inset; uint z; };"
}
