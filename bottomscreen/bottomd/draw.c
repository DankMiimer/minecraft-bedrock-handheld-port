#include "draw.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void draw_clear(Canvas *c, uint32_t color)
{
    for (int i = 0; i < BOTTOMD_W * BOTTOMD_H; ++i)
        c->px[i] = color;
}

/* 5x7 font, ASCII 32..90. One byte per column, bit0 = top row. */
static const uint8_t FONT5X7[59][5] = {
    {0x00,0x00,0x00,0x00,0x00}, /* 32 space */
    {0x00,0x00,0x5F,0x00,0x00}, /* ! */
    {0x00,0x07,0x00,0x07,0x00}, /* " */
    {0x14,0x7F,0x14,0x7F,0x14}, /* # */
    {0x24,0x2A,0x7F,0x2A,0x12}, /* $ */
    {0x23,0x13,0x08,0x64,0x62}, /* % */
    {0x36,0x49,0x55,0x22,0x50}, /* & */
    {0x00,0x05,0x03,0x00,0x00}, /* ' */
    {0x00,0x1C,0x22,0x41,0x00}, /* ( */
    {0x00,0x41,0x22,0x1C,0x00}, /* ) */
    {0x14,0x08,0x3E,0x08,0x14}, /* * */
    {0x08,0x08,0x3E,0x08,0x08}, /* + */
    {0x00,0x50,0x30,0x00,0x00}, /* , */
    {0x08,0x08,0x08,0x08,0x08}, /* - */
    {0x00,0x60,0x60,0x00,0x00}, /* . */
    {0x20,0x10,0x08,0x04,0x02}, /* / */
    {0x3E,0x51,0x49,0x45,0x3E}, /* 0 */
    {0x00,0x42,0x7F,0x40,0x00}, /* 1 */
    {0x42,0x61,0x51,0x49,0x46}, /* 2 */
    {0x21,0x41,0x45,0x4B,0x31}, /* 3 */
    {0x18,0x14,0x12,0x7F,0x10}, /* 4 */
    {0x27,0x45,0x45,0x45,0x39}, /* 5 */
    {0x3C,0x4A,0x49,0x49,0x30}, /* 6 */
    {0x01,0x71,0x09,0x05,0x03}, /* 7 */
    {0x36,0x49,0x49,0x49,0x36}, /* 8 */
    {0x06,0x49,0x49,0x29,0x1E}, /* 9 */
    {0x00,0x36,0x36,0x00,0x00}, /* : */
    {0x00,0x56,0x36,0x00,0x00}, /* ; */
    {0x08,0x14,0x22,0x41,0x00}, /* < */
    {0x14,0x14,0x14,0x14,0x14}, /* = */
    {0x00,0x41,0x22,0x14,0x08}, /* > */
    {0x02,0x01,0x51,0x09,0x06}, /* ? */
    {0x32,0x49,0x79,0x41,0x3E}, /* @ */
    {0x7E,0x11,0x11,0x11,0x7E}, /* A */
    {0x7F,0x49,0x49,0x49,0x36}, /* B */
    {0x3E,0x41,0x41,0x41,0x22}, /* C */
    {0x7F,0x41,0x41,0x22,0x1C}, /* D */
    {0x7F,0x49,0x49,0x49,0x41}, /* E */
    {0x7F,0x09,0x09,0x09,0x01}, /* F */
    {0x3E,0x41,0x49,0x49,0x7A}, /* G */
    {0x7F,0x08,0x08,0x08,0x7F}, /* H */
    {0x00,0x41,0x7F,0x41,0x00}, /* I */
    {0x20,0x40,0x41,0x3F,0x01}, /* J */
    {0x7F,0x08,0x14,0x22,0x41}, /* K */
    {0x7F,0x40,0x40,0x40,0x40}, /* L */
    {0x7F,0x02,0x0C,0x02,0x7F}, /* M */
    {0x7F,0x04,0x08,0x10,0x7F}, /* N */
    {0x3E,0x41,0x41,0x41,0x3E}, /* O */
    {0x7F,0x09,0x09,0x09,0x06}, /* P */
    {0x3E,0x41,0x51,0x21,0x5E}, /* Q */
    {0x7F,0x09,0x19,0x29,0x46}, /* R */
    {0x46,0x49,0x49,0x49,0x31}, /* S */
    {0x01,0x01,0x7F,0x01,0x01}, /* T */
    {0x3F,0x40,0x40,0x40,0x3F}, /* U */
    {0x1F,0x20,0x40,0x20,0x1F}, /* V */
    {0x3F,0x40,0x38,0x40,0x3F}, /* W */
    {0x63,0x14,0x08,0x14,0x63}, /* X */
    {0x07,0x08,0x70,0x08,0x07}, /* Y */
    {0x61,0x51,0x49,0x45,0x43}, /* Z */
};

