#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

#define DEFAULT_INPUT "/dev/video40"
#define DEFAULT_OUTPUT "/dev/video90"
#define DEFAULT_WIDTH 1288
#define DEFAULT_HEIGHT 800
#define DEFAULT_FRAME_RATE 30

struct buffer {
    void *start;
    size_t length;
};

struct options {
    const char *input;
    const char *output;
    const char *cfa;
    unsigned int width;
    unsigned int height;
    unsigned int fps;
    unsigned int frames;
    unsigned int phase_x;
    unsigned int phase_y;
    unsigned int red_gain;
    unsigned int green_gain;
    unsigned int blue_gain;
    unsigned int ir_subtract;
    unsigned int saturation;
    unsigned int contrast;
    unsigned int u_gain;
    unsigned int v_gain;
    int brightness;
    int u_offset;
    int v_offset;
    int hue_degrees;
    unsigned int target_luma;
    bool auto_wb;
    bool fast;
    bool mono;
    bool rotate_180;
};

struct frame_gains {
    unsigned int red;
    unsigned int green;
    unsigned int blue;
};

static void usage(const char *argv0)
{
    fprintf(stderr,
            "Usage: %s [options]\n"
            "\n"
            "Options:\n"
            "  -i, --input DEV       Input V4L2 capture node (default: %s)\n"
            "  -o, --output DEV      Output v4l2loopback node (default: %s)\n"
            "  -w, --width N         Frame width (default: %u)\n"
            "  -h, --height N        Frame height (default: %u)\n"
            "  -r, --fps N           Frame rate metadata (default: %u)\n"
            "  -n, --frames N        Stop after N frames (default: 0, run forever)\n"
            "  -c, --cfa NAME        CFA: grbg, rggb, bggr, gbrg,\n"
            "                        rgbir-yhrn, rgbir-yhrn180 (default: grbg)\n"
            "  -b, --bayer NAME      Alias for --cfa\n"
            "      --phase-x N       CFA horizontal phase offset 0..3 (default: 0)\n"
            "      --phase-y N       CFA vertical phase offset 0..3 (default: 0)\n"
            "      --red-gain N      Red gain in /1024 units (default: 1024)\n"
            "      --green-gain N    Green gain in /1024 units (default: 1024)\n"
            "      --blue-gain N     Blue gain in /1024 units (default: 1024)\n"
            "      --ir-subtract N   Subtract nearby IR from RGB in /1024 units (default: 0)\n"
            "      --saturation N    Chroma saturation in /1024 units (default: 1024)\n"
            "      --contrast N      Luma contrast in /1024 units (default: 1024)\n"
            "      --brightness N    Luma brightness offset, signed (default: 0)\n"
            "      --u-gain N        U/Cb chroma gain in /1024 units (default: 1024)\n"
            "      --v-gain N        V/Cr chroma gain in /1024 units (default: 1024)\n"
            "      --u-offset N      U/Cb chroma offset, signed (default: 0)\n"
            "      --v-offset N      V/Cr chroma offset, signed (default: 0)\n"
            "      --hue-deg N       Rotate U/V chroma hue, signed degrees (default: 0)\n"
            "      --auto-wb         Enable simple gray-world auto white balance\n"
            "      --target-luma N   Auto-WB target luma 1..255 (default: 115)\n"
            "      --fast            Use faster lower-quality RGB-IR interpolation\n"
            "      --mono            Force stable monochrome output\n"
            "      --no-rotate       Do not rotate output 180 degrees\n"
            "      --help            Show this help\n",
            argv0, DEFAULT_INPUT, DEFAULT_OUTPUT, DEFAULT_WIDTH, DEFAULT_HEIGHT,
            DEFAULT_FRAME_RATE);
}

static int xioctl(int fd, unsigned long request, void *arg)
{
    int rc;

    do {
        rc = ioctl(fd, request, arg);
    } while (rc == -1 && errno == EINTR);

    return rc;
}

static uint8_t clamp_u8(int value)
{
    if (value < 0)
        return 0;
    if (value > 255)
        return 255;
    return (uint8_t)value;
}

static int clamp_i(int value, int min, int max)
{
    if (value < min)
        return min;
    if (value > max)
        return max;
    return value;
}

static uint8_t raw10_to_u8(const uint8_t *raw, unsigned int stride,
                           unsigned int width, unsigned int height,
                           int x, int y)
{
    x = clamp_i(x, 0, (int)width - 1);
    y = clamp_i(y, 0, (int)height - 1);

    const uint8_t *p = raw + ((unsigned int)y * stride) + ((unsigned int)x * 2);
    uint16_t sample = (uint16_t)p[0] | ((uint16_t)p[1] << 8);

    return (uint8_t)((sample & 0x03ff) >> 2);
}

static uint8_t avg2(uint8_t a, uint8_t b)
{
    return (uint8_t)(((unsigned int)a + b) / 2);
}

static unsigned int clamp_gain(unsigned int gain)
{
    if (gain < 128)
        return 128;
    if (gain > 4096)
        return 4096;
    return gain;
}

