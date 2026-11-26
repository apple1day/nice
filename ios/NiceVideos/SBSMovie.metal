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

struct MovieColor {
    float4 levels;
    float4 coefficients;
};

static float4 sampleMovie(texture2d<float> image, texture2d<float> chroma, float2 uv, constant MovieColor &color) {
    constexpr sampler sampling(coord::normalized, address::clamp_to_edge, filter::linear);
    const float4 value = image.sample(sampling, uv);
    if (color.levels.z == 0) return float4(value.rgb, 1); // Already BGRA.
    const float y = (value.r - color.levels.x) * color.levels.z;
    const float2 cbcr = (chroma.sample(sampling, uv).rg - color.levels.y) * color.levels.w;
    return float4(y + color.coefficients.x * cbcr.y,
                  y + dot(color.coefficients.yz, cbcr),
                  y + color.coefficients.w * cbcr.x, 1);
}

fragment float4 sbsMovieFragment(SBSVaryings input [[stage_in]],
                                 texture2d<float> movie [[texture(0)]],
                                 texture2d<float> chroma [[texture(1)]],
                                 constant MovieColor &color [[buffer(1)]],
                                 constant float2 &region [[buffer(0)]]) {
    // Clamp to actual texel centers. If a scaled frame is odd in width,
    // discard its ambiguous center column rather than sample the other eye.
    float width = float(movie.get_width());
    float sampleWidth = floor(width * region.y);
    float first = region.x == 0 ? 0 : width - sampleWidth;
    const float inset = min(0.5f * sampleWidth, 0.5f * width / float(chroma.get_width()));
    float u = (first + clamp(input.movieUV.x * sampleWidth, inset, sampleWidth - inset)) / width;
    return sampleMovie(movie, chroma, float2(u, input.movieUV.y), color);
}

struct VRMovieUniforms {
    float3x3 cameraToWorld;
    float4 rayAndLens;
    float4 fitAndDisc;
    float4 eyeRect;
    uint4 options;
};

fragment float4 vrMovieFragment(SBSVaryings input [[stage_in]],
                                texture2d<float> movie [[texture(0)]],
                                texture2d<float> chroma [[texture(1)]],
                                constant MovieColor &color [[buffer(1)]],
                                constant VRMovieUniforms &vr [[buffer(0)]]) {
    constexpr float pi = 3.14159265358979323846f;
    const float2 screen = (input.movieUV - 0.5f) * float2(2.0f, -2.0f);
    // Inverse sampling of the generic Cardboard v1 screen, using the same
    // 40-degree half-FOV and radial coefficients as the flat cinema mesh.
    const float2 lens = screen * vr.rayAndLens.zw;
    const float r2 = dot(lens, lens);
    const float2 plane = screen * (1.0f + r2 * (0.441f + 0.156f * r2));
    const uint projection = vr.options.x;
    float2 uv;
    if (projection == 0u) {
        const float2 fit = plane / vr.fitAndDisc.xy;
        if (any(abs(fit) > 1.0f)) return float4(0, 0, 0, 1);
        uv = 0.5f + fit * float2(0.5f, -0.5f);
    } else {
        const float3 ray = normalize(vr.cameraToWorld * float3(plane * vr.rayAndLens.xy, -1));
        if (projection != 2u && ray.z > 0.00001f) return float4(0, 0, 0, 1);
        if (projection == 3u) {
            const float theta = acos(clamp(-ray.z, -1.0f, 1.0f));
            const float2 radial = ray.xy / max(length(ray.xy), 0.00001f);
            uv = 0.5f + radial * float2(1, -1) * (theta / pi) * vr.fitAndDisc.zw;
        } else {
            const float longitude = dot(ray.xz, ray.xz) > 0.0000001f ? atan2(ray.x, -ray.z) : 0;
            uv = float2(0.5f + longitude / (projection == 1u ? pi : 2.0f * pi),
                        0.5f - asin(clamp(ray.y, -1.0f, 1.0f)) / pi);
        }
    }
    // Metal texture coordinates begin at the top-left. Keep interpolation
    // inside each eye, even when the two tiles meet at an odd pixel boundary.
    const float2 inset = min(0.5f * (vr.eyeRect.zw - vr.eyeRect.xy), 0.5f / float2(chroma.get_width(), chroma.get_height()));
    const float2 coord = clamp(mix(vr.eyeRect.xy, vr.eyeRect.zw, uv),
                               vr.eyeRect.xy + inset, vr.eyeRect.zw - inset);
    return sampleMovie(movie, chroma, coord, color);
}
