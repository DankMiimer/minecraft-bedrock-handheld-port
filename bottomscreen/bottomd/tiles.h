/*
 * tiles.h — bedrockmap tile-cache reader for the minimap.
 * Tiles: $BOTTOMD_TILES/<dim>/<surface|cave>/r.<tx>.<tz>.raw
 * (256*256*3 RGB, 1 px per block; tile (tx,tz) covers world blocks
 * [tx*256, tx*256+255] x [tz*256, tz*256+255]).
 * Small LRU keeps the working set; mtime changes trigger reload, so
 * bedrockmap passes show up automatically.
 */
#ifndef BOTTOMD_TILES_H
#define BOTTOMD_TILES_H

#include <stdint.h>

void tiles_init(void); /* reads $BOTTOMD_TILES; absent => disabled */
int  tiles_enabled(void);
/* Sample the world-block color at (wx, wz). Returns 1 and fills rgb,
 * or 0 if no tile / unrendered (caller draws its fallback). */
int  tiles_sample(int32_t wx, int32_t wz, int dim, uint32_t *xrgb);
/* Emission at (wx, wz), 0..255, from bedrockmap's parallel .lum tile.
 * 0 when there is no light data (older tiles, or a dark block), which
 * makes "no data" behave exactly like "not a light source". */
uint8_t tiles_sample_light(int32_t wx, int32_t wz, int dim);
/* Call once per rendered frame: cheap mtime re-check every ~2s. */
void tiles_tick(void);
/* Drop all positive and negative cache entries after the map source changes. */
void tiles_invalidate_all(void);

#endif