int draw_text_width(const char *s, int scale)
{
    if (scale < 1) scale = 1;
    int n = 0;
    for (const char *p = s; *p; ++p) n++;
    return n * 6 * scale;
}

int draw_text(Canvas *c, int x, int y, const char *s, int scale,
              uint32_t color)
{
    if (scale < 1) scale = 1;
    int x0 = x;
    for (const char *p = s; *p; ++p) {
        unsigned ch = (unsigned char)*p;
        if (ch >= 'a' && ch <= 'z') ch -= 32;
        const uint8_t *g = (ch >= 32 && ch <= 90) ? FONT5X7[ch - 32]
                                                  : FONT5X7[0];
        for (int col = 0; col < 5; ++col)
            for (int row = 0; row < 7; ++row)
                if (g[col] & (1u << row))
                    draw_rect(c, x + col * scale, y + row * scale,
                              scale, scale, color);
        x += 6 * scale;
    }
    return x - x0;
}

void draw_dim(Canvas *c, int num, int den)
{
    if (den <= 0 || num >= den) return;
    if (num < 0) num = 0;
    for (int i = 0; i < BOTTOMD_W * BOTTOMD_H; ++i) {
        uint32_t p = c->px[i];
        uint32_t r = ((p >> 16) & 0xff) * (uint32_t)num / (uint32_t)den;
        uint32_t g = ((p >> 8) & 0xff) * (uint32_t)num / (uint32_t)den;
        uint32_t b = (p & 0xff) * (uint32_t)num / (uint32_t)den;
        c->px[i] = 0xff000000u | (r << 16) | (g << 8) | b;
    }
}

void draw_tint_rect(Canvas *c, int x, int y, int w, int h,
                    float rf, float gf, float bf)
{
    if (rf >= 0.999f && gf >= 0.999f && bf >= 0.999f) return;
    int x0 = x < 0 ? 0 : x, y0 = y < 0 ? 0 : y;
    int x1 = x + w > BOTTOMD_W ? BOTTOMD_W : x + w;
    int y1 = y + h > BOTTOMD_H ? BOTTOMD_H : y + h;
    /* fixed point: avoids a float multiply per channel per pixel on a
     * 300k-pixel panel refreshed 20x a second */
    uint32_t ri = (uint32_t)(rf < 0 ? 0 : rf * 256.0f);
    uint32_t gi = (uint32_t)(gf < 0 ? 0 : gf * 256.0f);
    uint32_t bi = (uint32_t)(bf < 0 ? 0 : bf * 256.0f);
    for (int yy = y0; yy < y1; ++yy) {
        uint32_t *row = c->px + (size_t)yy * BOTTOMD_W;
        for (int xx = x0; xx < x1; ++xx) {
            uint32_t p = row[xx];
            uint32_t r = (((p >> 16) & 0xff) * ri) >> 8;
            uint32_t g = (((p >> 8) & 0xff) * gi) >> 8;
            uint32_t b = ((p & 0xff) * bi) >> 8;
            if (r > 255) r = 255;
            if (g > 255) g = 255;
            if (b > 255) b = 255;
            row[xx] = 0xff000000u | (r << 16) | (g << 8) | b;
        }
    }
}

void draw_pixel(Canvas *c, int x, int y, uint32_t color)
{
    if ((unsigned)x < BOTTOMD_W && (unsigned)y < BOTTOMD_H)
        c->px[y * BOTTOMD_W + x] = color;
}

void draw_rect(Canvas *c, int x, int y, int w, int h, uint32_t color)
{
    int x0 = x < 0 ? 0 : x, y0 = y < 0 ? 0 : y;
    int x1 = x + w > BOTTOMD_W ? BOTTOMD_W : x + w;
    int y1 = y + h > BOTTOMD_H ? BOTTOMD_H : y + h;
    for (int yy = y0; yy < y1; ++yy)
        for (int xx = x0; xx < x1; ++xx)
            c->px[yy * BOTTOMD_W + xx] = color;
}

