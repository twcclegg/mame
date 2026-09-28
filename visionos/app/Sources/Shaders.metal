// license:BSD-3-Clause
//
// Draws the latest MAME frame as an aspect-fit quad.  This is the hook for
// later upscaling / CRT passes (goal 4): swap the fragment shader or add
// passes that read `frame`.

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// scale.xy: quad size in normalized device coordinates (aspect fit)
vertex VertexOut frame_vertex(uint vid [[vertex_id]], constant float2 &scale [[buffer(0)]])
{
    // triangle strip covering the quad
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    const float2 uvs[4]     = { float2(0, 1),   float2(1, 1),  float2(0, 0),  float2(1, 0) };
    VertexOut out;
    out.position = float4(corners[vid] * scale, 0, 1);
    out.uv = uvs[vid];
    return out;
}

fragment float4 frame_fragment(VertexOut in [[stage_in]],
                               texture2d<float> frame [[texture(0)]],
                               sampler smp [[sampler(0)]])
{
    // libmame's software renderer leaves the alpha byte undefined
    return float4(frame.sample(smp, in.uv).rgb, 1.0);
}