static uint8_t apply_gain(uint8_t value, unsigned int gain)
{
    return clamp_u8(((unsigned int)value * gain) / 1024);
}

static uint8_t apply_luma_adjust(uint8_t value, unsigned int contrast,
                                 int brightness)
{
    int y = (int)value - 128;

    y = ((y * (int)contrast) / 1024) + 128 + brightness;
    return clamp_u8(y);
}

static bool is_rgbir_cfa(const char *cfa)
{
    return strcmp(cfa, "rgbir-yhrn") == 0 || strcmp(cfa, "rgbir-yhrn180") == 0;
}

static char cfa_at(const struct options *opt, int x, int y)
{
    static const char rgbir_yhrn[16] = {
        'g', 'r', 'g', 'b',
        'i', 'g', 'i', 'g',
        'g', 'b', 'g', 'r',
        'i', 'g', 'i', 'g',
    };
    static const char rgbir_yhrn180[16] = {
        'g', 'i', 'g', 'i',
        'r', 'g', 'b', 'g',
        'g', 'i', 'g', 'i',
        'b', 'g', 'r', 'g',
    };

    if (is_rgbir_cfa(opt->cfa)) {
        const char *pattern = strcmp(opt->cfa, "rgbir-yhrn180") == 0 ?
                              rgbir_yhrn180 : rgbir_yhrn;
        unsigned int px = ((unsigned int)x + opt->phase_x) & 3U;
        unsigned int py = ((unsigned int)y + opt->phase_y) & 3U;
        return pattern[(py * 4) + px];
    }

    return opt->cfa[((((unsigned int)y + opt->phase_y) & 1U) * 2) +
                    (((unsigned int)x + opt->phase_x) & 1U)];
}

static uint8_t average_neighbors(const uint8_t *raw, unsigned int stride,
                                 const struct options *opt, int x, int y,
                                 char target)
{
    unsigned int sum = 0;
    unsigned int count = 0;
    const int radius_max = is_rgbir_cfa(opt->cfa) ? 3 : 1;

    for (int radius = 1; radius <= radius_max && count == 0; radius++) {
        for (int dy = -radius; dy <= radius; dy++) {
            for (int dx = -radius; dx <= radius; dx++) {
                int nx = x + dx;
                int ny = y + dy;

                if (dx == 0 && dy == 0)
                    continue;
                if (nx < 0 || ny < 0 ||
                    nx >= (int)opt->width || ny >= (int)opt->height)
                    continue;

                if (cfa_at(opt, nx, ny) != target)
                    continue;

                sum += raw10_to_u8(raw, stride, opt->width, opt->height,
                                   nx, ny);
                count++;
            }
        }
    }

    if (count == 0)
        return raw10_to_u8(raw, stride, opt->width, opt->height, x, y);

    return (uint8_t)(sum / count);
}

static uint8_t nearest_sample(const uint8_t *raw, unsigned int stride,
                              const struct options *opt, int x, int y,
                              char target)
{
    static const int offsets[][2] = {
        { 0, 0 },
        { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 },
        { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 },
        { -2, 0 }, { 2, 0 }, { 0, -2 }, { 0, 2 },
        { -2, -1 }, { 2, -1 }, { -2, 1 }, { 2, 1 },
        { -1, -2 }, { 1, -2 }, { -1, 2 }, { 1, 2 },
    };

    for (size_t i = 0; i < sizeof(offsets) / sizeof(offsets[0]); i++) {
        int nx = x + offsets[i][0];
        int ny = y + offsets[i][1];

        if (nx < 0 || ny < 0 ||
            nx >= (int)opt->width || ny >= (int)opt->height)
            continue;
        if (cfa_at(opt, nx, ny) != target)
            continue;

        return raw10_to_u8(raw, stride, opt->width, opt->height, nx, ny);
    }

    return raw10_to_u8(raw, stride, opt->width, opt->height, x, y);
}

static void raw10_to_rgb(const uint8_t *raw, unsigned int stride,
                         const struct options *opt, int x, int y,
                         uint8_t *r, uint8_t *g, uint8_t *b)
{
    const uint8_t c = raw10_to_u8(raw, stride, opt->width, opt->height, x, y);
    const char color = cfa_at(opt, x, y);

    if (opt->fast) {
        *r = (color == 'r') ? c : nearest_sample(raw, stride, opt, x, y, 'r');
        *g = (color == 'g') ? c : nearest_sample(raw, stride, opt, x, y, 'g');
        *b = (color == 'b') ? c : nearest_sample(raw, stride, opt, x, y, 'b');
    } else {
        *r = (color == 'r') ? c :
             average_neighbors(raw, stride, opt, x, y, 'r');
        *g = (color == 'g') ? c :
             average_neighbors(raw, stride, opt, x, y, 'g');
        *b = (color == 'b') ? c :
             average_neighbors(raw, stride, opt, x, y, 'b');
    }

    if (opt->ir_subtract > 0 && is_rgbir_cfa(opt->cfa)) {
        uint8_t ir = (color == 'i') ? c :
                     (opt->fast ? nearest_sample(raw, stride, opt, x, y, 'i') :
                                  average_neighbors(raw, stride, opt, x, y, 'i'));
        int correction = ((unsigned int)ir * opt->ir_subtract) / 1024;
        *r = clamp_u8((int)*r - correction);
        *g = clamp_u8((int)*g - correction);
        *b = clamp_u8((int)*b - correction);
    }
}

