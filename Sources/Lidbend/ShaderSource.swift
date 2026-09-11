import Foundation

/// Metal source compiled at runtime.
///
/// The offline `metal` compiler ships with Xcode, not the Command Line Tools,
/// so the library is built with `device.makeLibrary(source:)` at launch instead
/// of being precompiled into a .metallib.
enum ShaderSource {
    static let metal = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float aspect;
    float theta;            // peak tilt in radians
    float bendRadius;       // arc radius, in units of screen height
    float hingeV;           // bend line, 0 = bottom edge, 1 = top edge

    float focal;            // camera distance; smaller = stronger perspective
    float progress;         // eased, 0 = flat .. 1 = fully bent
    float blurAmount;       // 0..1 opacity of the progressive blur layers
    float shadeAmount;      // 0..1 opacity of the shade overlay

    float sheen;
    float saturation;
    float grain;
    float time;

    float vignette;
    float feather;          // fraction of the panel feathered at the far edge
    float panelTop;         // screen-space y of the panel's far edge, 0..1
    float pad1;

    float4 tint;
};

// ---------------------------------------------------------------- background

struct BgOut {
    float4 pos [[position]];
    float2 uv;
};

vertex BgOut bg_vertex(uint vid [[vertex_id]])
{
    float2 p[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    BgOut o;
    o.pos = float4(p[vid], 0.0, 1.0);
    o.uv = p[vid] * 0.5 + 0.5;      // uv.y = 1 at the top of the screen
    return o;
}

fragment float4 bg_fragment(BgOut in [[stage_in]],
                            constant Uniforms &U [[buffer(0)]])
{
    float2 c = in.uv - 0.5;
    c.x *= U.aspect;
    float d = length(c);
    float v = 1.0 - U.vignette * smoothstep(0.10, 0.95, d);

    float3 col = float3(0.018, 0.020, 0.026) * v;

    // Light spilling out of the hinge as the panel leans away.
    float2 h = in.uv - float2(0.5, U.hingeV);
    h.x *= U.aspect * 0.45;
    h.y *= 2.6;
    float g = exp(-dot(h, h) * 7.0) * U.progress;
    col += float3(0.30, 0.33, 0.40) * g * 0.22;

    // Soft spill above the far edge, so the space the panel vacates keeps a
    // sense of depth instead of going flat black.
    float above = max(in.uv.y - U.panelTop, 0.0);
    float falloff = exp(-above * 8.0);
    float sides = 1.0 - smoothstep(0.25, 0.72, abs(in.uv.x - 0.5));
    col += float3(0.22, 0.24, 0.32) * falloff * sides * U.progress * 0.42;

    return float4(col, 1.0);
}

// ---------------------------------------------------------------------- blur

struct BlurOut {
    float4 pos [[position]];
    float2 uv;
};

vertex BlurOut blur_vertex(uint vid [[vertex_id]])
{
    float2 p[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    BlurOut o;
    o.pos = float4(p[vid], 0.0, 1.0);
    float2 uv = p[vid] * 0.5 + 0.5;
    o.uv = float2(uv.x, 1.0 - uv.y);   // texture origin is top-left
    return o;
}

// dir.xy = one texel step along the blur axis, dir.z = radius multiplier
fragment float4 blur_fragment(BlurOut in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              constant float4 &dir [[buffer(0)]])
{
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float2 step = dir.xy * dir.z;

    const float w0 = 0.2270270270;
    const float w1 = 0.3162162162;
    const float w2 = 0.0702702703;
    const float o1 = 1.3846153846;
    const float o2 = 3.2307692308;

    float3 sum = src.sample(smp, in.uv).rgb * w0;
    sum += src.sample(smp, in.uv + step * o1).rgb * w1;
    sum += src.sample(smp, in.uv - step * o1).rgb * w1;
    sum += src.sample(smp, in.uv + step * o2).rgb * w2;
    sum += src.sample(smp, in.uv - step * o2).rgb * w2;
    return float4(sum, 1.0);
}

// ---------------------------------------------------------------------- bend

struct BendOut {
    float4 pos [[position]];
    float2 uv;
    float  along;     // 0 at the bend line, 1 at the far edge
};

vertex BendOut bend_vertex(uint vid [[vertex_id]],
                           constant float2 *grid [[buffer(0)]],
                           constant Uniforms &U [[buffer(1)]])
{
    float2 g = grid[vid];
    float u = g.x;
    float v = g.y;

    float wx = (u - 0.5) * U.aspect;
    float s  = v - U.hingeV;              // arc length measured along the surface

    // Bend the panel over a circular arc of radius r, then continue straight.
    // This keeps the surface C1 so there is no visible crease.
    float r = max(U.bendRadius, 0.0005);
    float arc = r * U.theta;

    float ry, rz;
    if (s <= 0.0) {
        ry = s;
        rz = 0.0;
    } else if (s < arc) {
        float phi = s / r;
        ry = r * sin(phi);
        rz = -r * (1.0 - cos(phi));
    } else {
        float ex = s - arc;
        ry = r * sin(U.theta) + ex * cos(U.theta);
        rz = -r * (1.0 - cos(U.theta)) - ex * sin(U.theta);
    }

    // The bend line stays put on screen; everything above it leans away.
    float py = ry - (0.5 - U.hingeV);

    // Perspective divide happens on the GPU: clip.w carries the depth, so the
    // texture coordinates stay perspective-correct across the whole panel.
    float w = (U.focal - rz) / U.focal;

    BendOut o;
    o.pos = float4(wx / (U.aspect * 0.5), py / 0.5, 0.0, w);
    o.uv = float2(u, 1.0 - v);

    float span = max(1.0 - U.hingeV, 0.0005);
    o.along = clamp(s / span, 0.0, 1.0);
    return o;
}

fragment float4 bend_fragment(BendOut in [[stage_in]],
                              texture2d<float> sharp [[texture(0)]],
                              texture2d<float> soft1 [[texture(1)]],
                              texture2d<float> soft2 [[texture(2)]],
                              texture2d<float> soft3 [[texture(3)]],
                              constant Uniforms &U [[buffer(0)]])
{
    constexpr sampler smp(filter::linear, address::clamp_to_edge);

    float p = U.progress;
    float d = 1.0 - in.along;          // 0 at the far edge, 1 at the bend line

    // Progressive blur: three copies, each blurred harder and confined to a
    // shorter band below the far edge, so sharpness falls off smoothly
    // toward the top while the base stays crisp.
    float3 c = sharp.sample(smp, in.uv).rgb;
    float layer = U.blurAmount * p;
    float w1 = (1.0 - smoothstep(0.30, 0.75, d)) * layer;
    float w2 = (1.0 - smoothstep(0.15, 0.52, d)) * layer;
    float w3 = (1.0 - smoothstep(0.06, 0.34, d)) * layer;
    c = mix(c, soft1.sample(smp, in.uv).rgb, w1);
    c = mix(c, soft2.sample(smp, in.uv).rgb, w2);
    c = mix(c, soft3.sample(smp, in.uv).rgb, w3);

    // Shade: dark pools in the far corners plus a wash down from the far edge.
    float2 q = float2(in.uv.x, d);
    float r1 = length(float2(q.x / 1.2, q.y / 0.6));
    float r2 = length(float2((1.0 - q.x) / 1.2, q.y / 0.6));
    float a1 = 0.55 * saturate(1.0 - r1 / 0.6);
    float a2 = 0.55 * saturate(1.0 - r2 / 0.6);
    float a3 = 0.35 * saturate(1.0 - d / 0.45);
    float keep = (1.0 - a1) * (1.0 - a2) * (1.0 - a3);
    c *= mix(1.0, keep, saturate(U.shadeAmount * p));

    // A sheen band that travels up the panel as it folds.
    float bandPos = mix(1.25, -0.25, p);
    float b = (in.along - bandPos) * 3.0;
    c += U.sheen * exp(-b * b) * p;

    float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
    c = mix(float3(lum), c, U.saturation) * U.tint.rgb;

    if (U.grain > 0.0) {
        float n = fract(sin(dot(in.uv * 900.0 + U.time, float2(12.9898, 78.233))) * 43758.5453);
        c += (n - 0.5) * U.grain;
    }

    // Feather the far edge: a band that grows with the bend fades from fully
    // soft at the edge to fully sharp, so the silhouette softens with the
    // pixels instead of ending in a hard line.
    float alpha = 1.0;
    float t = U.feather * p;
    if (t > 0.0001) {
        float x = saturate(d / t);
        alpha = x < 0.25 ? x
              : x < 0.55 ? 0.25 + (x - 0.25) * (0.40 / 0.30)
              : 0.65 + (x - 0.55) * (0.35 / 0.45);
    }

    return float4(max(c, 0.0), alpha);
}
"""
}