void draw_rect_outline(Canvas *c, int x, int y, int w, int h,
                       uint32_t color)
{
    draw_rect(c, x, y, w, 1, color);
    draw_rect(c, x, y + h - 1, w, 1, color);
    draw_rect(c, x, y, 1, h, color);
    draw_rect(c, x + w - 1, y, 1, h, color);
}

void draw_line(Canvas *c, int x0, int y0, int x1, int y1, uint32_t color)
{
    int dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1;
    int dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1;
    int err = dx + dy;
    for (;;) {
        draw_pixel(c, x0, y0, color);
        if (x0 == x1 && y0 == y1) break;
        int e2 = 2 * err;
        if (e2 >= dy) { err += dy; x0 += sx; }
        if (e2 <= dx) { err += dx; y0 += sy; }
    }
}

void draw_disc(Canvas *c, int cx, int cy, int r, uint32_t color)
{
    for (int y = -r; y <= r; ++y)
        for (int x = -r; x <= r; ++x)
            if (x * x + y * y <= r * r)
                draw_pixel(c, cx + x, cy + y, color);
}

static int edge(int ax, int ay, int bx, int by, int px, int py)
{
    return (bx - ax) * (py - ay) - (by - ay) * (px - ax);
}

void draw_tri(Canvas *c, int x0, int y0, int x1, int y1, int x2, int y2,
              uint32_t color)
{
    int minx = x0 < x1 ? (x0 < x2 ? x0 : x2) : (x1 < x2 ? x1 : x2);
    int maxx = x0 > x1 ? (x0 > x2 ? x0 : x2) : (x1 > x2 ? x1 : x2);
    int miny = y0 < y1 ? (y0 < y2 ? y0 : y2) : (y1 < y2 ? y1 : y2);
    int maxy = y0 > y1 ? (y0 > y2 ? y0 : y2) : (y1 > y2 ? y1 : y2);
    /* winding-agnostic: accept all-nonneg or all-nonpos */
    for (int y = miny; y <= maxy; ++y)
        for (int x = minx; x <= maxx; ++x) {
            int a = edge(x0, y0, x1, y1, x, y);
            int b = edge(x1, y1, x2, y2, x, y);
            int d = edge(x2, y2, x0, y0, x, y);
            if ((a >= 0 && b >= 0 && d >= 0) ||
                (a <= 0 && b <= 0 && d <= 0))
                draw_pixel(c, x, y, color);
        }
}

/* seven-segment digits --------------------------------------------- */
/* segment bits: 0=top 1=tr 2=br 3=bottom 4=bl 5=tl 6=mid */
static const uint8_t SEG[10] = {
    0x3f, 0x06, 0x5b, 0x4f, 0x66, 0x6d, 0x7d, 0x07, 0x7f, 0x6f
};

static void seg_digit(Canvas *c, int x, int y, int s, uint8_t bits,
                      uint32_t col)
{
    int w = 3 * s, h = 6 * s, t = s; /* width, height, thickness */
    if (bits & 0x01) draw_rect(c, x, y, w, t, col);
    if (bits & 0x02) draw_rect(c, x + w - t, y, t, h / 2, col);
    if (bits & 0x04) draw_rect(c, x + w - t, y + h / 2, t, h / 2, col);
    if (bits & 0x08) draw_rect(c, x, y + h - t, w, t, col);
    if (bits & 0x10) draw_rect(c, x, y + h / 2, t, h / 2, col);
    if (bits & 0x20) draw_rect(c, x, y, t, h / 2, col);
    if (bits & 0x40) draw_rect(c, x, y + h / 2 - t / 2, w, t, col);
}

int draw_number(Canvas *c, int x, int y, double value, int decimals,
                int scale, uint32_t color)
{
    char buf[32];
    snprintf(buf, sizeof buf, "%.*f", decimals, value);
    int s = scale < 1 ? 1 : scale;
    int adv = 4 * s, start = x;
    for (const char *p = buf; *p; ++p) {
        if (*p >= '0' && *p <= '9') {
            seg_digit(c, x, y, s, SEG[*p - '0'], color);
            x += adv;
        } else if (*p == '-') {
            draw_rect(c, x, y + 3 * s - s / 2, 3 * s, s, color);
            x += adv;
        } else if (*p == '.') {
            draw_rect(c, x, y + 5 * s, s, s, color);
            x += 2 * s;
        } else if (*p == ':') {
            draw_rect(c, x, y + s, s, s, color);
            draw_rect(c, x, y + 4 * s, s, s, color);
            x += 2 * s;
        }
    }
    return x - start;
}
