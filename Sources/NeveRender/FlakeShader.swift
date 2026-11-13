// AGENT HEADER - Sources/NeveRender/FlakeShader.swift  (flake MSL source; part of the NeveRender library)
// Role: `flakeShaderSource` (MSL in a Swift string; \(Palette.msl(...)) interpolations bake NeveCore Palette colours into the shader, so palette edits need no shader edit): instanced quads, one per `Instance`
//   (kind: 0 flake, 1 clump, 2 slab/falling chunk (packed profile in kind>>8), 3 puff, 4 glint, 5 meltwater drop, 6 out-of-focus disc, 7 flake lit by a Christmas light: colour index | strength << 3 in kind >> 8, mixed toward Palette.lights). Motion-streak stretch uses frameDt (set from the SIM frame, keeps slowmo consistent);
//   `Occ` buffer = the 26 float4 (24 occluder rects + s + n) (screen-local pt) written by the caller through `FrameInputs.occ` (maximized-window compact mode, floating panels).
// Invariants: the MSL `struct Instance` is NeveCore ShaderStructs.instance, checked against NeveCore/Render.swift `Instance` by ShaderLayoutTests (field order, offsets, size); changing one without the other renders garbage silently. Y is up, units are screen-local points.
// Flakes >= 5 pt are six-arm crystals when fragment buffer 0 = float2 (contrast, fx) has fx = 1.
// Perf: flake fragment shader runs for every flake pixel at up to 60 fps on full-screen drawables: keep branches cheap. Callers: Gpu (Gpu.swift) compiles it with the prim and pile sources.

import NeveCore

