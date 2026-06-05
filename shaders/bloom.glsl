#version 450
#extension GL_EXT_samplerless_texture_functions: require

#include <generated.glsl>

const int M = BLUR_RADIUS;
const int N = M * 2 + 1;

#if defined(COMPUTE)
layout(local_size_x = DIM_X, local_size_y = DIM_Y) in;

layout(set = 0, binding = 0) uniform texture2D in_texture;
layout(set = 1, binding = 0, rgba16f) writeonly uniform image2D out_texture;

#if !defined(CACHE) && defined(NAIVE)
void main() {
    const ivec2 texel_coord = ivec2(gl_GlobalInvocationID.xy);
    const ivec2 img_size = textureSize(in_texture, 0);

    if (texel_coord.x >= img_size.x || texel_coord.y >= img_size.y) {
        return;
    }

    vec4 sum = vec4(0.0);

    for (int y = 0; y < N; y++) {
        for (int x = 0; x < N; x++) {
            ivec2 offset = ivec2(x - M, y - M);
            ivec2 sample_coord = texel_coord + offset;
            sample_coord = clamp(sample_coord, ivec2(0, 0), img_size - 1);
            sum += kernel_gaussian[abs(offset.x)] *
                    kernel_gaussian[abs(offset.y)] *
                    texelFetch(in_texture, sample_coord, 0);
        }
    }

    imageStore(out_texture, texel_coord, sum);
}
#endif // NO_CACHE and NAIVE

#if !defined(CACHE) && (defined (HORIZONTAL) || defined(VERTICAL))
void main() {
    const ivec2 texel_coord = ivec2(gl_GlobalInvocationID.xy);
    const ivec2 img_size = textureSize(in_texture, 0);

    if (texel_coord.x >= img_size.x || texel_coord.y >= img_size.y) {
        return;
    }

    vec4 sum = vec4(0.0);

    for (int i = 0; i < N; i++) {
        int i_minus_m = i - M;

        #if defined(HORIZONTAL)
        ivec2 sample_coord = ivec2(texel_coord.x + i_minus_m, texel_coord.y);
        #else
        ivec2 sample_coord = ivec2(texel_coord.x, texel_coord.y + i_minus_m);
        #endif

        sample_coord = clamp(sample_coord, ivec2(0, 0), img_size - 1);
        sum += kernel_gaussian[abs(i_minus_m)] * texelFetch(in_texture, sample_coord, 0);
    }

    imageStore(out_texture, texel_coord, sum);
}
#endif // NO_CACHE and (HORIZONTAL or VERTICAL)

#if defined(CACHE) && (defined(HORIZONTAL) || defined(VERTICAL))
#if (DIM_X != DIM_Y || DIM_Z != 1)
#error "This shader must be compiled for a square workgroup"
#endif

const int cache_s = DIM_Y;
const int cache_l = DIM_X + M * 2;
shared vec4 cache[cache_s][cache_l];

void main() {
    const ivec2 texel_coord = ivec2(gl_GlobalInvocationID.xy);
    const ivec2 img_size = textureSize(in_texture, 0);

    const ivec2 tile_base = ivec2(gl_WorkGroupID.xy) * DIM_X;
    #if defined(HORIZONTAL)
    const ivec2 cc = ivec2(gl_LocalInvocationID.yx);
    #else
    const ivec2 cc = ivec2(gl_LocalInvocationID.xy);
    #endif

    const int num_load_tiles = (cache_l + DIM_X - 1) / DIM_X;
    for (int i = 0; i < num_load_tiles; i++) {
        ivec2 cc_load = ivec2(i * DIM_X, 0) + cc;

        if (cc_load.x >= cache_l) break;

        #if defined(HORIZONTAL)
        ivec2 sample_coord = tile_base + cc_load - ivec2(M, 0);
        #else
        ivec2 sample_coord = tile_base + cc_load.yx - ivec2(0, M);
        #endif

        sample_coord = clamp(sample_coord, ivec2(0, 0), img_size - 1);
        cache[cc_load.y][cc_load.x] = texelFetch(in_texture, sample_coord, 0);
    }

    barrier();

    if (texel_coord.x >= img_size.x || texel_coord.y >= img_size.y) {
        return;
    }

    vec4 sum = vec4(0.0);

    for (int i = 0; i < N; i++) {
        sum += kernel_gaussian[abs(i - M)] * cache[cc.x][cc.y + i];
    }

    imageStore(out_texture, texel_coord, sum);
}
#endif // CACHE and (HORIZONTAL or VERTICAL)
#endif // COMPUTE

