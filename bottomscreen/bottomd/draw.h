/* draw.h — software 2D primitives over an XRGB8888 canvas. */
#ifndef BOTTOMD_DRAW_H
#define BOTTOMD_DRAW_H

#include <stdint.h>
#include "backend.h"

typedef struct {
    uint32_t *px; /* BOTTOMD_W * BOTTOMD_H */
} Canvas;

void draw_clear(Canvas *c, uint32_t color);
void draw_pixel(Canvas *c, int x, int y, uint32_t color);
void draw_rect(Canvas *c, int x, int y, int w, int h, uint32_t color);
void draw_rect_outline(Canvas *c, int x, int y, int w, int h,
                       uint32_t color);
void draw_line(Canvas *c, int x0, int y0, int x1, int y1, uint32_t color);
void draw_disc(Canvas *c, int cx, int cy, int r, uint32_t color);
/* Filled triangle (player arrow etc.). */
void draw_tri(Canvas *c, int x0, int y0, int x1, int y1, int x2, int y2,
              uint32_t color);
/* Darken the whole canvas toward black. num/den = kept brightness
 * (e.g. 2/5 keeps 40%). Used by the STALE mode overlay so the last
 * known-good frame stays readable but is obviously not live. */
void draw_dim(Canvas *c, int num, int den);

/* Scale a rectangle's RGB by per-channel factors (0..1). Used for the
 * day/night map shading: night is not just darker, it is bluer, so the
 * channels must scale differently. Only touches the given rect, so
 * markers and chrome drawn afterwards stay at full brightness. */
void draw_tint_rect(Canvas *c, int x, int y, int w, int h,
                    float rf, float gf, float bf);
/* Seven-segment style number rendering: digits, '-', '.', ':'.
 * Returns advance in px. scale 1 => 4x7 px per digit cell.
 * Kept for the big readouts (coords strip, dev HUD) where the chunky
 * seven-seg look reads better at a glance than the 5x7 font. */
int draw_number(Canvas *c, int x, int y, double value, int decimals,
                int scale, uint32_t color);

/* 5x7 bitmap font, ASCII 32..90 (space, punctuation, digits, A-Z).
 * Lowercase is folded to uppercase; anything unmapped draws as a space.
 * scale 1 => 5x7 px per glyph, 6*scale px advance.
 * Returns the advance in px (so callers can chain). */
int draw_text(Canvas *c, int x, int y, const char *s, int scale,
              uint32_t color);
/* Advance draw_text WOULD use, without drawing — for centering. */
int draw_text_width(const char *s, int scale);

#endif
