#include "CLumatteNative.h"
#include "../../../../native/mobile-film/mobile_film_core.hpp"
#include <cstring>
#include <string>

namespace {

void write_error(char* error_buf, size_t error_buf_len, const char* message) {
    if (!error_buf || error_buf_len == 0) return;
    std::strncpy(error_buf, message ? message : "Unknown native error", error_buf_len - 1);
    error_buf[error_buf_len - 1] = '\0';
}

std::vector<float> copy_checked(const float* src, size_t count) {
    if (count == 0) return {};
    if (!src) throw std::invalid_argument("Null float array pointer");
    std::vector<float> out(src, src + count);
    for (float v : out) {
        if (!std::isfinite(v)) throw std::invalid_argument("Non-finite float in native table");
    }
    return out;
}

lfm::mobile::Table make_film_stage(const float* values, int32_t n, const float* range6) {
    if (n < 2 || n > 65) throw std::invalid_argument("Mobile film table dimension unsupported");
    lfm::mobile::Table result{n, {}, {}, {}};
    for (int c = 0; c < 3; ++c) {
        result.minimum[c] = range6[c];
        result.maximum[c] = range6[3 + c];
        if (!(result.maximum[c] > result.minimum[c]) || !std::isfinite(result.maximum[c] - result.minimum[c]))
            throw std::invalid_argument("Mobile film table range invalid");
    }
    result.values = copy_checked(values, size_t(n) * n * n * 3);
    return result;
}

lfm::mobile::Effects parse_film_effects(const float* raw_controls) {
    const auto values = copy_checked(raw_controls, 60);
    if ((values[0] != 0 && values[0] != .125f && values[0] != .25f && values[0] != .5f) ||
        (values[1] != 0 && values[1] != 1) || values[2] < -3 || values[2] > 3 ||
        (values[3] != 0 && values[3] != 1) || values[4] < .0001f || values[4] > 10 || values[23] < 10 || values[23] > 100)
        throw std::invalid_argument("Mobile film controls invalid");
    lfm::mobile::Effects result{};
    result.diffusion = values[0];
    result.halation = values[1] == 1;
    result.exposure_gain = std::pow(2.f, values[2]);
    result.grain = values[3] == 1;
    result.particle_area = values[4];
    result.format_mm = values[23];
    if ((values[24] != 0 && values[24] != 1) || values[25] < 1 || values[25] > 8 ||
        values[25] != std::floor(values[25]) || values[26] < 0 || values[26] > 1 || values[27] < 0 || values[27] > 40)
        throw std::invalid_argument("Mobile spatial profile invalid");
    result.cinestill = values[24] == 1;
    result.halation_bounces = int(values[25]);
    if (values[59] < 0 || values[59] > 2 || (!result.cinestill && values[59] != 0))
        throw std::invalid_argument("Invalid CineStill JPEG halation look");
    result.remjet_look = values[59];
    if (result.cinestill) {
        for (int c = 0; c < 3; ++c) {
            result.fotu_sigma_mm[c] = values[38 + c];
            if (values[38 + c] < .000001f || values[38 + c] > 2)
                throw std::invalid_argument("Invalid physical halation sigma");
            float weights = 0, matrix = 0;
            for (int j = 0; j < 3; ++j) {
                const float weight = values[41 + 3 * c + j], routed = values[50 + 3 * c + j];
                if (weight < -1e-6f || weight > 1 || routed < 0 || routed > 1)
                    throw std::invalid_argument("Invalid physical halation matrix");
                result.fotu_weights[c][j] = weight;
                result.fotu_matrix[c][j] = routed;
                weights += weight;
                matrix += routed;
            }
            if (std::abs(weights - 1) > 1e-5f || matrix > 1)
                throw std::invalid_argument("Invalid physical halation partition");
        }
    }
    result.halation_decay = values[26];
    result.grain_spacing_um = values[27];
    if (values[28] < 0 || values[28] > 1) throw std::invalid_argument("Invalid scatter amount");
    result.scatter_amount = values[28];
    for (int c = 0; c < 3; ++c) {
        result.scatter_core_um[c] = values[29 + c];
        result.scatter_tail_um[c] = values[32 + c];
        result.scatter_tail_weight[c] = values[35 + c];
        if (values[29 + c] < 0 || values[29 + c] > 1000 || values[32 + c] < 0 || values[32 + c] > 1000 ||
            values[35 + c] < 0 || values[35 + c] > 1)
            throw std::invalid_argument("Invalid emulsion scatter profile");
    }
    for (int c = 0; c < 3; ++c) {
        result.particle_scale[c] = values[5 + c];
        result.floor[c] = values[8 + c];
        result.uniformity[c] = values[11 + c];
        result.density_max[c] = values[14 + c];
        result.halation_strength[c] = values[17 + c];
        result.halation_sigma_um[c] = values[20 + c];
        if (result.particle_scale[c] < .0001f || result.particle_scale[c] > 20 || result.floor[c] < 0 || result.floor[c] > 1 ||
            result.uniformity[c] < 0 || result.uniformity[c] > 1 || result.density_max[c] <= 0 || result.density_max[c] > 10 ||
            result.halation_strength[c] < 0 || result.halation_strength[c] > 2 || result.halation_sigma_um[c] < 0 || result.halation_sigma_um[c] > 1000)
            throw std::invalid_argument("Mobile film effect channels invalid");
    }
    return result;
}

struct LutTable {
    int one_size = 0, three_size = 0;
    float strength = 0;
    std::vector<float> one, three, bounds;