static void rgb_to_yuv(uint8_t r, uint8_t g, uint8_t b,
                       uint8_t *y, uint8_t *u, uint8_t *v)
{
    int yy = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
    int uu = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
    int vv = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;

    *y = clamp_u8(yy);
    *u = clamp_u8(uu);
    *v = clamp_u8(vv);
}

static uint8_t scale_chroma(uint8_t value, unsigned int saturation,
                            unsigned int gain)
{
    int chroma = (int)value - 128;
    chroma = (chroma * (int)saturation) / 1024;
    chroma = (chroma * (int)gain) / 1024;
    return clamp_u8(128 + chroma);
}

static int round_double_to_int(double value)
{
    return (int)(value + (value >= 0.0 ? 0.5 : -0.5));
}

static void rotate_chroma(uint8_t *u, uint8_t *v, int hue_degrees)
{
    const double pi = 3.14159265358979323846;
    double radians;
    double c;
    double s;
    int chroma_u;
    int chroma_v;
    int rotated_u;
    int rotated_v;

    if (hue_degrees == 0)
        return;

    radians = ((double)hue_degrees * pi) / 180.0;
    c = cos(radians);
    s = sin(radians);
    chroma_u = (int)*u - 128;
    chroma_v = (int)*v - 128;
    rotated_u = round_double_to_int(((double)chroma_u * c) -
                                    ((double)chroma_v * s));
    rotated_v = round_double_to_int(((double)chroma_u * s) +
                                    ((double)chroma_v * c));

    *u = clamp_u8(128 + rotated_u);
    *v = clamp_u8(128 + rotated_v);
}

static unsigned long long nonzero_avg(unsigned long long sum,
                                      unsigned int count)
{
    unsigned long long avg = sum / count;

    return avg == 0 ? 1 : avg;
}

static struct frame_gains compute_frame_gains(const uint8_t *raw,
                                              unsigned int stride,
                                              const struct options *opt)
{
    unsigned long long r_sum = 0;
    unsigned long long g_sum = 0;
    unsigned long long b_sum = 0;
    unsigned long long y_sum = 0;
    unsigned int count = 0;
    /*
     * Use a step that is not a multiple of the RGB-IR 4x4 period. Sampling
     * every 16 pixels repeatedly hits the same CFA phase and breaks AWB.
     */
    const unsigned int step = 17;

    struct frame_gains gains = {
        .red = opt->red_gain,
        .green = opt->green_gain,
        .blue = opt->blue_gain,
    };

    if (!opt->auto_wb)
        return gains;

    if (opt->fast && is_rgbir_cfa(opt->cfa)) {
        for (unsigned int by = 0; by + 3 < opt->height; by += 4) {
            for (unsigned int bx = 0; bx + 3 < opt->width; bx += 4) {
                unsigned int br = 0, bg = 0, bb = 0, bi = 0;
                unsigned int rc = 0, gc = 0, bc = 0, ic = 0;

                for (unsigned int dy = 0; dy < 4; dy++) {
                    for (unsigned int dx = 0; dx < 4; dx++) {
                        unsigned int x = bx + dx;
                        unsigned int y = by + dy;
                        uint8_t sample = raw10_to_u8(raw, stride, opt->width,
                                                     opt->height, x, y);

                        switch (cfa_at(opt, (int)x, (int)y)) {
                        case 'r':
                            br += sample;
                            rc++;
                            break;
                        case 'g':
                            bg += sample;
                            gc++;
                            break;
                        case 'b':
                            bb += sample;
                            bc++;
                            break;
                        case 'i':
                            bi += sample;
                            ic++;
                            break;
                        default:
                            break;
                        }
                    }
                }

                if (!rc || !gc || !bc)
                    continue;

                uint8_t ir = ic ? (uint8_t)(bi / ic) : 0;
                int correction = ((unsigned int)ir * opt->ir_subtract) / 1024;
                uint8_t r = clamp_u8((int)(br / rc) - correction);
                uint8_t g = clamp_u8((int)(bg / gc) - correction);
                uint8_t b = clamp_u8((int)(bb / bc) - correction);
                unsigned int luma = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;

                if (luma < 12 || luma > 245)
                    continue;

                r_sum += r;
                g_sum += g;
                b_sum += b;
                y_sum += luma;
                count++;
            }
        }
    } else {
    for (unsigned int y = 0; y < opt->height; y += step) {
        for (unsigned int x = 0; x < opt->width; x += step) {
            uint8_t r, g, b;

            raw10_to_rgb(raw, stride, opt, (int)x, (int)y, &r, &g, &b);

            unsigned int luma = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;

            if (luma < 12 || luma > 245)
                continue;

            r_sum += r;
            g_sum += g;
            b_sum += b;
            y_sum += luma;
            count++;
        }
    }
    }

    if (count == 0 || r_sum == 0 || g_sum == 0 || b_sum == 0 || y_sum == 0)
        return gains;

    const unsigned long long r_avg = nonzero_avg(r_sum, count);
    const unsigned long long g_avg = nonzero_avg(g_sum, count);
    const unsigned long long b_avg = nonzero_avg(b_sum, count);
    const unsigned long long y_avg = nonzero_avg(y_sum, count);
    unsigned long long gray_avg = (r_avg + g_avg + b_avg) / 3;

    if (gray_avg == 0)
        gray_avg = 1;

    const unsigned long long wb_r = (gray_avg * 1024) / r_avg;
    const unsigned long long wb_g = (gray_avg * 1024) / g_avg;
    const unsigned long long wb_b = (gray_avg * 1024) / b_avg;
    const unsigned long long luma = ((unsigned long long)opt->target_luma * 1024) / y_avg;

    gains.red = clamp_gain((unsigned int)(((unsigned long long)opt->red_gain * wb_r * luma) / (1024 * 1024)));
    gains.green = clamp_gain((unsigned int)(((unsigned long long)opt->green_gain * wb_g * luma) / (1024 * 1024)));
    gains.blue = clamp_gain((unsigned int)(((unsigned long long)opt->blue_gain * wb_b * luma) / (1024 * 1024)));

    return gains;
}

