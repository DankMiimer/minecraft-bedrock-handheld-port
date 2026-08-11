#ifndef BOTTOMD_TEXTURE_H
#define BOTTOMD_TEXTURE_H

#include "draw.h"

#include <stddef.h>

/* Reads path/index files produced from the user's installed APK. */
void texture_init(void);
void texture_close(void);
int texture_available(void);

/* Draw an atlas-relative PNG with nearest-neighbour scaling and alpha. */
int texture_draw(Canvas *canvas, const char *relative_path,
                 int x, int y, int width, int height);

/* Resolve Bedrock's item identifier through item-textures.tsv. */
int texture_item_path(const char *identifier, unsigned variant,
                      char *out, size_t out_size);

#endif
