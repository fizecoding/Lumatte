#ifndef CLUMATTE_NATIVE_H
#define CLUMATTE_NATIVE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Renders the 3-stage Lumatte mobile film pipeline in-place on an RGBA8888 pixel buffer.
/// Uses the exact C++20 `lfm::mobile::render_cpu` implementation from `native/mobile-film/mobile_film_core.hpp`.
/// Returns 0 on success, non-zero on error (writing a message to `error_buf`).
int lumatte_render_film_rgba8888(
    uint8_t* pixels,
    uint32_t width,
    uint32_t height,
    uint32_t stride,
    const float* response_table,
    int32_t response_size,
    const float* development_table,
    int32_t development_size,
    const float* scan_table,
    int32_t scan_size,
    const float* bounds18,
    const float* controls60,
    int32_t source_width,
    int32_t source_height,
    uint64_t seed,
    char* error_buf,
    size_t error_buf_len
);

/// Renders the Lumatte dual-slot LUT + luminance grain + 4x4 Bayer dithering pipeline in-place on an RGBA8888 pixel buffer.
/// Uses the exact C++20 algorithm from `native/lut/lut_jni.cpp`.
/// Returns 0 on success, non-zero on error (writing a message to `error_buf`).
int lumatte_render_lut_rgba8888(
    uint8_t* pixels,
    uint32_t width,
    uint32_t height,
    uint32_t stride,
    int32_t first_one_size,
    int32_t first_three_size,
    const float* first_one,
    const float* first_three,
    const float* first_bounds13,
    float first_strength,
    int32_t second_one_size,
    int32_t second_three_size,
    const float* second_one,
    const float* second_three,
    const float* second_bounds13,
    float second_strength,
    float grain,
    int32_t source_width,
    int32_t source_height,
    int32_t seed,
    bool dithering,
    char* error_buf,
    size_t error_buf_len
);

#ifdef __cplusplus
}
#endif

#endif /* CLUMATTE_NATIVE_H */