static void source_coords(const struct options *opt, unsigned int x,
                          unsigned int y, int *sx, int *sy)
{
    *sx = (int)x;
    *sy = (int)y;

    if (opt->rotate_180) {
        *sx = (int)opt->width - 1 - (int)x;
        *sy = (int)opt->height - 1 - (int)y;
    }
}

static void write_yuyv_pair(uint8_t *out, const struct options *opt,
                            const struct frame_gains *gains,
                            unsigned int x, unsigned int y,
                            uint8_t r0, uint8_t g0, uint8_t b0,
                            uint8_t r1, uint8_t g1, uint8_t b1)
{
    uint8_t y0, u0, v0, y1, u1, v1;

    r0 = apply_gain(r0, gains->red);
    g0 = apply_gain(g0, gains->green);
    b0 = apply_gain(b0, gains->blue);
    r1 = apply_gain(r1, gains->red);
    g1 = apply_gain(g1, gains->green);
    b1 = apply_gain(b1, gains->blue);
    rgb_to_yuv(r0, g0, b0, &y0, &u0, &v0);
    rgb_to_yuv(r1, g1, b1, &y1, &u1, &v1);
    u0 = scale_chroma(u0, opt->saturation, opt->u_gain);
    v0 = scale_chroma(v0, opt->saturation, opt->v_gain);
    u1 = scale_chroma(u1, opt->saturation, opt->u_gain);
    v1 = scale_chroma(v1, opt->saturation, opt->v_gain);
    rotate_chroma(&u0, &v0, opt->hue_degrees);
    rotate_chroma(&u1, &v1, opt->hue_degrees);
    u0 = clamp_u8((int)u0 + opt->u_offset);
    v0 = clamp_u8((int)v0 + opt->v_offset);
    u1 = clamp_u8((int)u1 + opt->u_offset);
    v1 = clamp_u8((int)v1 + opt->v_offset);

    size_t off = (((size_t)y * opt->width) + x) * 2;
    out[off + 0] = y0;
    out[off + 1] = avg2(u0, u1);
    out[off + 2] = y1;
    out[off + 3] = avg2(v0, v1);
}

static unsigned int compute_mono_gain(const uint8_t *raw, unsigned int stride,
                                      const struct options *opt)
{
    unsigned long long y_sum = 0;
    unsigned int count = 0;
    const unsigned int step = 17;

    if (!opt->auto_wb)
        return 1024;

    for (unsigned int y = 0; y < opt->height; y += step) {
        for (unsigned int x = 0; x < opt->width; x += step) {
            uint8_t sample = raw10_to_u8(raw, stride, opt->width,
                                         opt->height, (int)x, (int)y);

            if (sample < 4 || sample > 250)
                continue;

            y_sum += sample;
            count++;
        }
    }

    if (count == 0 || y_sum == 0)
        return 1024;

    return clamp_gain((unsigned int)(((unsigned long long)opt->target_luma *
                                      1024 * count) / y_sum));
}

