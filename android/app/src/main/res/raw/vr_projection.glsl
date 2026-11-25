#extension GL_OES_EGL_image_external : require
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
varying vec2 screenPos;
uniform samplerExternalOES movie;
uniform mat4 textureTransform;
uniform mat4 cameraToWorld;
uniform int projection;
uniform vec2 lens;
uniform vec2 rayExtent;
uniform vec2 fit;
uniform vec2 fisheyeDisc;
uniform vec2 texelInset;
// Normalized bounds in the untransformed texture; (0,0) is the image's bottom left.
uniform vec4 eyeRect;

const float PI = 3.141592653589793;
const int FLAT = 0;
const int EQUIRECT_180 = 1;
const int FISHEYE_180 = 3;

void main() {
    // Inverse pixel mapping for the generic Cardboard v1 lens, also used in iOS.
    vec2 lensPosition = screenPos * lens;
    float radius2 = dot(lensPosition, lensPosition);
    vec2 imagePlane = screenPos * (1.0 + radius2 * (0.441 + 0.156 * radius2));
    vec2 uv;

    if (projection == FLAT) {
        vec2 p = imagePlane / fit;
        if (max(abs(p.x), abs(p.y)) > 1.0) {
            gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0);
            return;
        }
        uv = p * 0.5 + 0.5;
    } else {
        vec3 direction = normalize(mat3(cameraToWorld) * vec3(imagePlane * rayExtent, -1.0));
        if ((projection == EQUIRECT_180 || projection == FISHEYE_180) && direction.z > 0.00001) {
            // A 180-degree movie has no image behind the viewer.
            gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0);
            return;
        }
        if (projection == FISHEYE_180) {
            // The equidistant image circle fills the shorter dimension of one eye.
            float theta = acos(clamp(-direction.z, -1.0, 1.0));
            float transverse = length(direction.xy);
            vec2 radial = direction.xy / max(transverse, 0.00001);
            uv = vec2(0.5) + radial * (theta / PI) * fisheyeDisc;
        } else {
            // The center of an equirectangular atlas faces -Z. Longitude wraps
            // at the back of the 360 sphere; latitude is defined at both poles.
            float longitude = dot(direction.xz, direction.xz) > 0.0000001
                    ? atan(direction.x, -direction.z) : 0.0;
            float latitude = asin(clamp(direction.y, -1.0, 1.0));
            float longitudeSpan = projection == EQUIRECT_180 ? PI : 2.0 * PI;
            uv = vec2(0.5 + longitude / longitudeSpan, 0.5 + latitude / PI);
        }
    }

    // Sample only this eye, then apply the decoder's crop and vertical flip once.
    vec2 packedUV = clamp(mix(eyeRect.xy, eyeRect.zw, uv),
                          eyeRect.xy + texelInset, eyeRect.zw - texelInset);
    vec2 sampleUV = (textureTransform * vec4(packedUV, 0.0, 1.0)).xy;
    gl_FragColor = vec4(texture2D(movie, sampleUV).rgb, 1.0);
}
