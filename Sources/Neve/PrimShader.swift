// AGENT HEADER - Sources/Neve/PrimShader.swift  (MSL source for SDF actor primitives; appended to the flake shader library)
// Role: `primShaderSource` draws every figure / ball / carrot / gift / shot / icicle as signed-distance primitives, one instanced quad per `Prim` (NeveCore/Render.swift `Prim`, filled by `Rig` through `PrimWriter`):
//   kind 0 = rotated ellipse (a = centre, b = radii, c.x = angle), kind 1 = capsule/line (a -> b, width), else convex quad (a, b, c, d; polyDist). `soft` widens the ~1 px antialias (used for shadows); colour is premultiplied.
// Invariants: `struct Prim` here MUST match the Swift `Prim` layout (4 x float2, float4, uint, 3 x float); quad padding = soft + 2 pt. Drawn between the pile pass and the flake pass (actors under flakes) via Gpu.prims (Renderer.swift) from Overlay.render.
// Capacity: Overlay's prim buffer holds `primCapacity` (800) prims and grows in update() after a frame that dropped some (PrimWriter.dropped); drawing order = write order (painter's algorithm, no depth buffer).

/// SDF primitives (see `Prim` in NeveCore/Render.swift). Appended to the flake shader source: no second #include.
let primShaderSource = """
struct Prim { float2 a; float2 b; float2 c; float2 d; float4 color; uint kind; float soft; float width; float pad; };
struct PVOut { float4 position [[position]]; float2 p; uint id [[flat]]; };
vertex PVOut primVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                        constant Prim *prims [[buffer(0)]], constant float2 &viewSize [[buffer(1)]]) {
    Prim q = prims[iid];
    float2 lo, hi;
    if (q.kind == 0) { float cs = cos(q.c.x), sn = sin(q.c.x); float2 e = sqrt(float2(q.b.x * q.b.x * cs * cs + q.b.y * q.b.y * sn * sn, q.b.x * q.b.x * sn * sn + q.b.y * q.b.y * cs * cs)); lo = q.a - e; hi = q.a + e; }
    else if (q.kind == 1) { float h = q.width * 0.5; lo = min(q.a, q.b) - h; hi = max(q.a, q.b) + h; }
    else { lo = min(min(q.a, q.b), min(q.c, q.d)); hi = max(max(q.a, q.b), max(q.c, q.d)); }
    float pad = q.soft + 2.0;
    lo -= pad; hi += pad;
    float2 corner = float2((vid & 1) ? 1.0 : 0.0, (vid & 2) ? 1.0 : 0.0);
    float2 p = mix(lo, hi, corner);
    PVOut o;
    o.position = float4(p / viewSize * 2.0 - 1.0, 0.0, 1.0);
    o.p = p;
    o.id = iid;
    return o;
}
// Signed distance to a convex polygon given in either winding (zero-length edges skipped).
static float polyDist(float2 p, float2 v0, float2 v1, float2 v2, float2 v3) {
    float2 v[4] = {v0, v1, v2, v3};
    float area = 0.0;
    for (int i = 0; i < 4; i++) { float2 s = v[i], e = v[(i + 1) & 3]; area += s.x * e.y - e.x * s.y; }
    float sgn = area >= 0.0 ? 1.0 : -1.0;
    float d = -1e9;
    for (int i = 0; i < 4; i++) {
        float2 s = v[i], e = v[(i + 1) & 3], t = e - s;
        float len = length(t);
        if (len < 1e-4) continue;
        float2 n = float2(t.y, -t.x) / len * sgn;   // outward
        d = max(d, dot(p - s, n));
    }
    return d;
}
fragment float4 primFragment(PVOut in [[stage_in]], constant Prim *prims [[buffer(0)]]) {
    Prim q = prims[in.id];
    float d;
    if (q.kind == 0) {
        float2 r = max(q.b, float2(1e-3));
        float cs = cos(q.c.x), sn = sin(q.c.x);
        float2 l = in.p - q.a;
        l = float2(l.x * cs + l.y * sn, -l.x * sn + l.y * cs);
        float k0 = length(l / r), k1 = length(l / (r * r));
        d = k1 > 1e-6 ? k0 * (k0 - 1.0) / k1 : -min(r.x, r.y);
    } else if (q.kind == 1) {
        float2 pa = in.p - q.a, ba = q.b - q.a;
        float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
        d = length(pa - ba * h) - q.width * 0.5;
    } else {
        d = polyDist(in.p, q.a, q.b, q.c, q.d);
    }
    float w = max(fwidth(d) * 0.5, q.soft);   // ~1px antialias; `soft` widens it (shadows)
    float a = q.color.a * (1.0 - smoothstep(-w, w, d));
    return float4(q.color.rgb * a, a);
}
"""