static void convert_raw10_to_mono_yuyv(const uint8_t *raw, unsigned int stride,
                                       uint8_t *out, const struct options *opt)
{
    const unsigned int luma_gain = compute_mono_gain(raw, stride, opt);

    for (unsigned int y = 0; y < opt->height; y++) {
        for (unsigned int x = 0; x < opt->width; x += 2) {
            int sx0, sy0, sx1, sy1;
            uint8_t y0, y1;
            size_t off;

            source_coords(opt, x, y, &sx0, &sy0);
            source_coords(opt, x + 1, y, &sx1, &sy1);

            y0 = apply_gain(raw10_to_u8(raw, stride, opt->width, opt->height,
                                        sx0, sy0), luma_gain);
            y1 = apply_gain(raw10_to_u8(raw, stride, opt->width, opt->height,
                                        sx1, sy1), luma_gain);
            y0 = apply_luma_adjust(y0, opt->contrast, opt->brightness);
            y1 = apply_luma_adjust(y1, opt->contrast, opt->brightness);

            off = (((size_t)y * opt->width) + x) * 2;
            out[off + 0] = y0;
            out[off + 1] = 128;
            out[off + 2] = y1;
            out[off + 3] = 128;
        }
    }
}

static void convert_rgbir_block_fast(const uint8_t *raw, unsigned int stride,
                                     uint8_t *out, const struct options *opt,
                                     const struct frame_gains *gains)
{
    for (unsigned int by = 0; by < opt->height; by += 4) {
        for (unsigned int bx = 0; bx < opt->width; bx += 4) {
            unsigned int r_sum = 0, g_sum = 0, b_sum = 0, i_sum = 0;
            unsigned int r_count = 0, g_count = 0, b_count = 0, i_count = 0;
            unsigned int block_w = opt->width - bx < 4 ? opt->width - bx : 4;
            unsigned int block_h = opt->height - by < 4 ? opt->height - by : 4;

            for (unsigned int dy = 0; dy < block_h; dy++) {
                for (unsigned int dx = 0; dx < block_w; dx++) {
                    int sx, sy;
                    source_coords(opt, bx + dx, by + dy, &sx, &sy);
                    uint8_t sample = raw10_to_u8(raw, stride, opt->width,
                                                 opt->height, sx, sy);

                    switch (cfa_at(opt, sx, sy)) {
                    case 'r':
                        r_sum += sample;
                        r_count++;
                        break;
                    case 'g':
                        g_sum += sample;
                        g_count++;
                        break;
                    case 'b':
                        b_sum += sample;
                        b_count++;
                        break;
                    case 'i':
                        i_sum += sample;
                        i_count++;
                        break;
                    default:
                        break;
                    }
                }
            }

            uint8_t r = r_count ? (uint8_t)(r_sum / r_count) : 0;
            uint8_t g = g_count ? (uint8_t)(g_sum / g_count) : 0;
            uint8_t b = b_count ? (uint8_t)(b_sum / b_count) : 0;
            uint8_t ir = i_count ? (uint8_t)(i_sum / i_count) : 0;

            if (opt->ir_subtract > 0) {
                int correction = ((unsigned int)ir * opt->ir_subtract) / 1024;
                r = clamp_u8((int)r - correction);
                g = clamp_u8((int)g - correction);
                b = clamp_u8((int)b - correction);
            }

            for (unsigned int dy = 0; dy < block_h; dy++) {
                for (unsigned int dx = 0; dx + 1 < block_w; dx += 2)
                    write_yuyv_pair(out, opt, gains, bx + dx, by + dy,
                                    r, g, b, r, g, b);
            }
        }
    }
}

static void convert_grbg10_to_yuyv(const uint8_t *raw, unsigned int stride,
                                   uint8_t *out, const struct options *opt)
{
    const struct frame_gains gains = compute_frame_gains(raw, stride, opt);

    if (opt->mono) {
        convert_raw10_to_mono_yuyv(raw, stride, out, opt);
        return;
    }

    if (opt->fast && is_rgbir_cfa(opt->cfa)) {
        convert_rgbir_block_fast(raw, stride, out, opt, &gains);
        return;
    }

    for (unsigned int y = 0; y < opt->height; y++) {
        for (unsigned int x = 0; x < opt->width; x += 2) {
            uint8_t r0, g0, b0, r1, g1, b1;
            int sx0, sy0, sx1, sy1;
            source_coords(opt, x, y, &sx0, &sy0);
            source_coords(opt, x + 1, y, &sx1, &sy1);

            raw10_to_rgb(raw, stride, opt, sx0, sy0, &r0, &g0, &b0);
            raw10_to_rgb(raw, stride, opt, sx1, sy1, &r1, &g1, &b1);
            write_yuyv_pair(out, opt, &gains, x, y, r0, g0, b0, r1, g1, b1);
        }
    }
}

static int parse_u32(const char *text, unsigned int *out)
{
    char *end = NULL;
    unsigned long value;

    errno = 0;
    value = strtoul(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || value > UINT32_MAX)
        return -1;

    *out = (unsigned int)value;
    return 0;
}

static int parse_i32(const char *text, int *out)
{
    char *end = NULL;
    long value;

    errno = 0;
    value = strtol(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' ||
        value < INT32_MIN || value > INT32_MAX)
        return -1;

    *out = (int)value;
    return 0;
}

