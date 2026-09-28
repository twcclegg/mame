// license:BSD-3-Clause
//
// Presentation shaders for MAME frames.
//
// apply_effect() is shared by the flat-window path (frame_vertex /
// frame_fragment, drawing into an MTKView) and the theater path
// (present_kernel, writing into a RealityKit LowLevelTexture), so both look
// the same.
//
// Effects (keep in sync with ScreenEffect in AppModel.swift):
//   0  pixels  - nearest neighbour, crisp but uneven at non-integer scales
//   1  sharp   - "sharp bilinear": integer-prescale then bilinear, crisp and even
//   2  crt     - sharp base + gaussian scanlines + RGB aperture mask

#include <metal_stdlib>
using namespace metal;

struct PresentParams {
    float2 src_size;    // source frame size in pixels
    float2 dst_size;    // output size in pixels
    float2 scale;       // quad size in NDC (aspect fit), vertex stage only
    int    effect;
};

constexpr sampler nearest_sampler(filter::nearest, address::clamp_to_edge);
constexpr sampler linear_sampler(filter::linear, address::clamp_to_edge);

static float3 sharp_bilinear(texture2d<float> src, float2 uv, float2 src_size, float2 dst_size)
{
    float2 texel = uv * src_size;
    float2 scale = max(floor(dst_size / src_size), float2(1.0));
    float2 region = 0.5 - 0.5 / scale;
    float2 center_dist = fract(texel) - 0.5;
    float2 f = (center_dist - clamp(center_dist, -region, region)) * scale + 0.5;
    return src.sample(linear_sampler, (floor(texel) + f) / src_size).rgb;
}

static float3 crt(texture2d<float> src, float2 uv, float2 src_size, float2 dst_size, float2 dst_pixel)
{
    float3 color = sharp_bilinear(src, uv, src_size, dst_size);

    // scanlines: gaussian beam profile across each source row, brighter
    // pixels bloom wider (the classic "beam width" look)
    float row_pos = fract(uv.y * src_size.y) - 0.5;
    float luma = dot(color, float3(0.299, 0.587, 0.114));
    float width = mix(0.28, 0.45, luma);
    float beam = exp(-(row_pos * row_pos) / (2.0 * width * width));
    color *= mix(0.35, 1.15, beam);

    // aperture grille mask on output pixels (only meaningful when the output
    // is at least ~3x the source)
    if (dst_size.x / src_size.x >= 3.0) {
        int triad = int(dst_pixel.x) % 3;
        float3 mask = float3(0.75);
        mask[triad] = 1.2;
        color *= mask;
    }
    return saturate(color);
}

static float3 apply_effect(texture2d<float> src, float2 uv, constant PresentParams &p, float2 dst_pixel)
{
    switch (p.effect) {
    case 1:  return sharp_bilinear(src, uv, p.src_size, p.dst_size);
    case 2:  return crt(src, uv, p.src_size, p.dst_size, dst_pixel);
    default: return src.sample(nearest_sampler, uv).rgb;
    }
}

// --- flat window (MTKView) ---------------------------------------------------

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut frame_vertex(uint vid [[vertex_id]], constant PresentParams &p [[buffer(0)]])
{
    // triangle strip covering the aspect-fit quad
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    const float2 uvs[4]     = { float2(0, 1),   float2(1, 1),  float2(0, 0),  float2(1, 0) };
    VertexOut out;
    out.position = float4(corners[vid] * p.scale, 0, 1);
    out.uv = uvs[vid];
    return out;
}

fragment float4 frame_fragment(VertexOut in [[stage_in]],
                               texture2d<float> frame [[texture(0)]],
                               constant PresentParams &p [[buffer(0)]])
{
    // libmame's software renderer leaves the alpha byte undefined: force opaque
    return float4(apply_effect(frame, in.uv, p, in.position.xy), 1.0);
}

// --- theater (RealityKit LowLevelTexture) ------------------------------------

kernel void present_kernel(texture2d<float> frame [[texture(0)]],
                           texture2d<float, access::write> out [[texture(1)]],
                           constant PresentParams &p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= out.get_width() || gid.y >= out.get_height())
        return;
    float2 uv = (float2(gid) + 0.5) / float2(out.get_width(), out.get_height());
    out.write(float4(apply_effect(frame, uv, p, float2(gid)), 1.0), gid);
}