#if defined(FRAGMENT)
layout(location = 0) in vec2 in_uv;

layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D u_input_texture;

#if defined(PREFILTER)
#if !defined(BLOOM_PRE_THRESHOLD)
#define BLOOM_PRE_THRESHOLD 2.0
#endif
#if !defined(BLOOM_PRE_KNEE)
#define BLOOM_PRE_KNEE 2.0
#endif

#define EPSILON 0.00001

#include <color.glsl>

// https://www.desmos.com/calculator/0cw6zqclwh

void main() {
    vec3 color = texture(u_input_texture, in_uv).rgb;

    float luma = brightness(color);
    float soft = luma - BLOOM_PRE_THRESHOLD + BLOOM_PRE_KNEE;
    soft = clamp(soft, 0.0, 2.0 * BLOOM_PRE_KNEE);
    soft = soft * soft / (4.0 * BLOOM_PRE_KNEE + EPSILON);

    float contribution = max(soft, luma - BLOOM_PRE_THRESHOLD);
    contribution /= max(luma, EPSILON);

    out_color = vec4(color * contribution, 1.0);
}
#endif // PREFILTER

#if defined(COMPOSITE)
layout(set = 2, binding = 1) uniform sampler2D u_input_texture1;
layout(set = 2, binding = 2) uniform sampler2D u_input_texture2;
layout(set = 2, binding = 3) uniform sampler2D u_input_texture3;
layout(set = 2, binding = 4) uniform sampler2D u_input_texture4;

void main() {
    vec3 color = texture(u_input_texture, in_uv).rgb;
    color += texture(u_input_texture1, in_uv).rgb;
    color += texture(u_input_texture2, in_uv).rgb;
    color += texture(u_input_texture3, in_uv).rgb;
    color += texture(u_input_texture4, in_uv).rgb;
    out_color = vec4(color, 1.0);
}
#endif // COMPOSITE

#if defined(SAMPLE)
void main() {
    out_color = texture(u_input_texture, in_uv);
}
#endif // SAMPLE

#if defined(NAIVE)
void main() {
    vec2 t = 1.0 / textureSize(u_input_texture, 0);
    #if defined(PIXEL_SCALE)
    t *= PIXEL_SCALE;
    #endif
    vec4 sum = vec4(0.0);

    for (int y = 0; y < N; y++) {
        for (int x = 0; x < N; x++) {
            ivec2 offset = ivec2(x - M, y - M);
            vec2 sample_coord = in_uv + t * offset;
            sum += kernel_gaussian[abs(offset.x)] *
                    kernel_gaussian[abs(offset.y)] *
                    texture(u_input_texture, sample_coord);
        }
    }

    out_color = sum;
}
#endif // NAIVE

#if defined(HORIZONTAL) || defined(VERTICAL)
void main() {
    vec2 t = 1.0 / textureSize(u_input_texture, 0);
    #if defined(PIXEL_SCALE)
    t *= PIXEL_SCALE;
    #endif
    vec4 sum = vec4(0.0);

    for (int i = 0; i < N; i++) {
        int i_minus_m = i - M;
        #if defined(HORIZONTAL)
        ivec2 offset = ivec2(i_minus_m, 0);
        #else
        ivec2 offset = ivec2(0, i_minus_m);
        #endif
        vec2 sample_coord = in_uv + t * offset;
        sum += kernel_gaussian[abs(i_minus_m)] *
                texture(u_input_texture, sample_coord);
    }

    out_color = sum;
}
#endif // HORIZONTAL or VERTICAL