    static LutTable read(int32_t one_size, int32_t three_size, const float* one_ptr,
                         const float* three_ptr, const float* bounds_ptr, float strength) {
        if (!std::isfinite(strength) || strength < 0 || strength > 1)
            throw std::invalid_argument("LUT strength is outside 0..1");
        if (strength == 0 || (one_size == 0 && three_size == 0)) return {};
        if ((one_size != 0 && (one_size < 2 || one_size > 65536)) ||
            (three_size != 0 && (three_size < 2 || three_size > 65)))
            throw std::invalid_argument("Unsupported LUT table dimensions");
        LutTable table;
        table.one_size = one_size;
        table.three_size = three_size;
        table.strength = strength;
        table.one = copy_checked(one_ptr, size_t(one_size) * 3);
        table.three = copy_checked(three_ptr, size_t(three_size) * three_size * three_size * 3);
        table.bounds = copy_checked(bounds_ptr, 13);
        if (table.bounds[12] != 0.0f && (one_size != 0 || three_size != 17))
            throw std::invalid_argument("Invalid VLT grid");
        for (int c = 0; c < 3; ++c)
            if (!(table.bounds[3 + c] > table.bounds[c]) || !(table.bounds[9 + c] > table.bounds[6 + c]))
                throw std::invalid_argument("Invalid LUT input range");
        return table;
    }

    static float coordinate(float value, float minimum, float maximum, int size) {
        const float position = (value - minimum) / (maximum - minimum);
        if (std::isnan(position)) throw std::runtime_error("LUT range arithmetic produced an invalid colour");
        return std::clamp(position, 0.0f, 1.0f) * float(size - 1);
    }

    void apply(std::array<float, 3>& input) const {
        if (strength == 0) return;
        auto output = input;
        if (one_size != 0) {
            for (int c = 0; c < 3; ++c) {
                const float position = coordinate(input[c], bounds[c], bounds[3 + c], one_size);
                const int lower = int(std::floor(position)), upper = std::min(lower + 1, one_size - 1);
                const float fraction = position - float(lower);
                output[c] = one[size_t(lower) * 3 + c] * (1.0f - fraction) + one[size_t(upper) * 3 + c] * fraction;
            }
        }
        if (three_size != 0) {
            auto position = [&](int c) {
                if (bounds[12] == 0.0f) return coordinate(output[c], bounds[6 + c], bounds[9 + c], three_size);
                const float v = std::clamp(output[c], 0.0f, 1.0f) * 4095.0f;
                return v <= 3840.0f ? v / 256.0f : 15.0f + (v - 3840.0f) / 255.0f;
            };
            const float r = position(0), g = position(1), b = position(2);
            const int r0 = int(std::floor(r)), g0 = int(std::floor(g)), b0 = int(std::floor(b));
            const int r1 = std::min(r0 + 1, three_size - 1), g1 = std::min(g0 + 1, three_size - 1), b1 = std::min(b0 + 1, three_size - 1);
            const float fr = r - float(r0), fg = g - float(g0), fb = b - float(b0);
            auto index = [&](int x, int y, int z) { return size_t(x + three_size * (y + three_size * z)) * 3; };
            const size_t i000 = index(r0, g0, b0), i100 = index(r1, g0, b0), i010 = index(r0, g1, b0), i110 = index(r1, g1, b0);
            const size_t i001 = index(r0, g0, b1), i101 = index(r1, g0, b1), i011 = index(r0, g1, b1), i111 = index(r1, g1, b1);
            for (int c = 0; c < 3; ++c) {
                const float low = (three[i000 + c] * (1.0f - fr) + three[i100 + c] * fr) * (1.0f - fg) +
                    (three[i010 + c] * (1.0f - fr) + three[i110 + c] * fr) * fg;
                const float high = (three[i001 + c] * (1.0f - fr) + three[i101 + c] * fr) * (1.0f - fg) +
                    (three[i011 + c] * (1.0f - fr) + three[i111 + c] * fr) * fg;
                output[c] = low * (1.0f - fb) + high * fb;
            }
        }
        for (int c = 0; c < 3; ++c) input[c] += (output[c] - input[c]) * strength;
    }
};

} // namespace