static int parse_args(int argc, char **argv, struct options *opt)
{
    *opt = (struct options){
        .input = DEFAULT_INPUT,
        .output = DEFAULT_OUTPUT,
        .cfa = "grbg",
        .width = DEFAULT_WIDTH,
        .height = DEFAULT_HEIGHT,
        .fps = DEFAULT_FRAME_RATE,
        .frames = 0,
        .phase_x = 0,
        .phase_y = 0,
        .red_gain = 1024,
        .green_gain = 1024,
        .blue_gain = 1024,
        .ir_subtract = 0,
        .saturation = 1024,
        .contrast = 1024,
        .u_gain = 1024,
        .v_gain = 1024,
        .brightness = 0,
        .u_offset = 0,
        .v_offset = 0,
        .hue_degrees = 0,
        .target_luma = 115,
        .auto_wb = false,
        .fast = false,
        .mono = false,
        .rotate_180 = true,
    };

    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];
        const char **str_target = NULL;
        unsigned int *uint_target = NULL;
        int *int_target = NULL;

        if (strcmp(arg, "--help") == 0) {
            usage(argv[0]);
            exit(EXIT_SUCCESS);
        } else if (strcmp(arg, "--auto-wb") == 0) {
            opt->auto_wb = true;
            continue;
        } else if (strcmp(arg, "--fast") == 0) {
            opt->fast = true;
            continue;
        } else if (strcmp(arg, "--mono") == 0) {
            opt->mono = true;
            continue;
        } else if (strcmp(arg, "--no-rotate") == 0) {
            opt->rotate_180 = false;
            continue;
        } else if (strcmp(arg, "-i") == 0 || strcmp(arg, "--input") == 0) {
            str_target = &opt->input;
        } else if (strcmp(arg, "-o") == 0 || strcmp(arg, "--output") == 0) {
            str_target = &opt->output;
        } else if (strcmp(arg, "-b") == 0 || strcmp(arg, "--bayer") == 0 ||
                   strcmp(arg, "-c") == 0 || strcmp(arg, "--cfa") == 0) {
            str_target = &opt->cfa;
        } else if (strcmp(arg, "-w") == 0 || strcmp(arg, "--width") == 0) {
            uint_target = &opt->width;
        } else if (strcmp(arg, "-h") == 0 || strcmp(arg, "--height") == 0) {
            uint_target = &opt->height;
        } else if (strcmp(arg, "-r") == 0 || strcmp(arg, "--fps") == 0) {
            uint_target = &opt->fps;
        } else if (strcmp(arg, "-n") == 0 || strcmp(arg, "--frames") == 0) {
            uint_target = &opt->frames;
        } else if (strcmp(arg, "--phase-x") == 0) {
            uint_target = &opt->phase_x;
        } else if (strcmp(arg, "--phase-y") == 0) {
            uint_target = &opt->phase_y;
        } else if (strcmp(arg, "--red-gain") == 0) {
            uint_target = &opt->red_gain;
        } else if (strcmp(arg, "--green-gain") == 0) {
            uint_target = &opt->green_gain;
        } else if (strcmp(arg, "--blue-gain") == 0) {
            uint_target = &opt->blue_gain;
        } else if (strcmp(arg, "--ir-subtract") == 0) {
            uint_target = &opt->ir_subtract;
        } else if (strcmp(arg, "--saturation") == 0) {
            uint_target = &opt->saturation;
        } else if (strcmp(arg, "--contrast") == 0) {
            uint_target = &opt->contrast;
        } else if (strcmp(arg, "--brightness") == 0) {
            int_target = &opt->brightness;
        } else if (strcmp(arg, "--u-gain") == 0) {
            uint_target = &opt->u_gain;
        } else if (strcmp(arg, "--v-gain") == 0) {
            uint_target = &opt->v_gain;
        } else if (strcmp(arg, "--u-offset") == 0) {
            int_target = &opt->u_offset;
        } else if (strcmp(arg, "--v-offset") == 0) {
            int_target = &opt->v_offset;
        } else if (strcmp(arg, "--hue-deg") == 0) {
            int_target = &opt->hue_degrees;
        } else if (strcmp(arg, "--target-luma") == 0) {
            uint_target = &opt->target_luma;
        } else {
            fprintf(stderr, "Unknown option: %s\n", arg);
            return -1;
        }

        if (i + 1 >= argc) {
            fprintf(stderr, "Missing value for %s\n", arg);
            return -1;
        }

        if (str_target) {
            *str_target = argv[++i];
        } else if (uint_target && parse_u32(argv[++i], uint_target) != 0) {
            fprintf(stderr, "Invalid numeric value for %s\n", arg);
            return -1;
        } else if (int_target && parse_i32(argv[++i], int_target) != 0) {
            fprintf(stderr, "Invalid signed numeric value for %s\n", arg);
            return -1;
        }
    }

    if ((opt->width % 2) != 0) {
        fprintf(stderr, "Width must be even for YUYV output\n");
        return -1;
    }

    if (strcmp(opt->cfa, "grbg") != 0 && strcmp(opt->cfa, "rggb") != 0 &&
        strcmp(opt->cfa, "bggr") != 0 && strcmp(opt->cfa, "gbrg") != 0 &&
        strcmp(opt->cfa, "rgbir-yhrn") != 0 &&
        strcmp(opt->cfa, "rgbir-yhrn180") != 0) {
        fprintf(stderr, "Invalid CFA: %s\n", opt->cfa);
        return -1;
    }

    if (opt->phase_x > 3 || opt->phase_y > 3) {
        fprintf(stderr, "CFA phase offsets must be in range 0..3\n");
        return -1;
    }

    if (opt->target_luma == 0 || opt->target_luma > 255) {
        fprintf(stderr, "Invalid target luma: %u\n", opt->target_luma);
        return -1;
    }

    return 0;
}

