#include <metal_stdlib>
using namespace metal;

struct SBSVertex {
    float2 position;
    float2 movieUV;
};

struct SBSVaryings {
    float4 position [[position]];
    float2 movieUV;
};

vertex SBSVaryings sbsMovieVertex(uint index [[vertex_id]],
                                  constant SBSVertex *vertices [[buffer(0)]]) {
    SBSVertex point = vertices[index];
    return {float4(point.position, 0, 1), point.movieUV};
}

fragment float4 sbsMovieFragment(SBSVaryings input [[stage_in]],
                                 texture2d<float> movie [[texture(0)]],
                                 constant float &eyeStart [[buffer(0)]]) {
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    // Clamp to actual texel centers. If a scaled frame is odd in width,
    // discard its ambiguous center column rather than sample the other eye.
    float width = float(movie.get_width());
    float eyeWidth = floor(width * 0.5f);
    float first = eyeStart == 0 ? 0 : width - eyeWidth;
    float u = (first + clamp(input.movieUV.x * eyeWidth, 0.5f, eyeWidth - 0.5f)) / width;
    return float4(movie.sample(linearSampler, float2(u, input.movieUV.y)).rgb, 1);
}