extern "C" int lumatte_render_film_rgba8888(
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
) {
    try {
        if (!pixels || width == 0 || height == 0 || uint64_t(stride) < uint64_t(width) * 4 ||
            source_width <= 0 || source_height <= 0 || !bounds18 || !controls60) {
            throw std::invalid_argument("Invalid mobile film request");
        }
        const auto ranges = copy_checked(bounds18, 18);
        lfm::mobile::Model model{
            make_film_stage(response_table, response_size, ranges.data()),
            make_film_stage(development_table, development_size, ranges.data() + 6),
            make_film_stage(scan_table, scan_size, ranges.data() + 12)
        };
        const auto effects = parse_film_effects(controls60);
        const lfm::mobile::Image image{pixels, width, height, stride};
        lfm::mobile::render_cpu(
            image,
            model,
            effects,
            uint32_t(source_width),
            uint32_t(source_height),
            seed,
            [] {}
        );
        return 0;
    } catch (const std::exception& e) {
        write_error(error_buf, error_buf_len, e.what());
        return -1;
    } catch (...) {
        write_error(error_buf, error_buf_len, "Mobile film rendering failed");
        return -1;
    }
}

extern "C" int lumatte_render_lut_rgba8888(
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
) {
    try {
        if (!pixels || width == 0 || height == 0 || uint64_t(stride) < uint64_t(width) * 4 ||
            source_width <= 0 || source_height <= 0 || !std::isfinite(grain) || grain < 0 || grain > 1) {
            throw std::invalid_argument("Invalid LUT render request");
        }
        const LutTable first = LutTable::read(first_one_size, first_three_size, first_one, first_three, first_bounds13, first_strength);
        const LutTable second = LutTable::read(second_one_size, second_three_size, second_one, second_three, second_bounds13, second_strength);

        for (uint32_t y = 0; y < height; ++y) {
            auto* row = pixels + size_t(y) * stride;
            for (uint32_t x = 0; x < width; ++x) {
                auto* pixel = row + size_t(x) * 4;
                std::array<float, 3> rgb{pixel[0] / 255.0f, pixel[1] / 255.0f, pixel[2] / 255.0f};
                first.apply(rgb);
                second.apply(rgb);
                if (grain > 0) {
                    const uint32_t sx = uint32_t(uint64_t(x) * uint32_t(source_width) / width / 3);
                    const uint32_t sy = uint32_t(uint64_t(y) * uint32_t(source_height) / height / 3);
                    uint32_t hash = uint32_t(seed) ^ (sx * 73856093u) ^ (sy * 19349663u);
                    hash = (hash ^ (hash >> 16)) * uint32_t(-2048144789);
                    hash = (hash ^ (hash >> 13)) * uint32_t(-1028477387);
                    hash ^= hash >> 16;
                    const float light = std::clamp(.2126f * rgb[0] + .7152f * rgb[1] + .0722f * rgb[2], 0.0f, 1.0f);
                    const float noise = (float((hash >> 8) & 65535u) / 65535.0f - .5f) * grain * .12f * (.35f + .65f * (1.0f - light));
                    for (float& channel : rgb) channel += noise;
                }
                if (dithering) {
                    static constexpr int bayer[16] = {0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5};
                    const float noise = ((float(bayer[(y & 3u) * 4u + (x & 3u)]) + .5f) / 16.0f - .5f) / 255.0f;
                    for (float& channel : rgb) channel += noise;
                }
                for (int c = 0; c < 3; ++c) {
                    if (std::isnan(rgb[c])) throw std::runtime_error("LUT arithmetic produced an invalid colour");
                    pixel[c] = uint8_t(std::lround(std::clamp(rgb[c], 0.0f, 1.0f) * 255.0f));
                }
            }
        }
        return 0;
    } catch (const std::exception& e) {
        write_error(error_buf, error_buf_len, e.what());
        return -1;
    } catch (...) {
        write_error(error_buf, error_buf_len, "LUT rendering failed");
        return -1;
    }
}