static int configure_capture(int fd, const struct options *opt,
                             unsigned int *stride)
{
    struct v4l2_format fmt;

    memset(&fmt, 0, sizeof(fmt));
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.width = opt->width;
    fmt.fmt.pix.height = opt->height;
    fmt.fmt.pix.pixelformat = v4l2_fourcc('B', 'A', '1', '0');
    fmt.fmt.pix.field = V4L2_FIELD_NONE;

    if (xioctl(fd, VIDIOC_S_FMT, &fmt) == -1) {
        perror("VIDIOC_S_FMT input");
        return -1;
    }

    if (fmt.fmt.pix.width != opt->width || fmt.fmt.pix.height != opt->height ||
        fmt.fmt.pix.pixelformat != v4l2_fourcc('B', 'A', '1', '0')) {
        fprintf(stderr, "Input did not accept requested BA10 %ux%u\n",
                opt->width, opt->height);
        return -1;
    }

    *stride = fmt.fmt.pix.bytesperline;
    fprintf(stderr, "Input: %s BA10 %ux%u stride=%u sizeimage=%u\n",
            opt->input, fmt.fmt.pix.width, fmt.fmt.pix.height,
            fmt.fmt.pix.bytesperline, fmt.fmt.pix.sizeimage);
    return 0;
}

static int configure_output(int fd, const struct options *opt)
{
    struct v4l2_format fmt;
    struct v4l2_streamparm parm;

    memset(&fmt, 0, sizeof(fmt));
    fmt.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
    fmt.fmt.pix.width = opt->width;
    fmt.fmt.pix.height = opt->height;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
    fmt.fmt.pix.field = V4L2_FIELD_NONE;
    fmt.fmt.pix.bytesperline = opt->width * 2;
    fmt.fmt.pix.sizeimage = opt->width * opt->height * 2;

    if (xioctl(fd, VIDIOC_S_FMT, &fmt) == -1) {
        perror("VIDIOC_S_FMT output");
        return -1;
    }

    memset(&parm, 0, sizeof(parm));
    parm.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
    parm.parm.output.timeperframe.numerator = 1;
    parm.parm.output.timeperframe.denominator = opt->fps;
    (void)xioctl(fd, VIDIOC_S_PARM, &parm);

    if (fmt.fmt.pix.pixelformat != V4L2_PIX_FMT_YUYV) {
        fprintf(stderr, "Output did not accept YUYV\n");
        return -1;
    }

    fprintf(stderr, "Output: %s YUYV %ux%u stride=%u sizeimage=%u\n",
            opt->output, fmt.fmt.pix.width, fmt.fmt.pix.height,
            fmt.fmt.pix.bytesperline, fmt.fmt.pix.sizeimage);
    return 0;
}

static int setup_mmap(int fd, struct buffer **buffers_out,
                      unsigned int *buffer_count_out)
{
    struct v4l2_requestbuffers req;
    struct buffer *buffers;

    memset(&req, 0, sizeof(req));
    req.count = 4;
    req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    req.memory = V4L2_MEMORY_MMAP;

    if (xioctl(fd, VIDIOC_REQBUFS, &req) == -1) {
        perror("VIDIOC_REQBUFS");
        return -1;
    }

    if (req.count < 2) {
        fprintf(stderr, "Insufficient capture buffers\n");
        return -1;
    }

    buffers = calloc(req.count, sizeof(*buffers));
    if (!buffers) {
        perror("calloc");
        return -1;
    }

    for (unsigned int i = 0; i < req.count; i++) {
        struct v4l2_buffer buf;

        memset(&buf, 0, sizeof(buf));
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index = i;

        if (xioctl(fd, VIDIOC_QUERYBUF, &buf) == -1) {
            perror("VIDIOC_QUERYBUF");
            free(buffers);
            return -1;
        }

        buffers[i].length = buf.length;
        buffers[i].start = mmap(NULL, buf.length, PROT_READ | PROT_WRITE,
                                MAP_SHARED, fd, buf.m.offset);
        if (buffers[i].start == MAP_FAILED) {
            perror("mmap");
            free(buffers);
            return -1;
        }
    }

    for (unsigned int i = 0; i < req.count; i++) {
        struct v4l2_buffer buf;

        memset(&buf, 0, sizeof(buf));
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index = i;

        if (xioctl(fd, VIDIOC_QBUF, &buf) == -1) {
            perror("VIDIOC_QBUF");
            free(buffers);
            return -1;
        }
    }

    *buffers_out = buffers;
    *buffer_count_out = req.count;
    return 0;
}

