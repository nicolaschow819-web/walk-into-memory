#include <metal_stdlib>
using namespace metal;

// Fullscreen pass 1: ARKit camera image (Y + CbCr planes) -> drawable.
// UVs arrive pre-transformed by ARFrame.displayTransform on the CPU side.
struct CameraVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex CameraVertexOut cameraVertex(uint vid [[vertex_id]],
                                    constant float2 *positions [[buffer(0)]],
                                    constant float2 *uvs [[buffer(1)]]) {
    CameraVertexOut out;
    out.position = float4(positions[vid], 0, 1);
    out.uv = uvs[vid];
    return out;
}

fragment float4 cameraFragment(CameraVertexOut in [[stage_in]],
                               texture2d<float> texY [[texture(0)]],
                               texture2d<float> texCbCr [[texture(1)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float y = texY.sample(s, in.uv).r;
    float2 cbcr = texCbCr.sample(s, in.uv).rg - float2(0.5, 0.5);
    float r = y + 1.402 * cbcr.y;
    float g = y - 0.344 * cbcr.x - 0.714 * cbcr.y;
    float b = y + 1.772 * cbcr.x;
    return float4(r, g, b, 1.0);
}

// Fullscreen pass 2: composite the offscreen splat render over the camera image.
// Drawn with alpha blending enabled (srcAlpha, 1-srcAlpha).
struct CompositeVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex CompositeVertexOut compositeVertex(uint vid [[vertex_id]]) {
    // Triangle strip quad: (-1,-1) (1,-1) (-1,1) (1,1); uv y down matches texture space.
    float2 pos = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    CompositeVertexOut out;
    out.position = float4(pos, 0, 1);
    out.uv = float2((vid & 1) ? 1.0 : 0.0, (vid & 2) ? 0.0 : 1.0);
    return out;
}

fragment float4 compositeFragment(CompositeVertexOut in [[stage_in]],
                                  texture2d<float> splatTex [[texture(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    return splatTex.sample(s, in.uv);
}