let flakeShaderSource = """
#include <metal_stdlib>
using namespace metal;
\(ShaderStructs.instance)   // kind: 0 flake, 1 clump, 2 slab, 3 puff, 4 glint, 5 drop, 6 out-of-focus disc
struct VOut { float4 position [[position]]; float2 uv; float alpha; float size; float seed; float2 wpos; float kind; float rot; float aspect; float prof; float2 tail; };
\(ShaderStructs.occ)   // r[0..7] compact: hide every flake, faded by s.x; r[8..15] only background flakes (seed >= 2); r[16..23] HARD (surfaceless windows, floating panels: always hide every flake). Rects are packed from the first slot of each group. s.x = compact strength, s.y = compact count (0 while strength is 0), s.z = hard count, s.w = dark blend 0...1, n.x = background count
vertex VOut flakeVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                        constant Instance *inst [[buffer(0)]], constant float2 &viewSize [[buffer(1)]], constant float &frameDt [[buffer(2)]]) {
    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    Instance i = inst[iid];
    uint k = i.kind & 255u;
    uint lit = k == 7u ? i.kind >> 8 : 0u;   // lit flake: colour index | strength << 3
    uint pr = k == 7u ? 0u : i.kind >> 8;   // falling chunk: packed profile (thickness in half-points + 3 height fractions), see Flake.pack
    float aspect = pr > 0u ? min(float(pr & 511u) * 0.5 / i.size, 3.0) : 0.45;
    float2 l = corner * i.size * 0.5 * float2(1.0, k == 2 ? aspect : 1.0) * (pr > 0u ? 1.15 : 1.0);   // chunks: a margin for the soft, irregular edge
    float c = cos(i.rot), sn = sin(i.rot);
    float2 p = i.pos + float2(c * l.x - sn * l.y, sn * l.x + c * l.y);
    // Motion streak (flakes, clumps, drops): stretch the quad backwards along the velocity, head at the current position.
    // smear = distance covered in one frame (frameDt, so 30 / 20 fps do not strobe), capped at k * size; below 0.3pt the quad is untouched. Slow snow (< 150 pt/s) never streaks; debris and drops do.
    float2 uv = corner, tail = float2(0.0);
    float alphaK = 1.0;
    float speed = length(i.vel);
    float smear = (((k == 0u || k == 7u) && speed >= 150.0) || k == 1u || k == 5u) ? min(speed * frameDt, i.size * (k == 5u ? 1.0 : 2.0)) : 0.0;
    if (smear >= 0.3) {
        float2 dir = i.vel / speed, perp = float2(-dir.y, dir.x);
        float h = i.size * 0.5 * (pr > 0u ? 1.15 : 1.0);   // same chunk margin as above
        float a = corner.x > 0.0 ? h : -(h + smear);
        float2 d = dir * a + perp * (corner.y * h);
        p = i.pos + d;
        uv = float2(c * d.x + sn * d.y, -sn * d.x + c * d.y) / h;   // back into the shape's own (un-rotated) frame
        float2 t = -dir * smear;
        tail = float2(c * t.x + sn * t.y, -sn * t.x + c * t.y) / h;
        alphaK = i.size / (i.size + smear * 0.6);   // keep the total brightness
    }
    VOut o;
    o.position = float4(p / viewSize * 2.0 - 1.0, 0.0, 1.0);
    o.uv = uv;
    o.tail = tail;
    o.alpha = i.alpha * alphaK;
    o.size = i.size;
    o.seed = i.seed;
    o.wpos = p;
    o.kind = float(k);
    o.rot = i.rot;
    o.aspect = aspect;
    o.prof = float(k == 7u ? lit : pr);
    return o;
}
// `cf` = (contrast, fx): contrast (Increase Contrast) = 1 darkens the flake edge; fx = 1 draws flakes >= 5 pt as six-arm crystals (0 in economy / Low Power).
// 1 inside the rect (minx, miny, maxx, maxy; screen coordinates) with a soft ~8pt edge; empty rects hide nothing.
static float occMask(float2 p, float4 r) {
    if (r.z <= r.x) return 0.0;
    float d = min(min(p.x - r.x, r.z - p.x), min(p.y - r.y, r.w - p.y));
    return smoothstep(-4.0, 4.0, d);
}
fragment float4 flakeFragment(VOut in [[stage_in]], constant float2 &cf [[buffer(0)]], constant Occ &occ [[buffer(1)]]) {
    float contrast = cf.x, fx = cf.y;   // fx = 0 in economy / Low Power: round flakes
    float seed = fract(in.seed);
    float dark = occ.s.w;
    float hide = 0.0;
    for (int k = 0; k < int(occ.s.y); k++) hide = max(hide, occMask(in.wpos, occ.r[k]) * occ.s.x);
    if (in.seed >= 2.0) for (int k = 0; k < int(occ.n.x); k++) hide = max(hide, occMask(in.wpos, occ.r[8 + k]));
    for (int k = 0; k < int(occ.s.z); k++) hide = max(hide, occMask(in.wpos, occ.r[16 + k]));
    if (hide >= 1.0) discard_fragment();
    int kind = int(in.kind + 0.5);
    float litS = 0.0; int litI = 0;
    if (kind == 7) { kind = 0; uint lc = uint(in.prof + 0.5); litI = int(lc & 7u); litS = float((lc >> 3) & 15u) / 15.0; }
    float2 u0 = in.uv;   // distance to the streak's segment instead of to a point; head opaque, tail fainter
    float sg = 1.0;
    float tt2 = dot(in.tail, in.tail);
    if (tt2 > 0.0) { float tt = clamp(dot(u0, in.tail) / tt2, 0.0, 1.0); u0 -= in.tail * tt; sg = mix(1.0, 0.3, tt); }
    if (kind == 6) {   // out-of-focus foreground flake: soft gaussian-like disc, no edge, no streak
        float r2 = dot(in.uv, in.uv);
        float a = exp(-3.5 * r2) * (1.0 - smoothstep(0.7, 1.0, r2)) * in.alpha * (1.0 - hide);
        return float4(\(Palette.msl(Palette.flake)) * a, a);
    }
    if (kind == 5) {   // meltwater drop: teardrop (point up), bluish translucent, white specular dot
        float2 u = u0;
        float t = (u.y + 1.0) * 0.5;
        float w = t < 0.4 ? 0.7 * sqrt(max(1.0 - pow((0.4 - t) / 0.4, 2.0), 0.0)) : 0.7 * (1.0 - t) / 0.6;
        float e = max(0.12, 1.5 * fwidth(u.x));
        float a = (1.0 - smoothstep(w - e, w + e * 0.5, abs(u.x))) * step(-1.0, u.y) * (1.0 - smoothstep(0.96, 1.0, t));
        float spec = 1.0 - smoothstep(0.08, 0.2, length(u - float2(-0.2, -0.15)));
        float rim = 1.0 - smoothstep(0.06, 0.24, w - abs(u.x));   // thin darker-blue outline so it reads on any wallpaper
        float3 c = mix(\(Palette.msl(Palette.dropFill)), \(Palette.msl(Palette.dropEdge)), rim);
        c = mix(c, \(Palette.msl(Palette.flake)), spec);
        a *= in.alpha * sg * (1.0 - hide);
        return float4(c * a, a);
    }
    if (kind > 0) {
        float3 body = \(Palette.msl(Palette.snow)), white = \(Palette.msl(Palette.flake)), shadow = mix(body * 0.72 * \(Palette.msl(Palette.deep)), \(Palette.msl(Palette.shadowHC)), contrast);   // shaded snow: the body darkened, not a black wash
        float2 u = u0;
        // Light stays fixed while the shape turns: shading masks use the un-rotated position (world offset / half-size), clamped to the quad.
        float rc = cos(in.rot), rs = sin(in.rot);
        float2 ul = float2(rc * u.x - rs * u.y, rs * u.x + rc * u.y);
        if (kind == 2) ul.y = clamp(rc * u.y + rs * u.x / max(in.aspect, 0.45), -1.0, 1.0);   // long thin blocks: a small tilt must not flip the lighting
        float a = 0.0;
        float3 c = white;
        if (kind == 1 || (kind == 2 && in.prof <= 0.0)) {   // clump (also a slab without a profile, should one ever arrive): lumpy disc, shadowed below, whiter on top
            float th = atan2(u.y, u.x) + seed * 6.2832;
            float d = length(u) / (1.0 + 0.12 * cos(3.0 * th + seed * 17.0) + 0.06 * cos(5.0 * th));
            a = 1.0 - smoothstep(1.0 - max(0.18, 1.5 * fwidth(d)), 1.0, d);
            float lt = dot(ul, \(Palette.mslLight));   // along the one light
            c = mix(body, shadow, 0.35 * (1.0 - smoothstep(-0.3, 0.2, lt)));
            c = mix(c, white, 0.3 * smoothstep(0.3, 0.7, lt));
        } else if (kind == 2 && in.prof > 0.0) {   // falling chunk of pile: curved lumpy crest from the profile, soft ragged underside, broken edges
            uint pr = uint(in.prof + 0.5);
            float T = float(pr & 511u) * 0.5, W = in.size;
            float hl = float((pr >> 9) & 31u) / 31.0, hm = float((pr >> 14) & 31u) / 31.0, hr = float((pr >> 19) & 31u) / 31.0;
            float2 q = u * float2(W * 0.5, T * 0.5) * 1.15;
            float s = clamp(q.x / (W * 0.5), -1.0, 1.0);
            float h = hm + 0.5 * (hr - hl) * s + (0.5 * (hl + hr) - hm) * s * s;   // quadratic through the 3 pile heights
            float lump = 0.5 + 0.3 * sin(s * (3.0 + 5.0 * seed) + seed * 40.0) + 0.2 * sin(s * 11.0 + seed * 70.0);
            h = clamp(h + (lump - 0.5) * 0.28, 0.12, 1.0) * (1.0 - 0.6 * smoothstep(0.55, 1.0, abs(s)));   // shoulders round off toward the broken ends
            float ytop = -T * 0.5 + h * T;
            float ybot = -T * 0.5 + T * (0.04 + 0.12 * (0.5 + 0.3 * sin(s * 7.0 + seed * 90.0) + 0.2 * sin(s * 19.0 + seed * 30.0)));
            float vv = clamp(q.y / (T * 0.5), -1.0, 1.0);
            float xlim = W * 0.5 * (1.0 - 0.10 * (0.5 + 0.3 * sin(vv * 6.0 + seed * 50.0) + 0.2 * sin(vv * 17.0 + seed * 20.0)) - 0.22 * (1.0 - smoothstep(-1.0, -0.3, vv)) - 0.12 * smoothstep(0.2, 1.0, vv));   // mound: rounded foot, narrower crest
            float inside = min(min(ytop - q.y, q.y - ybot), xlim - abs(q.x));
            a = clamp(0.5 + inside / max(fwidth(inside), 1.0), 0.0, 1.0);
            float depth = (ytop - q.y) / max(ytop - ybot, 1.0);   // 0 at the crest, 1 at the underside
            float mott = 0.5 + 0.5 * sin(q.x * 0.22 + seed * 60.0 + q.y * 0.15);   // slow mottling, no pattern
            c = mix(white, body, smoothstep(0.15, 0.85, depth));
            c = mix(c, shadow, 0.55 * smoothstep(0.6, 1.0, depth) + 0.08 * mott * depth);   // the hide mask fades alpha only (below), never the shading
            c = mix(c, white, 1.0 - smoothstep(0.0, 1.6, ytop - q.y));
        } else if (kind == 3) {   // puff: soft white, no rim
            a = max(1.0 - dot(u, u), 0.0);
        } else if (kind == 4) {   // glint: 4-point star
            float v = sqrt(abs(u.x)) + sqrt(abs(u.y));
            a = (1.0 - smoothstep(0.5, 1.0, v)) + 0.5 * (1.0 - smoothstep(0.0, 0.5, length(u)));
            a = min(a, 1.0);
            c = \(Palette.msl(Palette.glint));
        }   // any other kind: a = 0, nothing drawn
        a *= in.alpha * sg * (1.0 - hide);
        return float4(c * a, a);
    }
    float d = length(u0);
    // Flakes >= ~5pt: faint 6-fold crystal hint + a little per-flake irregularity. Small ones stay round dots.
    float big = fx > 0.0 ? step(5.0, in.size) : smoothstep(3.5, 5.5, in.size);
    if (big > 0.0) {
        float th = atan2(u0.y, u0.x) + seed * 6.2832;
        if (fx > 0.0) {   // six-arm crystal: arms (thin or fat by seed), a seed-sized core, optional short side tips between the arms
            float k = 3.0 + 7.0 * fract(seed * 5.3), core = 0.30 + 0.12 * fract(seed * 11.7);
            float r = core + (1.0 - core) * pow(abs(cos(3.0 * th)), k) + 0.28 * fract(seed * 3.7) * pow(abs(sin(3.0 * th)), 10.0);
            d /= max(min(r, 1.0) * 0.92, 0.2);
        } else {
        float wob = cos(6.0 * th) * 0.13 + cos(3.0 * th + seed * 17.0) * 0.07 * fract(seed * 7.0);
        d *= 1.0 - big * (wob + 0.04);
        }
    }
    // Depth of field: the focus plane is a mid-size sky flake; further from it (smaller / background = far, bigger = near) the edge gets softer.
    float far = in.seed >= 2.0 ? 1.0 : 0.7 * clamp(abs(in.size - 4.5) / 3.0, 0.0, 1.0);
    float soft = max(max(0.45, 1.5 * fwidth(d)), 0.6 * far);
    // No gray-blue ring: white body with a very faint neutral edge shadow in light mode (none in dark); Increase Contrast darkens the edge.
    float edge = smoothstep(0.35, 1.0, d);
    float3 rimC = mix(\(Palette.msl(Palette.shadow)), \(Palette.msl(Palette.shadowHC)), contrast);
    float rk = mix(\(Palette.msl(Palette.rimAlpha)), 0.7, contrast);
    float a = (1.0 - smoothstep(1.0 - soft, 1.0, d)) * in.alpha * sg * (1.0 - hide);
    float3 fc = mix(\(Palette.msl(Palette.flake)), rimC, rk * edge);
    if (litS > 0.0) {   // lit by a Christmas light: toward the bulb's colour
        float3 lcol[5] = { \(Palette.lights.map { Palette.msl($0) }.joined(separator: ", ")) };
        fc = mix(fc, lcol[litI], min(litS * 1.4, 0.9));
    }
    return float4(fc * a, a);
}
"""