#if defined(KAWASE)
void main() {
    vec2 o = 0.5 / textureSize(u_input_texture, 0);

    vec4 sum = vec4(0.0);

    #if defined(UP)
    const float weight = 1.0 / 12.0;
    sum += texture(u_input_texture, in_uv + vec2(-2.0, 0.0) * o);
    sum += texture(u_input_texture, in_uv + vec2(2.0, 0.0) * o);
    sum += texture(u_input_texture, in_uv + vec2(0.0, -2.0) * o);
    sum += texture(u_input_texture, in_uv + vec2(0.0, 2.0) * o);
    sum += texture(u_input_texture, in_uv + vec2(-1.0, 1.0) * o) * 2.0;
    sum += texture(u_input_texture, in_uv + vec2(1.0, 1.0) * o) * 2.0;
    sum += texture(u_input_texture, in_uv + vec2(-1.0, -1.0) * o) * 2.0;
    sum += texture(u_input_texture, in_uv + vec2(1.0, -1.0) * o) * 2.0;
    #elif defined(DOWN)
    const float weight = 1.0 / 8.0;
    sum += texture(u_input_texture, in_uv) * 4.0;
    sum += texture(u_input_texture, in_uv + vec2(-1.0, -1.0) * o);
    sum += texture(u_input_texture, in_uv + vec2(1.0, -1.0) * o);
    sum += texture(u_input_texture, in_uv + vec2(-1.0, 1.0) * o);
    sum += texture(u_input_texture, in_uv + vec2(1.0, 1.0) * o);
    #else
    #error "Either UP or DOWN must be defined"
    #endif // UP elif DOWN

    out_color = sum * weight;
}
#endif // KAWASE

#if defined(JIMENEZ)
void main() {
    vec2 t = 1.0 / textureSize(u_input_texture, 0);
    #if defined(PIXEL_SCALE)
    t *= PIXEL_SCALE;
    #endif

    vec4 sum = vec4(0.0);

    #if defined(UP)
    const float weight = 1.0 / 16.0;
    sum += texture(u_input_texture, in_uv + vec2(-1.0, 1.0) * t);
    sum += texture(u_input_texture, in_uv + vec2(0.0, 1.0) * t) * 2.0;
    sum += texture(u_input_texture, in_uv + vec2(1.0, 1.0) * t);
    sum += texture(u_input_texture, in_uv + vec2(-1.0, 0.0) * t) * 2.0;
    sum += texture(u_input_texture, in_uv + vec2(0.0, 0.0) * t) * 4.0;
    sum += texture(u_input_texture, in_uv + vec2(1.0, 0.0) * t) * 2.0;
    sum += texture(u_input_texture, in_uv + vec2(-1.0, -1.0) * t);
    sum += texture(u_input_texture, in_uv + vec2(0.0, -1.0) * t) * 2.0;
    sum += texture(u_input_texture, in_uv + vec2(1.0, -1.0) * t);
    #elif defined(DOWN)
    const float weight = 1.0 / 32.0;
    sum += texture(u_input_texture, in_uv + vec2(-2.0, 2.0) * t);
    sum += texture(u_input_texture, in_uv + vec2(0.0, 2.0) * t) * 2.0;
    sum += texture(u_input_texture, in_uv + vec2(2.0, 2.0) * t);
    sum += texture(u_input_texture, in_uv + vec2(-2.0, 0.0) * t) * 2.0;
    sum += texture(u_input_texture, in_uv + vec2(0.0, 0.0) * t) * 4.0;
    sum += texture(u_input_texture, in_uv + vec2(2.0, 0.0) * t) * 2.0;
    sum += texture(u_input_texture, in_uv + vec2(-2.0, -2.0) * t);
    sum += texture(u_input_texture, in_uv + vec2(0.0, -2.0) * t) * 2.0;
    sum += texture(u_input_texture, in_uv + vec2(2.0, -2.0) * t);
    sum += texture(u_input_texture, in_uv + vec2(-1.0, 1.0) * t) * 4.0;
    sum += texture(u_input_texture, in_uv + vec2(1.0, 1.0) * t) * 4.0;
    sum += texture(u_input_texture, in_uv + vec2(-1.0, -1.0) * t) * 4.0;
    sum += texture(u_input_texture, in_uv + vec2(1.0, -1.0) * t) * 4.0;
    #else
    #error "Either UP or DOWN must be defined"
    #endif // UP elif DOWN

    out_color = sum * weight;
}
#endif // JIMENEZ
#endif // FRAGMENT