static int wait_for_frame(int fd)
{
    fd_set fds;
    struct timeval tv;
    int rc;

    FD_ZERO(&fds);
    FD_SET(fd, &fds);
    tv.tv_sec = 2;
    tv.tv_usec = 0;

    rc = select(fd + 1, &fds, NULL, NULL, &tv);
    if (rc == -1) {
        if (errno == EINTR)
            return 0;
        perror("select");
        return -1;
    }

    if (rc == 0) {
        fprintf(stderr, "Timeout waiting for frame\n");
        return -1;
    }

    return 0;
}

static int write_all(int fd, const uint8_t *buf, size_t len)
{
    while (len > 0) {
        ssize_t written = write(fd, buf, len);
        if (written == -1) {
            if (errno == EINTR)
                continue;
            perror("write output");
            return -1;
        }
        buf += written;
        len -= (size_t)written;
    }

    return 0;
}

int main(int argc, char **argv)
{
    struct options opt;
    int in_fd = -1;
    int out_fd = -1;
    struct buffer *buffers = NULL;
    unsigned int buffer_count = 0;
    unsigned int stride = 0;
    uint8_t *yuyv = NULL;
    enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    unsigned int frame = 0;
    int rc = EXIT_FAILURE;

    if (parse_args(argc, argv, &opt) != 0) {
        usage(argv[0]);
        return EXIT_FAILURE;
    }

    in_fd = open(opt.input, O_RDWR | O_NONBLOCK);
    if (in_fd == -1) {
        perror("open input");
        goto out;
    }

    out_fd = open(opt.output, O_RDWR);
    if (out_fd == -1) {
        perror("open output");
        goto out;
    }

    if (configure_capture(in_fd, &opt, &stride) != 0)
        goto out;
    if (configure_output(out_fd, &opt) != 0)
        goto out;
    if (setup_mmap(in_fd, &buffers, &buffer_count) != 0)
        goto out;

    yuyv = malloc((size_t)opt.width * opt.height * 2);
    if (!yuyv) {
        perror("malloc");
        goto out;
    }

    if (xioctl(in_fd, VIDIOC_STREAMON, &type) == -1) {
        perror("VIDIOC_STREAMON");
        goto out;
    }

    fprintf(stderr,
            "Streaming %s -> %s; cfa=%s phase=%u/%u rotate_180=%s "
            "gains=%u/%u/%u ir_subtract=%u saturation=%u contrast=%u "
            "brightness=%d u_gain=%u v_gain=%u u_offset=%d v_offset=%d "
            "hue_degrees=%d auto_wb=%s target_luma=%u fast=%s mono=%s\n",
            opt.input, opt.output, opt.cfa, opt.phase_x, opt.phase_y,
            opt.rotate_180 ? "yes" : "no", opt.red_gain, opt.green_gain,
            opt.blue_gain, opt.ir_subtract, opt.saturation, opt.contrast,
            opt.brightness, opt.u_gain, opt.v_gain, opt.u_offset,
            opt.v_offset, opt.hue_degrees, opt.auto_wb ? "yes" : "no",
            opt.target_luma, opt.fast ? "yes" : "no",
            opt.mono ? "yes" : "no");

    while (opt.frames == 0 || frame < opt.frames) {
        struct v4l2_buffer buf;

        if (wait_for_frame(in_fd) != 0)
            goto out_streaming;

        memset(&buf, 0, sizeof(buf));
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = V4L2_MEMORY_MMAP;

        if (xioctl(in_fd, VIDIOC_DQBUF, &buf) == -1) {
            if (errno == EAGAIN)
                continue;
            perror("VIDIOC_DQBUF");
            goto out_streaming;
        }

        if (buf.index >= buffer_count) {
            fprintf(stderr, "Invalid buffer index %u\n", buf.index);
            goto out_streaming;
        }

        convert_grbg10_to_yuyv(buffers[buf.index].start, stride, yuyv, &opt);

        if (write_all(out_fd, yuyv, (size_t)opt.width * opt.height * 2) != 0)
            goto out_streaming;

        if (xioctl(in_fd, VIDIOC_QBUF, &buf) == -1) {
            perror("VIDIOC_QBUF requeue");
            goto out_streaming;
        }

        frame++;
        if ((frame % opt.fps) == 0)
            fprintf(stderr, "frames=%u\n", frame);
    }

    rc = EXIT_SUCCESS;

out_streaming:
    (void)xioctl(in_fd, VIDIOC_STREAMOFF, &type);
out:
    if (buffers) {
        for (unsigned int i = 0; i < buffer_count; i++) {
            if (buffers[i].start && buffers[i].start != MAP_FAILED)
                munmap(buffers[i].start, buffers[i].length);
        }
        free(buffers);
    }
    free(yuyv);
    if (out_fd != -1)
        close(out_fd);
    if (in_fd != -1)
        close(in_fd);

    return rc;
}
