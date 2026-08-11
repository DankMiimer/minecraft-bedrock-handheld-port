#define _GNU_SOURCE
#include "texture.h"

#include <png.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_ROOTS 64
#define MAX_TEXTURES 128

typedef struct LoadedTexture {
    char key[160];
    unsigned width;
    unsigned height;
    unsigned char *rgba;
    unsigned long stamp;
} LoadedTexture;

static char g_roots[MAX_ROOTS][512];
static int g_root_count;
static char g_item_index[512];
static LoadedTexture g_cache[MAX_TEXTURES];
static unsigned long g_stamp;

static int safe_relative(const char *path)
{
    return path && path[0] && path[0] != '/' && path[0] != '\\' &&
           !strstr(path, "../") && !strstr(path, "..\\");
}

void texture_init(void)
{
    const char *paths = getenv("BOTTOMD_RESOURCE_INDEX");
    const char *items = getenv("BOTTOMD_ITEM_INDEX");
    if (items) snprintf(g_item_index, sizeof g_item_index, "%s", items);
    if (!paths || !paths[0]) return;
    FILE *file = fopen(paths, "r");
    if (!file) return;
    while (g_root_count < MAX_ROOTS &&
           fgets(g_roots[g_root_count], sizeof g_roots[0], file)) {
        char *line = g_roots[g_root_count];
        line[strcspn(line, "\r\n")] = 0;
        if (line[0]) g_root_count++;
    }
    fclose(file);
    fprintf(stderr, "bottomd: using %d user-installed Bedrock texture roots\n",
            g_root_count);
}

void texture_close(void)
{
    for (int i = 0; i < MAX_TEXTURES; ++i) {
        free(g_cache[i].rgba);
        g_cache[i].rgba = NULL;
    }
}

int texture_available(void) { return g_root_count > 0; }

static int make_path(char *out, size_t size, const char *root,
                     const char *relative)
{
    int has_png = strlen(relative) >= 4 &&
                  !strcmp(relative + strlen(relative) - 4, ".png");
    int written = snprintf(out, size, "%s/%s%s", root, relative,
                           has_png ? "" : ".png");
    return written > 0 && (size_t)written < size;
}

static int load_png(const char *relative, LoadedTexture *slot)
{
    if (!safe_relative(relative)) return 0;
    char full[1024];
    for (int root = 0; root < g_root_count; ++root) {
        if (!make_path(full, sizeof full, g_roots[root], relative)) continue;
        png_image image;
        memset(&image, 0, sizeof image);
        image.version = PNG_IMAGE_VERSION;
        if (!png_image_begin_read_from_file(&image, full)) continue;
        image.format = PNG_FORMAT_RGBA;
        if (!image.width || !image.height || image.width > 4096 || image.height > 4096) {
            png_image_free(&image);
            continue;
        }
        unsigned char *rgba = malloc(PNG_IMAGE_SIZE(image));
        if (!rgba) {
            png_image_free(&image);
            return 0;
        }
        if (!png_image_finish_read(&image, NULL, rgba, 0, NULL)) {
            free(rgba);
            png_image_free(&image);
            continue;
        }
        free(slot->rgba);
        memset(slot, 0, sizeof *slot);
        snprintf(slot->key, sizeof slot->key, "%s", relative);
        slot->width = image.width;
        slot->height = image.height;
        slot->rgba = rgba;
        slot->stamp = ++g_stamp;
        png_image_free(&image);
        return 1;
    }
    return 0;
}

static LoadedTexture *find_texture(const char *relative)
{
    LoadedTexture *oldest = &g_cache[0];
    for (int i = 0; i < MAX_TEXTURES; ++i) {
        if (g_cache[i].rgba && !strcmp(g_cache[i].key, relative)) {
            g_cache[i].stamp = ++g_stamp;
            return &g_cache[i];
        }
        if (!g_cache[i].rgba) oldest = &g_cache[i];
        else if (oldest->rgba && g_cache[i].stamp < oldest->stamp) oldest = &g_cache[i];
    }
    return load_png(relative, oldest) ? oldest : NULL;
}

static uint32_t blend(uint32_t destination, const unsigned char *source)
{
    unsigned a = source[3];
    if (a == 255) return 0xff000000u | ((uint32_t)source[0] << 16) |
                         ((uint32_t)source[1] << 8) | source[2];
    if (!a) return destination;
    unsigned inv = 255 - a;
    unsigned dr = (destination >> 16) & 255u;
    unsigned dg = (destination >> 8) & 255u;
    unsigned db = destination & 255u;
    unsigned r = (source[0] * a + dr * inv + 127) / 255;
    unsigned g = (source[1] * a + dg * inv + 127) / 255;
    unsigned b = (source[2] * a + db * inv + 127) / 255;
    return 0xff000000u | (r << 16) | (g << 8) | b;
}

int texture_draw(Canvas *canvas, const char *relative_path,
                 int x, int y, int width, int height)
{
    LoadedTexture *texture = find_texture(relative_path);
    if (!texture || !canvas || width <= 0 || height <= 0) return 0;
    for (int dy = 0; dy < height; ++dy) {
        int py = y + dy;
        if (py < 0 || py >= BOTTOMD_H) continue;
        unsigned sy = (unsigned)((uint64_t)dy * texture->height / (unsigned)height);
        for (int dx = 0; dx < width; ++dx) {
            int px = x + dx;
            if (px < 0 || px >= BOTTOMD_W) continue;
            unsigned sx = (unsigned)((uint64_t)dx * texture->width / (unsigned)width);
            const unsigned char *source = texture->rgba +
                ((size_t)sy * texture->width + sx) * 4u;
            uint32_t *destination = &canvas->px[(size_t)py * BOTTOMD_W + px];
            *destination = blend(*destination, source);
        }
    }
    return 1;
}

int texture_item_path(const char *identifier, unsigned variant,
                      char *out, size_t out_size)
{
    if (!identifier || !identifier[0] || !g_item_index[0] || !out || !out_size)
        return 0;
    /* Bedrock's native item name is canonical (minecraft:apple), while the
     * resource atlases use the path-local key (apple). */
    const char *lookup = strchr(identifier, ':');
    lookup = lookup ? lookup + 1 : identifier;
    FILE *file = fopen(g_item_index, "r");
    if (!file) return 0;
    char line[512];
    int found = 0;
    while (fgets(line, sizeof line, file)) {
        if (line[0] == '#') continue;
        char *id = strtok(line, "\t");
        char *var = strtok(NULL, "\t");
        char *path = strtok(NULL, "\r\n");
        if (!id || !var || !path || strcmp(id, lookup)) continue;
        if ((unsigned)strtoul(var, NULL, 10) != variant) continue;
        snprintf(out, out_size, "%s", path);
        found = 1;
        break;
    }
    fclose(file);
    return found;
}
