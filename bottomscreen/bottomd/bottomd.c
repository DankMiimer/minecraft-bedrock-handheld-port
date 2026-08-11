/*
 * bottomd — bottom-screen daemon.
 *
 * The page layer is the normal UI: persistent status plus HUD, Chat, Items,
 * Input, Settings and a bottom tab bar. The mode layer only handles health
 * overrides: stale telemetry, no signal, and an explicitly opted-in blank.
 * Chat and Items are independent views backed by a versioned native bridge.
 * They never copy game framebuffer pixels, so gameplay remains visible on the
 * other panel while inventory, crafting, or chat is used here.
 *
 * Every mode transition is logged with its reason, so a black bottom
 * screen is always attributable to a named state in bottomd.log.
 *
 * Usage:
 *   bottomd [--backend ppm|fbdev|wayland] [--outdir DIR] [--frames N]
 *           [--fps N] [--zoom PX_PER_BLOCK]
 * Env:
 *   MCPE_TELEMETRY_SHM  same override as the game side
 *   BOTTOMD_FB          fbdev node (default /dev/fb1)
 *   BOTTOMD_WAYPOINTS   text file, lines: "<x> <z>" (world coords)
 *   BOTTOMD_RESOURCE_INDEX path list generated from the installed Bedrock APK
 *   BOTTOMD_ITEM_INDEX item atlas index generated from that same installation
 *   BOTTOMD_BLANK_ON_CONTAINER=1
 *                       opt in to blanking the panel while a container is
 *                       open (default: keep the map up)
 *   BOTTOMD_STALE_MS    ms before telemetry counts as stale (default 5000)
 *   BOTTOMD_DEAD_MS     ms before the feed counts as dead and its flags
 *                       stop being trusted at all (default 30000)
 */
#define _GNU_SOURCE
#define MCPE_TELEMETRY_IMPLEMENT_READER
#include "../telemetry/mcpe_telemetry_abi.h"
#include "backend.h"
#include "companion.h"
#include "draw.h"
#include "pages.h"
#include "paneltouch.h"
#include "gamepad.h"
#include "keyfwd.h"
#include "screenflip.h"
#include "tiles.h"
#include "texture.h"
#include "touchfwd.h"
#include "worldinfo.h"

#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define COL_BG        0xff10141c
#define COL_GRID      0xff232c3a
#define COL_GRID_MAJ  0xff32405a
#define COL_ARROW     0xff5ee08a
#define COL_ARROW_RIM 0xff103820
#define COL_TEXT      0xffd8e0ea
#define COL_ACCENT    0xff5ea8e0
#define COL_DEATH     0xffe05e5e
#define COL_WAYPOINT  0xffe0c05e
#define COL_WARN      0xffe08a5e
#define COL_NOSIG     0xff404a58

/* Mode is the HEALTH/override axis. What the user chose to look at is
 * the Page axis (pages.h). MODE_PAGE means "no override applies — draw
 * whatever tab is active". */
typedef enum {
    MODE_NOSIGNAL = 0,
    MODE_STALE,
#ifndef BOTTOMD_STABLE_RELEASE
    MODE_MIRROR,
    MODE_BLANK,
#endif
    MODE_PAGE,
    MODE_COUNT
} Mode;

static const char *mode_name(Mode m)
{
    switch (m) {
    case MODE_NOSIGNAL: return "NOSIGNAL";
    case MODE_STALE:    return "STALE";
#ifndef BOTTOMD_STABLE_RELEASE
    case MODE_MIRROR:   return "MIRROR";
    case MODE_BLANK:    return "BLANK";
#endif
    case MODE_PAGE:     return "PAGE";
    default:            return "?";
    }
}

static volatile sig_atomic_t g_run = 1;
static void on_sig(int s) { (void)s; g_run = 0; }
static char g_map_source_path[512];

static void map_source_write(const char *state)
{
    if (!g_map_source_path[0]) return;
    char temporary[560];
    snprintf(temporary, sizeof temporary, "%s.tmp", g_map_source_path);
    FILE *file = fopen(temporary, "w");
    if (!file) return;
    fprintf(file, "%s\n", state);
    if (fclose(file) == 0)
        rename(temporary, g_map_source_path);
    else
        unlink(temporary);
}

typedef struct { float x, z; } Waypoint;
static Waypoint g_wp[64];
static int g_nwp = 0;
static char g_wp_path[512];
static time_t g_wp_mtime = 0;
static uint64_t g_wp_last_check = 0;

/* $BOTTOMD_WAYPOINTS may be a path through a symlink that appears only
 * once the active world is known — (re)load lazily on mtime change. */
static void waypoints_poll(void)
{
    if (!g_wp_path[0]) return;
    uint64_t now = (uint64_t)time(NULL);
    if (now - g_wp_last_check < 1) return;
    g_wp_last_check = now;
    struct stat st;
    if (stat(g_wp_path, &st) != 0) return;
    if (st.st_mtime == g_wp_mtime) return;
    g_wp_mtime = st.st_mtime;
    g_nwp = 0;
    FILE *f = fopen(g_wp_path, "r");
    if (!f) return;
    while (g_nwp < 64 &&
           fscanf(f, "%f %f%*[^\n]", &g_wp[g_nwp].x, &g_wp[g_nwp].z) == 2)
        g_nwp++;
    fclose(f);
}

static void waypoints_save(void)
{
    if (!g_wp_path[0]) return;
    char tmp[600];
    snprintf(tmp, sizeof tmp, "%s.tmp", g_wp_path);
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    for (int i = 0; i < g_nwp; ++i)
        fprintf(f, "%.1f %.1f\n", g_wp[i].x, g_wp[i].z);
    fclose(f);
    rename(tmp, g_wp_path);
    struct stat st;
    if (stat(g_wp_path, &st) == 0) g_wp_mtime = st.st_mtime;
}

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

/* view state: what world position the screen center shows */
static float g_view_x, g_view_z;
static int g_follow = 1; /* follow player until the map is panned */

/* zoom (px per block), set by --zoom and the side slider */
static float g_zoom = 2.0f;
#define ZOOM_MIN 0.5f
#define ZOOM_MAX 6.0f

/* Map controls float over the right edge of the paper sheet. The new shell
 * follows the reference project: persistent HUD above, equal tab buttons
 * below, content in the middle. */
#define SLD_X   (VIEW_X1 - 24)
#define SLD_W   10
#define SLD_KNOB 16
#define SLD_Y0  (VIEW_Y0 + 36)
#define SLD_Y1  (VIEW_Y1 - 74)
#define SLD_H   (SLD_Y1 - SLD_Y0)

#define BTN_W 34
#define BTN_H 34
#define BTN_X (VIEW_X1 - BTN_W - 10)
#define BTN_Y (VIEW_Y1 - BTN_H - 10)

/* Settings intentionally cover only behavior bottomd really owns. Values are
 * process-local for now; the release launcher can supply their defaults via
 * env without touching user game data. */
static int g_show_status = 1;
static int g_night_tint = 1;
static McpeCompanionState g_companion;
static int g_have_companion;
static int g_selected_item = -1;
static int g_chat_keyboard;
static char g_chat_input[256];
static size_t g_chat_input_len;
static uint64_t g_inventory_context_command;

static float slider_pos_from_zoom(void)
{
    return logf(g_zoom / ZOOM_MIN) / logf(ZOOM_MAX / ZOOM_MIN);
}

/* Vertical: top of the track = max zoom, which matches "up = closer". */
static void zoom_from_slider_y(int y)
{
    float pos = 1.0f - (float)(y - SLD_Y0 - SLD_KNOB / 2) /
                           (float)(SLD_H - SLD_KNOB);
    if (pos < 0) pos = 0;
    if (pos > 1) pos = 1;
    g_zoom = ZOOM_MIN * powf(ZOOM_MAX / ZOOM_MIN, pos);
}

/* Is (x,y) in the page body — i.e. not on either side column? */
static int in_view(int x, int y)
{
    return x >= VIEW_X0 && x < VIEW_X1 && y >= VIEW_Y0 && y < VIEW_Y1;
}

/* world (x,z) -> screen, north (-Z) up, east (+X) right.
 * Vertical centre is VIEW_CY, not BOTTOMD_H/2: the tab strip owns the
 * top band and the coords strip the bottom one. */
static void world_to_screen(float zoom, float wx, float wz, int *sx,
                            int *sy)
{
    *sx = (int)lroundf((wx - g_view_x) * zoom) + VIEW_CX;
    *sy = (int)lroundf((wz - g_view_z) * zoom) + VIEW_CY;
}

/* inverse: screen -> world, for tap-to-waypoint and drag panning */
static void screen_to_world(float zoom, int sx, int sy, float *wx,
                            float *wz)
{
    *wx = g_view_x + (sx - VIEW_CX) / zoom;
    *wz = g_view_z + (sy - VIEW_CY) / zoom;
}

/* Procedural 16px earth-toned backdrop. It evokes the quiet tiled block
 * background used by the reference app without redistributing a Minecraft
 * texture. The pattern is deterministic and cheap enough for the software
 * renderer. */
static void draw_backdrop(Canvas *c)
{
    static const uint32_t palette[6] = {
        0xff3a2b24u, 0xff423027u, 0xff49352au,
        0xff513a2du, 0xff352720u, 0xff463126u
    };
    for (int y = 0; y < BOTTOMD_H; ++y) {
        for (int x = 0; x < BOTTOMD_W; ++x) {
            unsigned bx = (unsigned)(x & 15), by = (unsigned)(y & 15);
            unsigned hash = bx * 13u + by * 29u + (bx >> 2) * 7u +
                            (by >> 2) * 11u;
            c->px[y * BOTTOMD_W + x] = palette[hash % 6u];
        }
    }
}

static void draw_heart(Canvas *c, int x, int y, int fill)
{
    /* Nine rows, bit 8 is the leftmost pixel. */
    static const uint16_t mask[9] = {
        0x0cc, 0x1fe, 0x1ff, 0x1ff, 0x0fe, 0x07c, 0x038, 0x010, 0x000
    };
    for (int yy = 0; yy < 9; ++yy)
        for (int xx = 0; xx < 9; ++xx) {
            if (!(mask[yy] & (1u << (8 - xx)))) continue;
            uint32_t col = 0xff3b1717u;
            if (fill == 2 || (fill == 1 && xx <= 4))
                col = yy < 2 ? 0xffff7777u : 0xffd92929u;
            draw_rect(c, x + xx * 2, y + yy * 2, 2, 2, col);
        }
}

static void draw_food(Canvas *c, int x, int y, int fill)
{
    uint32_t dark = 0xff35251du;
    uint32_t meat = fill ? 0xffc47a3au : dark;
    uint32_t light = fill == 2 ? 0xffe7a45du : meat;
    draw_disc(c, x + 6, y + 7, 6, dark);
    draw_disc(c, x + 6, y + 7, 4, light);
    draw_line(c, x + 10, y + 11, x + 15, y + 16, dark);
    draw_disc(c, x + 16, y + 17, 2, fill ? 0xffe5d2b0u : dark);
}

static const char *slot_texture(const McpeCompanionSlot *slot,
                                char *resolved, size_t size)
{
    if (slot->texture_path[0]) return slot->texture_path;
    if (texture_item_path(slot->identifier, slot->texture_variant,
                          resolved, size))
        return resolved;
    return NULL;
}

static void draw_stack(Canvas *c, const McpeCompanionSlot *slot,
                       int x, int y, int size)
{
    if (!slot || !slot->count) return;
    char resolved[160];
    const char *path = slot_texture(slot, resolved, sizeof resolved);
    if (path) texture_draw(c, path, x, y, size, size);
    if (slot->count > 1) {
        char count[8];
        snprintf(count, sizeof count, "%u", slot->count);
        int tw = draw_text_width(count, 1);
        draw_text(c, x + size - tw + 1, y + size - 6, count, 1,
                  0xff202020u);
        draw_text(c, x + size - tw, y + size - 7, count, 1, COL_TEXT);
    }
    if (slot->max_damage && slot->damage < slot->max_damage) {
        int width = (int)((uint32_t)(slot->max_damage - slot->damage) *
                          (uint32_t)(size - 2) / slot->max_damage);
        draw_rect(c, x + 1, y + size - 2, size - 2, 2, 0xff1b1b1bu);
        draw_rect(c, x + 1, y + size - 2, width, 2,
                  width > (size - 2) / 2 ? 0xff55cc44u : 0xffcc5544u);
    }
}

static const McpeCompanionSlot *find_slot(int kind, int index)
{
    if (!g_have_companion) return NULL;
    unsigned count = g_companion.slot_count;
    if (count > MCPE_COMPANION_MAX_SLOTS) count = MCPE_COMPANION_MAX_SLOTS;
    for (unsigned i = 0; i < count; ++i)
        if (g_companion.slots[i].kind == kind &&
            g_companion.slots[i].index == index)
            return &g_companion.slots[i];
    return NULL;
}

static void draw_status_icons(Canvas *c, float value, int food, int right)
{
    int start = right ? BOTTOMD_W - 12 - 10 * 19 : 12;
    for (int i = 0; i < 10; ++i) {
        float remain = value - (float)(i * 2);
        int fill = remain >= 2.0f ? 2 : (remain > 0.0f ? 1 : 0);
        int slot = right ? 9 - i : i;
        int x = start + slot * 19;
        const char *background = food ? "textures/ui/hunger_background" :
                                        "textures/ui/heart_background";
        const char *full = food ? "textures/ui/hunger_full" :
                                  "textures/ui/heart_new";
        if (texture_draw(c, background, x, 7, 18, 18)) {
            if (fill == 2) texture_draw(c, full, x, 7, 18, 18);
            else if (fill == 1) {
                /* Keep half icons honest until the renderer gains source
                 * cropping; the procedural half is drawn over the real
                 * vanilla background. */
                if (food) draw_food(c, x, 7, fill);
                else draw_heart(c, x, 7, fill);
            }
        } else if (food) draw_food(c, x, 8, fill);
        else draw_heart(c, x, 7, fill);
    }
}

static const char *dimension_name(int dimension)
{
    switch (dimension) {
    case 0: return "OVERWORLD";
    case 1: return "NETHER";
    case 2: return "THE END";
    default: return "WORLD";
    }
}

static void draw_status_stack(Canvas *c, const McpeTelemetry *t,
                              uint64_t age_ms)
{
    if (!g_show_status) return;
    draw_rect(c, 0, 0, BOTTOMD_W, STATUS_H, 0xff181412u);
    draw_rect(c, 0, STATUS_H - 2, BOTTOMD_W, 2, 0xff080706u);

    float health = worldinfo_health();
    float hunger = worldinfo_hunger();
    draw_status_icons(c, health < 0 ? 0 : health, 0, 0);
    draw_status_icons(c, hunger < 0 ? 0 : hunger, 1, 1);
    draw_text(c, 12, 29, health < 0 ? "HEALTH --" : "HEALTH SNAPSHOT",
              1, health < 0 ? COL_NOSIG : COL_TEXT);
    const char *hunger_label = hunger < 0 ? "HUNGER --" : "HUNGER SNAPSHOT";
    draw_text(c, BOTTOMD_W - 12 - draw_text_width(hunger_label, 1), 29,
              hunger_label, 1, hunger < 0 ? COL_NOSIG : COL_TEXT);

    const char *dim = dimension_name(worldinfo_dimension());
    draw_text(c, VIEW_CX - draw_text_width(dim, 1) / 2, 10, dim, 1,
              COL_WAYPOINT);
    int live = t && t->magic == MCPE_TELEMETRY_MAGIC && age_ms < 1000;
    const char *state = live ? "BEDROCK LIVE" : "WAITING FOR BEDROCK";
    draw_text(c, VIEW_CX - draw_text_width(state, 1) / 2, 25, state, 1,
              live ? COL_ARROW : COL_WARN);

    /* Independent native bridge hotbar.  Empty/unsupported states remain
     * visibly empty; never invent item art or counts. */
    int slot_w = 25, slots_x = VIEW_CX - (9 * slot_w) / 2;
    for (int i = 0; i < 9; ++i) {
        int x = slots_x + i * slot_w;
        if (!texture_draw(c, "textures/ui/slot_enabled", x, 45, 23, 23)) {
            draw_rect(c, x, 43, slot_w - 2, 30, 0xff2a2928u);
            draw_rect_outline(c, x, 43, slot_w - 2, 30, 0xff686868u);
        }
        const McpeCompanionSlot *slot = find_slot(MCPE_SLOT_HOTBAR, i);
        if (!slot) slot = find_slot(MCPE_SLOT_INVENTORY, i);
        draw_stack(c, slot, x + 2, 47, 19);
        if (g_have_companion && g_companion.selected_slot == i)
            draw_rect_outline(c, x - 1, 42, 25, 29, 0xffffffffu);
    }
    if (!g_have_companion || !(g_companion.capabilities & MCPE_CC_INVENTORY_READ)) {
        const char *pending = g_have_companion ? g_companion.bridge_status :
                                                 "CONNECTING NATIVE BRIDGE";
        int pw = draw_text_width(pending, 1);
        if (pw > 246) pw = 246;
        draw_rect(c, VIEW_CX - 127, 54, 254, 10, 0xff181412u);
        draw_text(c, VIEW_CX - pw / 2, 55, pending, 1, COL_NOSIG);
    }

    if (live) {
        char pos[96];
        snprintf(pos, sizeof pos, "X %.0F  Y %.0F  Z %.0F  %.0F FPS",
                 t->cam_x, t->cam_y, t->cam_z, t->fps_avg_1s);
        draw_text(c, VIEW_CX - draw_text_width(pos, 1) / 2, 69, pos, 1,
                  COL_TEXT);
    }
}

static void draw_mc_button(Canvas *c, int x, int y, int w, int h,
                           const char *label, int selected)
{
    draw_rect(c, x, y, w, h, 0xff242424u);
    draw_rect(c, x + 2, y + 2, w - 4, h - 4,
              selected ? 0xff8a8a8au : 0xff626262u);
    draw_rect(c, x + 2, y + 2, w - 4, 2,
              selected ? 0xffc7c7c7u : 0xffa4a4a4u);
    draw_rect(c, x + 2, y + h - 4, w - 4, 2, 0xff393939u);
    int tw = draw_text_width(label, 2);
    int tx = x + (w - tw) / 2, ty = y + (h - 14) / 2;
    draw_text(c, tx + 2, ty + 2, label, 2, 0xff303030u);
    draw_text(c, tx, ty, label, 2, COL_TEXT);
}

static void render_minimap(Canvas *c, const McpeTelemetry *t, float zoom,
                           int remote_world)
{
    draw_backdrop(c);
    /* Vanilla-map-like paper frame around the live terrain square. */
    draw_rect(c, VIEW_X0 - 10, VIEW_Y0 - 10, MAP_SIZE + 20, MAP_SIZE + 20,
              0xffc9b47du);
    draw_rect_outline(c, VIEW_X0 - 10, VIEW_Y0 - 10,
                      MAP_SIZE + 20, MAP_SIZE + 20, 0xff5c482bu);
    draw_rect(c, VIEW_X0, VIEW_Y0, MAP_SIZE, MAP_SIZE, 0xff182026u);

    /* terrain from the bedrockmap tile cache ($BOTTOMD_TILES).
     * TODO(dim): dimension is fixed to 0 until bottomd merges
     * player.json (see bedrockmap README contract). */
    if (!remote_world && tiles_enabled()) {
        /* DAY/NIGHT + LIGHT SOURCES, done in this one pass rather than a
         * second full-screen tint: we already have the tile lookup here,
         * and a separate pass would cost another 300k samples a frame.
         *
         * daylight scales the whole map; per-block emission (lava,
         * torches, fire, glowstone — the 5th column of block_colors.tsv)
         * pulls that scale back toward full brightness, so light sources
         * still read as lit when everything around them is dark. */
        float day = g_night_tint ? worldinfo_daylight() : 1.0f;
        for (int sy = VIEW_Y0; sy < VIEW_Y1; ++sy)
            for (int sx = VIEW_X0; sx < VIEW_X1; ++sx) {
                int32_t wx = (int32_t)floorf(
                    g_view_x + (sx - VIEW_CX) / zoom);
                int32_t wz = (int32_t)floorf(
                    g_view_z + (sy - VIEW_CY) / zoom);
                uint32_t col;
                if (!tiles_sample(wx, wz, 0, &col)) continue;
                if (day < 0.999f) {
                    float lit = day;
                    uint8_t e = tiles_sample_light(wx, wz, 0);
                    if (e) {
                        float em = (float)e / 255.0f;
                        lit = day + (1.0f - day) * em;
                        if (lit > 1.0f) lit = 1.0f;
                    }
                    /* night is bluer, not merely darker — but a lit
                     * block goes WARM, which is what makes a torch read
                     * as a torch instead of a pale dot */
                    float rf = lit * (0.86f + 0.14f * lit);
                    float gf = lit * (0.94f + 0.06f * lit);
                    float bf = lit * 1.00f + 0.10f * (1.0f - lit);
                    uint32_t r = (uint32_t)(((col >> 16) & 0xff) * rf);
                    uint32_t g = (uint32_t)(((col >> 8) & 0xff) * gf);
                    uint32_t b = (uint32_t)((col & 0xff) * bf);
                    if (r > 255) r = 255;
                    if (g > 255) g = 255;
                    if (b > 255) b = 255;
                    col = 0xff000000u | (r << 16) | (g << 8) | b;
                }
                c->px[sy * BOTTOMD_W + sx] = col;
            }
    }

    /* Shading is applied per-pixel in the tile loop above (it needs the
     * per-block light data), so markers below are never dimmed — the
     * player arrow, waypoints and death marker stay readable at
     * midnight. */

    if (remote_world) {
        const char *line1 = "REMOTE WORLD";
        const char *line2 = "MAP UNAVAILABLE";
        const char *line3 = "LAN CLIENT HAS NO LOCAL CHUNK DB";
        draw_text(c, VIEW_CX - draw_text_width(line1, 3) / 2,
                  VIEW_CY - 64, line1, 3, COL_TEXT);
        draw_text(c, VIEW_CX - draw_text_width(line2, 2) / 2,
                  VIEW_CY - 22, line2, 2, COL_WARN);
        draw_text(c, VIEW_CX - draw_text_width(line3, 1) / 2,
                  VIEW_CY + 10, line3, 1, COL_NOSIG);
    }

    /* waypoints (edge-clamped). A remote world's coordinates must never be
     * mixed with waypoints belonging to the previous local world. */
    for (int i = 0; !remote_world && i < g_nwp; ++i) {
        int sx, sy;
        world_to_screen(zoom, g_wp[i].x, g_wp[i].z, &sx, &sy);
        int cl = sx < VIEW_X0 + 8 || sx >= VIEW_X1 - 8 ||
                 sy < VIEW_Y0 + 8 || sy >= VIEW_Y1 - 8;
        if (sx < VIEW_X0 + 8) sx = VIEW_X0 + 8;
        if (sx >= VIEW_X1 - 8) sx = VIEW_X1 - 9;
        if (sy < VIEW_Y0 + 8) sy = VIEW_Y0 + 8;
        if (sy >= VIEW_Y1 - 8) sy = VIEW_Y1 - 9;
        draw_disc(c, sx, sy, cl ? 4 : 6, COL_WAYPOINT);
    }

    /* death marker: X */
    if (!remote_world && (t->flags & MCPE_TF_PLAYER_DEAD) &&
        t->death_dimension >= 0) {
        int sx, sy;
        world_to_screen(zoom, t->death_x, t->death_z, &sx, &sy);
        if (sx > -10 && sx < BOTTOMD_W + 10 && sy > -10 &&
            sy < BOTTOMD_H + 10) {
            draw_line(c, sx - 6, sy - 6, sx + 6, sy + 6, COL_DEATH);
            draw_line(c, sx - 6, sy + 6, sx + 6, sy - 6, COL_DEATH);
            draw_line(c, sx - 5, sy - 6, sx + 7, sy + 6, COL_DEATH);
        }
    }

    /* player arrow at the player's world position (screen may be
     * panned away); edge-clamped dot when off-screen. Direction from
     * the raw forward vector (no trig). */
    float fx = t->fwd_x, fz = t->fwd_z;
    float len = sqrtf(fx * fx + fz * fz);
    if (len < 1e-3f) { fx = 0; fz = -1; len = 1; }
    fx /= len; fz /= len;
    int cx, cy;
    world_to_screen(zoom, t->cam_x, t->cam_z, &cx, &cy);
    if (cx >= -20 && cx < BOTTOMD_W + 20 && cy >= -20 &&
        cy < BOTTOMD_H + 20) {
        float tipx = cx + fx * 14, tipy = cy + fz * 14;
        float bx = cx - fx * 8, by = cy - fz * 8;   /* base center */
        float px = -fz, py = fx;                    /* perpendicular */
        draw_tri(c, (int)tipx, (int)tipy, (int)(bx + px * 8),
                 (int)(by + py * 8), (int)(bx - px * 8),
                 (int)(by - py * 8), COL_ARROW);
        draw_disc(c, cx, cy, 2, COL_ARROW_RIM);
    } else {
        int ex = cx < VIEW_X0 + 8 ? VIEW_X0 + 8
                                  : (cx >= VIEW_X1 - 8 ? VIEW_X1 - 9 : cx);
        int ey = cy < VIEW_Y0 + 8 ? VIEW_Y0 + 8
                                  : (cy >= VIEW_Y1 - 8 ? VIEW_Y1 - 9 : cy);
        draw_disc(c, ex, ey, 5, COL_ARROW);
    }

    /* north marker: top centre of the map viewport */
    draw_disc(c, VIEW_CX, VIEW_Y0 + 8, 3, COL_DEATH);

    /* Compact overlay controls preserve the paper-first look. */
    draw_rect(c, SLD_X - 7, SLD_Y0 - 28, SLD_W + 14,
              SLD_H + 56, 0xcc111111u);
    int cxp = SLD_X + SLD_W / 2;
    draw_rect(c, cxp - 7, SLD_Y0 - 16, 14, 2, COL_NOSIG);
    draw_rect(c, cxp - 1, SLD_Y0 - 22, 2, 14, COL_NOSIG);
    draw_rect(c, cxp - 7, SLD_Y1 + 12, 14, 2, COL_NOSIG);

    draw_rect(c, SLD_X, SLD_Y0, SLD_W, SLD_H, COL_GRID);
    draw_rect_outline(c, SLD_X, SLD_Y0, SLD_W, SLD_H, COL_GRID_MAJ);
    int ky = SLD_Y0 + (int)((1.0f - slider_pos_from_zoom()) *
                            (SLD_H - SLD_KNOB));
    draw_rect(c, SLD_X - 4, ky, SLD_W + 8, SLD_KNOB, COL_ACCENT);

    /* centre-on-player: target icon, accented while following */
    uint32_t bcol = g_follow ? COL_ARROW : COL_NOSIG;
    draw_rect(c, BTN_X, BTN_Y, BTN_W, BTN_H, 0xcc111111u);
    draw_rect_outline(c, BTN_X, BTN_Y, BTN_W, BTN_H, bcol);
    int bx0 = BTN_X + BTN_W / 2, by0 = BTN_Y + BTN_H / 2;
    draw_disc(c, bx0, by0, 4, bcol);
    draw_line(c, bx0 - 14, by0, bx0 - 6, by0, bcol);
    draw_line(c, bx0 + 6, by0, bx0 + 14, by0, bcol);
    draw_line(c, bx0, by0 - 14, bx0, by0 - 6, bcol);
    draw_line(c, bx0, by0 + 6, bx0, by0 + 14, bcol);
}

#define CHAT_INPUT_Y (CONTENT_Y1 - 48)

static void draw_chat_button(Canvas *c, int x, int y, int w, const char *label)
{
    draw_mc_button(c, x, y, w, 36, label, 0);
}

static void render_chat_keyboard(Canvas *c)
{
    static const char *rows[] = { "QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM" };
    static const int lengths[] = { 10, 9, 7 };
    int ys[] = { 210, 250, 290 };
    for (int row = 0; row < 3; ++row) {
        int key = 48, gap = 4;
        int total = lengths[row] * key + (lengths[row] - 1) * gap;
        int start = (BOTTOMD_W - total) / 2;
        for (int col = 0; col < lengths[row]; ++col) {
            char label[2] = { rows[row][col], 0 };
            draw_chat_button(c, start + col * (key + gap), ys[row], key,
                             label);
        }
    }
    draw_chat_button(c, 40, 334, 108, "BACK");
    draw_chat_button(c, 154, 334, 252, "SPACE");
    draw_chat_button(c, 412, 334, 90, "CLOSE");
    draw_chat_button(c, 508, 334, 92, "SEND");
}

static void render_chat(Canvas *c)
{
    draw_backdrop(c);
    draw_rect(c, 26, CONTENT_Y0 + 8, BOTTOMD_W - 52,
              CONTENT_Y1 - CONTENT_Y0 - 16, 0xe0151515u);
    draw_rect_outline(c, 26, CONTENT_Y0 + 8, BOTTOMD_W - 52,
                      CONTENT_Y1 - CONTENT_Y0 - 16, 0xff777777u);
    draw_text(c, 40, CONTENT_Y0 + 18, "INDEPENDENT CHAT", 2, COL_TEXT);
    const char *status = g_have_companion ? g_companion.bridge_status :
                                            "CONNECTING NATIVE BRIDGE";
    draw_text(c, 40, CONTENT_Y0 + 42, status, 1,
              g_have_companion && (g_companion.capabilities & MCPE_CC_CHAT_READ)
                  ? COL_ARROW : COL_WARN);

    unsigned count = g_have_companion ? g_companion.chat_count : 0;
    if (count > MCPE_COMPANION_MAX_CHAT) count = MCPE_COMPANION_MAX_CHAT;
    unsigned visible = g_chat_keyboard ? 4 : 11;
    unsigned first = count > visible ? count - visible : 0;
    int y = CONTENT_Y0 + 64;
    for (unsigned i = first; i < count; ++i, y += 18) {
        char line[94];
        if (g_companion.chat[i].sender[0])
            snprintf(line, sizeof line, "<%.24s> %.60s",
                     g_companion.chat[i].sender, g_companion.chat[i].message);
        else
            snprintf(line, sizeof line, "%.90s", g_companion.chat[i].message);
        draw_text(c, 40, y, line, 1, COL_TEXT);
    }
    if (!count)
        draw_text(c, 40, CONTENT_Y0 + 76,
                  "NO CHAT LINES PUBLISHED BY BEDROCK YET", 1, COL_NOSIG);

    int input_y = g_chat_keyboard ? 170 : CHAT_INPUT_Y;
    draw_rect(c, 40, input_y, 454, 34, 0xff080808u);
    draw_rect_outline(c, 40, input_y, 454, 34,
                      g_chat_keyboard ? COL_ACCENT : 0xff777777u);
    char display[80];
    snprintf(display, sizeof display, "%.77s%s", g_chat_input,
             g_chat_keyboard ? "_" : "");
    draw_text(c, 50, input_y + 13, display[0] ? display : "TAP TO TYPE", 1,
              display[0] ? COL_TEXT : COL_NOSIG);
    if (g_chat_keyboard)
        render_chat_keyboard(c);
    else
        draw_mc_button(c, 504, input_y, 96, 34, "TYPE", 0);
}

#define INV_X 34
#define INV_Y 82
#define INV_SLOT 36

static void visual_slot_address(int visual, int *kind, int *index)
{
    if (visual < 27) {
        *kind = MCPE_SLOT_INVENTORY;
        *index = visual + 9;
    } else {
        *kind = MCPE_SLOT_HOTBAR;
        *index = visual - 27;
    }
}

static const McpeCompanionSlot *visual_slot(int visual)
{
    int kind, index;
    visual_slot_address(visual, &kind, &index);
    const McpeCompanionSlot *slot = find_slot(kind, index);
    if (!slot && kind == MCPE_SLOT_HOTBAR)
        slot = find_slot(MCPE_SLOT_INVENTORY, index);
    return slot;
}

static int inventory_slot_y(int row)
{
    return INV_Y + row * INV_SLOT + (row == 3 ? 12 : 0);
}

static void render_items(Canvas *c)
{
    draw_backdrop(c);
    draw_rect(c, 18, 12, BOTTOMD_W - 36, CONTENT_Y1 - 20, 0xffc6c6c6u);
    draw_rect_outline(c, 18, 12, BOTTOMD_W - 36, CONTENT_Y1 - 20,
                      0xff414141u);
    draw_text(c, 34, 28, "INVENTORY", 2, 0xff3f3f3fu);
    draw_text(c, 386, 28, "CRAFTABLE", 2, 0xff3f3f3fu);

    const char *status = g_have_companion ? g_companion.bridge_status :
                                            "CONNECTING NATIVE BRIDGE";
    draw_text(c, 34, 53, status, 1,
              g_have_companion && (g_companion.capabilities & MCPE_CC_INVENTORY_READ)
                  ? 0xff285d28u : 0xff8a4128u);

    for (int visual = 0; visual < 36; ++visual) {
        int row = visual / 9, col = visual % 9;
        int x = INV_X + col * INV_SLOT, y = inventory_slot_y(row);
        if (!texture_draw(c, "textures/ui/slot_enabled", x, y,
                          INV_SLOT - 2, INV_SLOT - 2)) {
            draw_rect(c, x, y, INV_SLOT - 2, INV_SLOT - 2, 0xff8b8b8bu);
            draw_rect_outline(c, x, y, INV_SLOT - 2, INV_SLOT - 2,
                              0xff373737u);
        }
        draw_stack(c, visual_slot(visual), x + 3, y + 3, INV_SLOT - 8);
        if (visual == g_selected_item)
            draw_rect_outline(c, x - 2, y - 2, INV_SLOT + 2, INV_SLOT + 2,
                              0xffffffffu);
    }
    draw_text(c, INV_X, INV_Y + INV_SLOT * 3 + 2, "HOTBAR", 1,
              0xff505050u);

    unsigned recipes = g_have_companion ? g_companion.recipe_count : 0;
    if (recipes > MCPE_COMPANION_MAX_RECIPES) recipes = MCPE_COMPANION_MAX_RECIPES;
    if (recipes > 6) recipes = 6;
    for (unsigned i = 0; i < recipes; ++i) {
        int x = 386, y = 72 + (int)i * 50;
        draw_rect(c, x, y, 220, 44, 0xff8b8b8bu);
        draw_rect_outline(c, x, y, 220, 44, 0xff454545u);
        char resolved[160];
        const char *path = g_companion.recipes[i].texture_path[0]
            ? g_companion.recipes[i].texture_path
            : (texture_item_path(g_companion.recipes[i].identifier, 0,
                                 resolved, sizeof resolved) ? resolved : NULL);
        if (path) texture_draw(c, path, x + 5, y + 5, 34, 34);
        char name[25];
        snprintf(name, sizeof name, "%.24s", g_companion.recipes[i].display_name[0]
                 ? g_companion.recipes[i].display_name
                 : g_companion.recipes[i].identifier);
        draw_text(c, x + 44, y + 8, name, 1, 0xff292929u);
        char count[20];
        snprintf(count, sizeof count, "MAKE %u", g_companion.recipes[i].craftable_count);
        draw_text(c, x + 44, y + 25, count, 1, 0xff505050u);
    }
    if (!recipes)
        draw_text(c, 386, 86, "NO RECIPES PUBLISHED", 1, 0xff666666u);

    const char *hint = (g_companion.capabilities & MCPE_CC_INVENTORY_MOVE)
        ? "TAP SOURCE THEN DESTINATION   RECIPE TAP CRAFTS ONE"
        : ((g_companion.capabilities & MCPE_CC_INVENTORY_READ)
            ? "LIVE INVENTORY - MOVE AND CRAFT TRANSACTIONS NOT YET ENABLED"
            : "READ ONLY UNTIL THE EXACT BEDROCK HOOK VALIDATES");
    draw_text(c, 34, CONTENT_Y1 - 28, hint, 1, 0xff555555u);
}

#define GRID_X 55
#define GRID_Y (CONTENT_Y0 + 38)
#define GRID_W 164
#define GRID_H 58
#define GRID_GAP_X 19
#define GRID_GAP_Y 16

static const char *g_input_labels[9] = {
    "HUD", "CENTER", "ZOOM +",
    "ITEMS", "SWAP", "ZOOM -",
    "CHAT", "KEYBOARD", "SETTINGS"
};

static void render_input(Canvas *c)
{
    draw_backdrop(c);
    const char *title = "COMPANION CONTROLS";
    draw_text(c, VIEW_CX - draw_text_width(title, 2) / 2,
              CONTENT_Y0 + 10, title, 2, COL_TEXT);
    for (int row = 0; row < 3; ++row)
        for (int col = 0; col < 3; ++col) {
            int index = row * 3 + col;
            int x = GRID_X + col * (GRID_W + GRID_GAP_X);
            int y = GRID_Y + row * (GRID_H + GRID_GAP_Y);
            draw_mc_button(c, x, y, GRID_W, GRID_H,
                           g_input_labels[index], 0);
        }
    const char *note = "GAME KEYBIND RELAY NEEDS A VERSION SPECIFIC BEDROCK HOOK";
    draw_text(c, VIEW_CX - draw_text_width(note, 1) / 2,
              CONTENT_Y1 - 20, note, 1, COL_NOSIG);
}

static void draw_setting(Canvas *c, int row, const char *label,
                         const char *description, int enabled)
{
    int x = 72, y = CONTENT_Y0 + 28 + row * 66, w = BOTTOMD_W - 144;
    draw_rect(c, x, y, w, 56, 0xcc161616u);
    draw_text(c, x + 12, y + 10, label, 2, COL_TEXT);
    draw_text(c, x + 12, y + 34, description, 1, COL_NOSIG);
    draw_mc_button(c, x + w - 112, y + 8, 96, 40,
                   enabled ? "ON" : "OFF", enabled);
}

static void render_settings(Canvas *c)
{
    draw_backdrop(c);
    const char *title = "SETTINGS";
    draw_text(c, VIEW_CX - draw_text_width(title, 2) / 2,
              CONTENT_Y0 + 7, title, 2, COL_TEXT);
    draw_setting(c, 0, "STATUS HUD", "HEALTH HUNGER POSITION AND FEED", g_show_status);
    draw_setting(c, 1, "AUTO ITEMS", "FOLLOW BEDROCK OPEN AND CLOSE SIGNALS", pages_auto_items());
    draw_setting(c, 2, "NIGHT MAP", "SHADE TERRAIN USING WORLD TIME", g_night_tint);
    draw_setting(c, 3, "FOLLOW PLAYER", "KEEP PLAYER CENTERED ON THE MAP", g_follow);
}

static void launch_osk(void)
{
    const char *path = getenv("BOTTOMD_OSK_SHOW_CMD");
    if (!path || !path[0]) {
        fprintf(stderr, "bottomd: keyboard unavailable (BOTTOMD_OSK_SHOW_CMD unset)\n");
        return;
    }
    pid_t child = fork();
    if (child == 0) {
        setenv("MCPE_OSK_REASON", "bottomd chat/input button", 1);
        execl(path, path, (char *)NULL);
        _exit(127);
    }
}

static int in_rect(int x, int y, int rx, int ry, int rw, int rh)
{
    return x >= rx && x < rx + rw && y >= ry && y < ry + rh;
}

static void chat_append(char character)
{
    if (g_chat_input_len + 1 >= sizeof g_chat_input) return;
    g_chat_input[g_chat_input_len++] = character;
    g_chat_input[g_chat_input_len] = 0;
}

static void handle_chat_keyboard_tap(int x, int y)
{
    static const char *rows[] = { "QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM" };
    static const int lengths[] = { 10, 9, 7 };
    int ys[] = { 210, 250, 290 };
    for (int row = 0; row < 3; ++row) {
        int key = 48, gap = 4;
        int total = lengths[row] * key + (lengths[row] - 1) * gap;
        int start = (BOTTOMD_W - total) / 2;
        if (y < ys[row] || y >= ys[row] + 36 || x < start) continue;
        int column = (x - start) / (key + gap);
        int offset = (x - start) % (key + gap);
        if (column < lengths[row] && offset < key)
            chat_append(rows[row][column]);
        return;
    }
    if (in_rect(x, y, 40, 334, 108, 36)) {
        if (g_chat_input_len) g_chat_input[--g_chat_input_len] = 0;
    } else if (in_rect(x, y, 154, 334, 252, 36)) {
        chat_append(' ');
    } else if (in_rect(x, y, 412, 334, 90, 36)) {
        g_chat_keyboard = 0;
    } else if (in_rect(x, y, 508, 334, 92, 36)) {
        if (g_chat_input_len && g_have_companion &&
            (g_companion.capabilities & MCPE_CC_CHAT_SEND)) {
            companion_send(MCPE_CMD_SEND_CHAT, 0, -1, 0, -1, 0, 0,
                           g_chat_input);
            g_chat_input_len = 0;
            g_chat_input[0] = 0;
            g_chat_keyboard = 0;
        }
    }
}

static void handle_items_tap(int x, int y)
{
    if (x >= INV_X && x < INV_X + 9 * INV_SLOT) {
        int col = (x - INV_X) / INV_SLOT;
        int row = -1;
        for (int candidate = 0; candidate < 4; ++candidate) {
            int slot_y = inventory_slot_y(candidate);
            if (y >= slot_y && y < slot_y + INV_SLOT) {
                row = candidate;
                break;
            }
        }
        if (row < 0) return;
        int visual = row * 9 + col;
        if (g_selected_item < 0) {
            const McpeCompanionSlot *source = visual_slot(visual);
            if (source && source->count) g_selected_item = visual;
            return;
        }
        int source_kind, source_slot, destination_kind, destination_slot;
        visual_slot_address(g_selected_item, &source_kind, &source_slot);
        visual_slot_address(visual, &destination_kind, &destination_slot);
        if (g_have_companion && !g_inventory_context_command &&
            (g_companion.capabilities & MCPE_CC_INVENTORY_MOVE) &&
            keyfwd_available()) {
            uint64_t command = companion_send(
                MCPE_CMD_MOVE_STACK, source_kind, source_slot,
                destination_kind, destination_slot, 0, 0, NULL);
            if (command) {
                g_inventory_context_command = command;
                if (keyfwd_toggle_inventory())
                    fprintf(stderr,
                            "bottomd: native inventory context opened for move %llu\n",
                            (unsigned long long)command);
                else
                    fprintf(stderr,
                            "bottomd: native inventory context key failed for move %llu\n",
                            (unsigned long long)command);
            }
        }
        g_selected_item = -1;
        return;
    }
    if (x >= 386 && x < 606 && y >= 72) {
        int recipe = (y - 72) / 50;
        unsigned count = g_have_companion ? g_companion.recipe_count : 0;
        if (count > MCPE_COMPANION_MAX_RECIPES) count = MCPE_COMPANION_MAX_RECIPES;
        if (recipe >= 0 && (unsigned)recipe < count && recipe < 6 &&
            (g_companion.capabilities & MCPE_CC_CRAFTING_DO))
            companion_send(MCPE_CMD_CRAFT_RECIPE, 0, -1, 0, -1, 1,
                           g_companion.recipes[recipe].network_id, NULL);
    }
}

static void handle_page_tap(int x, int y)
{
    if (pages_active() == PAGE_CHAT) {
        if (g_chat_keyboard) handle_chat_keyboard_tap(x, y);
        else if (in_rect(x, y, 40, CHAT_INPUT_Y, 560, 34))
            g_chat_keyboard = 1;
        return;
    }
    if (pages_active() == PAGE_ITEMS) {
        handle_items_tap(x, y);
        return;
    }
    if (pages_active() == PAGE_INPUT) {
        for (int row = 0; row < 3; ++row)
            for (int col = 0; col < 3; ++col) {
                int bx = GRID_X + col * (GRID_W + GRID_GAP_X);
                int by = GRID_Y + row * (GRID_H + GRID_GAP_Y);
                if (!in_rect(x, y, bx, by, GRID_W, GRID_H)) continue;
                switch (row * 3 + col) {
                case 0: pages_set(PAGE_HUD); break;
                case 1: g_follow = 1; break;
                case 2: g_zoom *= 1.35f; break;
                case 3: pages_set(PAGE_ITEMS); break;
                case 4: screenflip_toggle(); break;
                case 5: g_zoom /= 1.35f; break;
                case 6: pages_set(PAGE_CHAT); break;
                case 7: launch_osk(); break;
                case 8: pages_set(PAGE_SETTINGS); break;
                }
                if (g_zoom < ZOOM_MIN) g_zoom = ZOOM_MIN;
                if (g_zoom > ZOOM_MAX) g_zoom = ZOOM_MAX;
                return;
            }
        return;
    }
    if (pages_active() == PAGE_SETTINGS) {
        for (int row = 0; row < 4; ++row) {
            int sy = CONTENT_Y0 + 28 + row * 66;
            if (!in_rect(x, y, 72, sy, BOTTOMD_W - 144, 56)) continue;
            if (row == 0) g_show_status = !g_show_status;
            else if (row == 1) pages_set_auto_items(!pages_auto_items());
            else if (row == 2) g_night_tint = !g_night_tint;
            else if (row == 3) g_follow = !g_follow;
            return;
        }
    }
}

/* Deliberately blank — opt-in only (BOTTOMD_BLANK_ON_CONTAINER=1). A
 * thin border stays lit so "blank by choice" is visually distinct from
 * "panel died". */
static void render_blank(Canvas *c)
{
    draw_clear(c, 0xff000000);
    draw_rect_outline(c, 0, 0, BOTTOMD_W, BOTTOMD_H, 0xff141820);
}

static void render_nosignal(Canvas *c, int blink)
{
    draw_backdrop(c);
    draw_rect(c, 110, CONTENT_Y0 + 58, BOTTOMD_W - 220, 154,
              0xcc111111u);
    draw_rect_outline(c, 110, CONTENT_Y0 + 58, BOTTOMD_W - 220, 154,
                      COL_NOSIG);
    const char *title = "WAITING FOR MINECRAFT BEDROCK";
    draw_text(c, VIEW_CX - draw_text_width(title, 2) / 2,
              CONTENT_Y0 + 96, title, 2, COL_TEXT);
    const char *hint = "START THE GAME OR LOAD A WORLD";
    draw_text(c, VIEW_CX - draw_text_width(hint, 1) / 2,
              CONTENT_Y0 + 140, hint, 1, COL_NOSIG);
    if (blink)
        draw_disc(c, VIEW_CX, CONTENT_Y0 + 178, 6, COL_ACCENT);
}

/* Draw whatever tab is active. Shared by MODE_PAGE and MODE_STALE — the
 * stale path is "the same page, from the last known-good sample". */
static void render_page(Canvas *c, const McpeTelemetry *t, float zoom,
                        uint64_t age_ms, int remote_world)
{
    switch (pages_active()) {
    case PAGE_CHAT:     render_chat(c);                        break;
    case PAGE_ITEMS:    render_items(c);                       break;
    case PAGE_INPUT:    render_input(c);                       break;
    case PAGE_SETTINGS: render_settings(c);                    break;
    case PAGE_HUD:
    default:            render_minimap(c, t, zoom, remote_world); break;
    }
    if (pages_active() != PAGE_ITEMS)
        draw_status_stack(c, t, age_ms);
}

/* STALE overlay: the last known-good page, dimmed, with an age badge and
 * a blinking warn border. Never blank just because the feed paused — the
 * player would rather see a slightly old map than nothing (P6). */
static void render_stale_overlay(Canvas *c, uint64_t age_ms, int blink)
{
    draw_dim(c, 2, 5);
    if (blink)
        draw_rect_outline(c, 0, 0, BOTTOMD_W, BOTTOMD_H, COL_WARN);
    int bx = 6, by = STATUS_H + 4;
    draw_rect(c, bx, by, 150, 24, 0xff1a1208);
    draw_rect_outline(c, bx, by, 150, 24, COL_WARN);
    draw_text(c, bx + 6, by + 8, "STALE", 1, COL_WARN);
    draw_number(c, bx + 48, by + 4, (double)age_ms / 1000.0, 1, 2,
                COL_WARN);
    draw_text(c, bx + 128, by + 8, "S", 1, COL_WARN);
}

/* ---- mode state machine (P2/P4) ---------------------------------- *
 * ONE funnel. Every frame resolves to exactly one named mode with a
 * reason string, and every transition is logged. If the bottom screen
 * is black, bottomd.log says which mode did it and why. */
static int g_blank_on_container = 0;
static uint64_t g_dead_ns = 30000000000ull; /* BOTTOMD_DEAD_MS */

typedef struct {
    Mode        mode;
    const char *reason;
    uint64_t    age_ms;
} ModeDecision;

static ModeDecision resolve_mode(int have_data, const McpeTelemetry *t,
                                 uint64_t stale_ns)
{
    ModeDecision d = { MODE_NOSIGNAL, "no telemetry mapped yet", 0 };

    if (!have_data)
        return d;
    if (t->update_ns == 0) {
        d.reason = "writer up, no camera feed yet";
        return d;
    }

    uint64_t now = now_ns();
    uint64_t age_ns = now > t->update_ns ? now - t->update_ns : 0;
    d.age_ms = age_ns / 1000000ull;

    /* A flag from a feed that stopped long ago cannot be trusted: if the
     * game crashed with a container open, MCPE_TF_CONTAINER_OPEN stays
     * set in the shm forever. Past the dead threshold, nothing but STALE
     * is reachable — no flag may strand the panel. The threshold is well
     * above the normal stale one so that a container legitimately pausing
     * the camera feed does not immediately drop us out of MIRROR. */
    if (age_ns > g_dead_ns) {
        d.mode = MODE_STALE;
        d.reason = "feed dead, flags no longer trusted";
        return d;
    }

    if (t->flags & MCPE_TF_CONTAINER_OPEN) {
        if (g_blank_on_container) {
            d.mode = MODE_BLANK;
            d.reason = "container open, BOTTOMD_BLANK_ON_CONTAINER=1";
            return d;
        }
        /* No mirror to show and no opt-in to blank: fall through to the
         * page layer, which has already auto-switched to the ITEMS tab.
         * A container being open is not a reason to lose the screen. */
    }

    if (age_ns > stale_ns) {
        d.mode = MODE_STALE;
        d.reason = "telemetry aged out, showing last known good";
        return d;
    }

    d.mode = MODE_PAGE;
    d.reason = "live";
    return d;
}

int main(int argc, char **argv)
{
    const char *backend_name = "fbdev", *outdir = ".";
    int max_frames = 0, fps = 20;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--backend") && i + 1 < argc)
            backend_name = argv[++i];
        else if (!strcmp(argv[i], "--outdir") && i + 1 < argc)
            outdir = argv[++i];
        else if (!strcmp(argv[i], "--frames") && i + 1 < argc)
            max_frames = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--fps") && i + 1 < argc)
            fps = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--zoom") && i + 1 < argc)
            g_zoom = (float)atof(argv[++i]);
    }
    if (g_zoom < ZOOM_MIN) g_zoom = ZOOM_MIN;
    if (g_zoom > ZOOM_MAX) g_zoom = ZOOM_MAX;
    if (fps < 1) fps = 1;

    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);
    signal(SIGCHLD, SIG_IGN);
    const char *wpp = getenv("BOTTOMD_WAYPOINTS");
    if (wpp && wpp[0])
        snprintf(g_wp_path, sizeof g_wp_path, "%s", wpp);

    companion_init();
    texture_init();
    touchfwd_init();
    keyfwd_init();
    gamepad_init();
    screenflip_init();
    worldinfo_init();
#ifdef BOTTOMD_STABLE_RELEASE
    /* The two RGDS panels share one Sway identifier. On ROCKNIX only the
     * physical top panel reliably reaches a moved Wayland surface, so native
     * surface placement alone is not sufficient for the map controls. Grab
     * exactly the panel that currently displays bottomd and read it directly;
     * the game panel remains ungrabbed and continues through the compositor. */
    static PanelTouch pt_map;
    const char *panel_bottom = getenv("BOTTOMD_PANEL_BOTTOM");
    const char *panel_top = getenv("BOTTOMD_PANEL_TOP");
    if (!panel_bottom) panel_bottom = "";
    if (!panel_top) panel_top = "";
    if (paneltouch_open(&pt_map, panel_bottom) != 0)
        fprintf(stderr, "bottomd: map-panel raw touch unavailable; using Wayland fallback\n");
#else
    static PanelTouch pt_bottom, pt_top;
    const char *panel_bottom = getenv("BOTTOMD_PANEL_BOTTOM");
    if (!panel_bottom) panel_bottom = "";
    const char *panel_top = getenv("BOTTOMD_PANEL_TOP");
    if (!panel_top) panel_top = "";
    /* Sway reports both physical panels with the same Goodix identifier.
     * A Wayland surface therefore cannot reliably receive the lower panel's
     * touches.  Read the panel that currently displays bottomd directly
     * from startup; the game-facing top panel remains owned by the nested
     * compositor. */
    if (paneltouch_open(&pt_bottom, panel_bottom) != 0)
        fprintf(stderr, "bottomd: bottom-panel raw touch unavailable; using Wayland fallback\n");
#endif
#ifndef BOTTOMD_STABLE_RELEASE
    const char *boc = getenv("BOTTOMD_BLANK_ON_CONTAINER");
    g_blank_on_container = boc && boc[0] == '1';
#endif

    uint64_t stale_ns = 5000000000ull;
    const char *sms = getenv("BOTTOMD_STALE_MS");
    if (sms && sms[0]) {
        long v = atol(sms);
        if (v >= 250) stale_ns = (uint64_t)v * 1000000ull;
    }
    const char *dms = getenv("BOTTOMD_DEAD_MS");
    if (dms && dms[0]) {
        long v = atol(dms);
        if (v >= 1000) g_dead_ns = (uint64_t)v * 1000000ull;
    }
    if (g_dead_ns < stale_ns) g_dead_ns = stale_ns;
    fprintf(stderr,
#ifndef BOTTOMD_STABLE_RELEASE
            "bottomd: stale_ms=%llu dead_ms=%llu independent_companion=1 "
            "blank_on_container=%d\n",
            (unsigned long long)(stale_ns / 1000000ull),
            (unsigned long long)(g_dead_ns / 1000000ull),
            g_blank_on_container);
#else
            "bottomd: stable-core stale_ms=%llu dead_ms=%llu\n",
            (unsigned long long)(stale_ns / 1000000ull),
            (unsigned long long)(g_dead_ns / 1000000ull));
#endif

    tiles_init();
    const char *map_source = getenv("BOTTOMD_MAP_SOURCE");
    if (map_source && map_source[0]) {
        snprintf(g_map_source_path, sizeof g_map_source_path, "%s",
                 map_source);
        map_source_write("unknown");
    }

    Backend *be = NULL;
    if (!strcmp(backend_name, "ppm"))
        be = backend_ppm_create(outdir);
    else if (!strcmp(backend_name, "fbdev"))
        be = backend_fbdev_create();
#ifdef BOTTOMD_HAVE_WAYLAND
    else if (!strcmp(backend_name, "wayland"))
        be = backend_wayland_create();
#endif
    else {
        fprintf(stderr, "bottomd: unknown backend '%s'\n", backend_name);
        return 2;
    }
    if (!be || be->init(be) != 0) {
        fprintf(stderr, "bottomd: backend '%s' init failed\n",
                backend_name);
        return 1;
    }

    /* map telemetry (retry while absent — game may start later) */
    const char *shm_name = getenv("MCPE_TELEMETRY_SHM");
    if (!shm_name || shm_name[0] != '/')
        shm_name = MCPE_TELEMETRY_SHM_DEFAULT;
    const volatile McpeTelemetry *shm = NULL;

    static uint32_t pixels[BOTTOMD_W * BOTTOMD_H];
    Canvas canvas = { pixels };
    McpeTelemetry t;
    memset(&t, 0, sizeof t);
    int have_data = 0, frame = 0;
    int remote_world = 0, map_source_known = 0;
    pages_init(0);
    /* BOTTOMD_PAGE=hud|chat|items|input|settings — start on a given tab. For
     * screenshotting and on-device debugging without touch. */
    const char *p0 = getenv("BOTTOMD_PAGE");
    if (p0 && p0[0]) {
        if (!strcmp(p0, "hud") || !strcmp(p0, "map")) pages_set(PAGE_HUD);
        else if (!strcmp(p0, "chat"))     pages_set(PAGE_CHAT);
        else if (!strcmp(p0, "items")) pages_set(PAGE_ITEMS);
        else if (!strcmp(p0, "input")) pages_set(PAGE_INPUT);
        else if (!strcmp(p0, "settings")) pages_set(PAGE_SETTINGS);
        else fprintf(stderr, "bottomd: unknown BOTTOMD_PAGE '%s'\n", p0);
    }
    const char *auto_items = getenv("BOTTOMD_AUTO_ITEMS");
    if (auto_items && auto_items[0])
        pages_set_auto_items(auto_items[0] != '0');
    const char *show_status = getenv("BOTTOMD_SHOW_STATUS");
    if (show_status && show_status[0]) g_show_status = show_status[0] != '0';
    const char *night_tint = getenv("BOTTOMD_NIGHT_TINT");
    if (night_tint && night_tint[0]) g_night_tint = night_tint[0] != '0';
    /* start in NOSIGNAL so the first resolve always logs a transition */
    Mode cur_mode = MODE_NOSIGNAL;

    /* touch gesture state */
    int tch_active = 0, tch_id = 0, tch_moved = 0, tch_slider = 0;
    int tch_tab = 0; /* gesture started on the tab strip */

#ifndef BOTTOMD_STABLE_RELEASE
    /* Experimental ITEMS auto-release is source-only. */
    float last_cx = 0, last_cz = 0, last_yaw = 0;
    int move_frames = 0;
    int autorelease_frames = fps; /* ~1 s */
    const char *arms = getenv("BOTTOMD_ITEMS_AUTORELEASE_MS");
    if (arms && arms[0]) {
        long v = atol(arms);
        autorelease_frames = v <= 0 ? 0 : (int)((v * fps) / 1000);
        if (v > 0 && autorelease_frames < 1) autorelease_frames = 1;
    }
#endif
    int tch_x0 = 0, tch_y0 = 0, tch_x = 0, tch_y = 0;
    float tch_view0x = 0, tch_view0z = 0;

    while (g_run && (max_frames == 0 || frame < max_frames)) {
        if (frame % fps == 0) screenflip_refresh_touch();
        if (!shm) {
            int fd = shm_open(shm_name, O_RDONLY, 0);
            if (fd >= 0) {
                shm = mmap(NULL, sizeof(McpeTelemetry), PROT_READ,
                           MAP_SHARED, fd, 0);
                close(fd);
                if (shm == MAP_FAILED) shm = NULL;
            }
        }
        /* mcpe_telemetry_read only overwrites `t` on a good snapshot, so
         * `t` IS the last-known-good sample once have_data is set. */
        if (shm && mcpe_telemetry_read(shm, &t))
            have_data = 1;
        McpeCompanionState companion_snapshot;
        if (companion_read(&companion_snapshot)) {
            g_companion = companion_snapshot;
            g_have_companion = 1;
            if (g_inventory_context_command &&
                g_companion.command_ack >= g_inventory_context_command &&
                !(g_companion.flags & MCPE_CS_COMMAND_BUSY)) {
                uint64_t completed = g_inventory_context_command;
                g_inventory_context_command = 0;
                if (keyfwd_toggle_inventory())
                    fprintf(stderr,
                            "bottomd: native inventory context closed after move %llu result=%u\n",
                            (unsigned long long)completed,
                            g_companion.command_result);
            }
        }

        /* Page layer sees the raw flag: it owns auto-switch to ITEMS on
         * open and — critically — RESTORE of the previous tab on close.
         * On 1.16.221.01 this flag never sets (the game never calls
         * lockCursor/unlockCursor), so in practice the user drives the
         * ITEMS tab by hand — which is exactly why the capture request
         * below is keyed off the TAB and not off the flag. */
        pages_container(have_data && (t.flags & MCPE_TF_CONTAINER_OPEN));

        ModeDecision md = resolve_mode(have_data, &t, stale_ns);
        if (md.mode != cur_mode) {
            fprintf(stderr,
                    "bottomd: mode %s -> %s (%s; age=%llums flags=0x%x)\n",
                    mode_name(cur_mode), mode_name(md.mode), md.reason,
                    (unsigned long long)md.age_ms, (unsigned)t.flags);
            fflush(stderr);
            cur_mode = md.mode;
        }
        int fresh = (md.mode != MODE_NOSIGNAL && md.mode != MODE_STALE);
        int next_remote = (t.flags & MCPE_TF_REMOTE_WORLD) != 0;
        if (fresh && (!map_source_known || next_remote != remote_world)) {
            remote_world = next_remote;
            map_source_known = 1;
            tiles_invalidate_all();
            map_source_write(remote_world ? "remote" : "local");
            fprintf(stderr, "bottomd: map source -> %s\n",
                    remote_world ? "remote (terrain unavailable)" :
                                   "local LevelDB");
            fflush(stderr);
        }

        /* Auto-release ITEMS once the player is clearly back in the
         * world. Without this the mirror keeps running long after you
         * close the inventory — there is no "container closed" signal to
         * key off on 1.16.221.01 — which is what made it feel broken. A
         * container pins the player in place, so sustained movement means
         * the menu is gone. Deliberately requires ~1 s of movement:
         * being shoved by a mob while the inventory is open, or a single
         * stick twitch, must not trip it.
         *
         * SKIPPED while MCPE_TF_CONTAINER_OPEN is set: where the game
         * does report a container (any version but 1.16.221.01), that
         * flag is authoritative and movement means nothing. The
         * heuristic is a fallback for when we are flying blind, not a
         * second opinion that can override a real signal. */
#ifndef BOTTOMD_STABLE_RELEASE
        if (fresh && autorelease_frames > 0 &&
            !(t.flags & MCPE_TF_CONTAINER_OPEN)) {
            float dx = t.cam_x - last_cx, dz = t.cam_z - last_cz;
            float dyaw = fabsf(t.yaw_deg - last_yaw);
            if (dyaw > 180.0f) dyaw = 360.0f - dyaw;
            int moving = (dx * dx + dz * dz) > 0.04f || dyaw > 2.0f;
            move_frames = moving ? move_frames + 1 : 0;
            last_cx = t.cam_x;
            last_cz = t.cam_z;
            last_yaw = t.yaw_deg;
            if (move_frames >= autorelease_frames) {
                pages_auto_release();
                move_frames = 0;
            }
        }
#endif

        /* view follows the player until the user pans */
        if (g_follow && fresh) {
            g_view_x = t.cam_x;
            g_view_z = t.cam_z;
        }
        waypoints_poll();
        worldinfo_poll();

        /* SELECT swaps which panel shows the game (user's design,
         * 2026-07-27). Replaces the whole "detect the inventory" problem
         * with a button: put whatever you want to touch on the bottom. */
        if (gamepad_flip_pressed()) {
#ifndef BOTTOMD_STABLE_RELEASE
            touchfwd_release_all(); /* never flip with a finger held */
            /* Create uinput before screenflip asks Sway to map it.  Device
             * enumeration is asynchronous, so screenflip_refresh_touch()
             * keeps retrying after the first best-effort map. */
            if (!screenflip_game_is_bottom())
                touchfwd_available();
#endif
            screenflip_toggle();
#ifdef BOTTOMD_STABLE_RELEASE
            /* Follow the UI, not a fixed output. Closing first releases the
             * previous panel immediately, so the game never loses both touch
             * devices during a swap. */
            paneltouch_close(&pt_map);
            const char *map_panel = screenflip_game_is_bottom()
                                      ? panel_top : panel_bottom;
            if (paneltouch_open(&pt_map, map_panel) != 0)
                fprintf(stderr, "bottomd: swapped map-panel raw touch unavailable; using Wayland fallback\n");
#else
            /* INPUT has to follow the display. The game listens to the
             * TOP panel unconditionally (weston reads event1 raw), so
             * once it is rendering on the bottom we must take both
             * panels over ourselves: grab them so nothing else sees
             * them, feed the bottom one to the game, drop the top one.
             * Without the grab the top panel still drives the camera AND
             * gets forwarded again — that is the "spazm". */
            if (screenflip_game_is_bottom()) {
                if (!paneltouch_is_open(&pt_bottom) &&
                    paneltouch_open(&pt_bottom, panel_bottom) != 0)
                    fprintf(stderr, "bottomd: FLIP without bottom-panel "
                                    "touch — game will not be touchable\n");
                if (paneltouch_open(&pt_top, panel_top) != 0)
                    fprintf(stderr, "bottomd: FLIP without top-panel "
                                    "touch — map will not be touchable\n");
            } else {
                paneltouch_close(&pt_top);
                if (!paneltouch_is_open(&pt_bottom) &&
                    paneltouch_open(&pt_bottom, panel_bottom) != 0)
                    fprintf(stderr, "bottomd: bottom-panel raw touch unavailable after reset; using Wayland fallback\n");
            }
#endif
        }

        /* ---- touch dispatch ------------------------------------- *
         * Tab strip is checked FIRST and consumes the gesture; only
         * then does the event reach the active page's handler. Pages
         * other than MAP have no gestures yet, so their handler is the
         * empty default — but the dispatch point exists, so adding one
         * does not mean touching the map code (P13). */
        /* ---- touch sources -> owners -----------------------------
         * Exactly one owner per panel, decided by what is DISPLAYED on
         * it. Flipped, we grabbed both panels so sway delivers nothing
         * and we route explicitly; unflipped, sway hands us the bottom
         * panel as usual and the game reads the top one itself. */
        TouchEvent ev[16];
        int nev = 0;
#ifdef BOTTOMD_STABLE_RELEASE
        if (paneltouch_is_open(&pt_map))
            nev = paneltouch_poll(&pt_map, ev, 16);
        else
            nev = be->poll_touch ? be->poll_touch(be, ev, 16) : 0;
#else
        if (screenflip_game_is_bottom() &&
            paneltouch_is_open(&pt_bottom)) {
            /* Bottom panel is showing the GAME: everything goes there,
             * with NO tab hit-testing. (The tab strip lives on the left
             * edge of OUR ui — hit-testing it here is what made pressing
             * the bottom-left corner change the map's tab instead of
             * reaching the game.) */
            TouchEvent gev[16];
            int ng = paneltouch_poll(&pt_bottom, gev, 16);
            for (int i = 0; i < ng; ++i) {
                if (gev[i].type == TOUCH_DOWN)
                    touchfwd_down(0, gev[i].x, gev[i].y);
                else if (gev[i].type == TOUCH_MOTION)
                    touchfwd_move(0, gev[i].x, gev[i].y);
                else if (gev[i].type == TOUCH_UP)
                    touchfwd_up(0);
            }
            /* Top panel is showing OUR ui, so it drives the UI below. */
            if (paneltouch_is_open(&pt_top))
                nev = paneltouch_poll(&pt_top, ev, 16);
            else
                nev = be->poll_touch ? be->poll_touch(be, ev, 16) : 0;
        } else if (paneltouch_is_open(&pt_bottom)) {
            /* Normal layout: companion is physically below the game. */
            nev = paneltouch_poll(&pt_bottom, ev, 16);
        } else {
            nev = be->poll_touch ? be->poll_touch(be, ev, 16) : 0;
        }
#endif
        for (int i = 0; i < nev; ++i) {
            /* A gesture that STARTED on the tab strip belongs to it for
             * its whole life, so a sloppy tap that drifts down cannot
             * also pan the map. */
            if (ev[i].type == TOUCH_DOWN && !tch_active &&
                pages_hit_tab(ev[i].x, ev[i].y) >= 0) {
                tch_active = 1;
                tch_id = ev[i].id;
                tch_tab = 1;
                tch_moved = 0;
                tch_x0 = tch_x = ev[i].x;
                tch_y0 = tch_y = ev[i].y;
                continue;
            }
            if (tch_active && tch_tab) {
                if (ev[i].type == TOUCH_UP &&
                    (ev[i].id == tch_id || ev[i].id == -1)) {
                    int hit = pages_hit_tab(tch_x0, tch_y0);
                    /* only fires if the release is still on that tab */
                    if (hit >= 0 && hit == pages_hit_tab(tch_x, tch_y))
                        pages_set((Page)hit);
                    tch_active = 0;
                    tch_tab = 0;
                } else if (ev[i].type == TOUCH_MOTION &&
                           ev[i].id == tch_id) {
                    tch_x = ev[i].x;
                    tch_y = ev[i].y;
                }
                continue;
            }

            /* Independent Chat, Items, Input and Settings own ordinary tap
             * gestures; none of them forward pixels or touches to Bedrock. */
            if (pages_active() != PAGE_HUD) {
                if (ev[i].type == TOUCH_DOWN && !tch_active) {
                    tch_active = 1;
                    tch_id = ev[i].id;
                    tch_moved = 0;
                    tch_x0 = tch_x = ev[i].x;
                    tch_y0 = tch_y = ev[i].y;
                } else if (ev[i].type == TOUCH_MOTION && tch_active &&
                           ev[i].id == tch_id) {
                    tch_x = ev[i].x;
                    tch_y = ev[i].y;
                    if (abs(tch_x - tch_x0) > 8 || abs(tch_y - tch_y0) > 8)
                        tch_moved = 1;
                } else if (ev[i].type == TOUCH_UP && tch_active &&
                           (ev[i].id == tch_id || ev[i].id == -1)) {
                    if (!tch_moved) handle_page_tap(tch_x0, tch_y0);
                    tch_active = 0;
                }
                continue;
            }

            if (ev[i].type == TOUCH_DOWN && !tch_active) {
                tch_active = 1;
                tch_id = ev[i].id;
                tch_moved = 0;
                tch_x0 = tch_x = ev[i].x;
                tch_y0 = tch_y = ev[i].y;
                tch_view0x = g_view_x;
                tch_view0z = g_view_z;
                /* grab on the vertical slider — generous hit box: the
                 * whole right column above the centre button counts, so
                 * you never have to aim at a 14px track with a thumb */
                tch_slider = tch_x0 >= SLD_X - 12 && tch_x0 < VIEW_X1 &&
                             tch_y0 >= SLD_Y0 - 24 &&
                             tch_y0 < SLD_Y1 + 24;
                if (tch_slider) zoom_from_slider_y(tch_y0);
            } else if (ev[i].type == TOUCH_MOTION && tch_active &&
                       ev[i].id == tch_id) {
                tch_x = ev[i].x;
                tch_y = ev[i].y;
                if (tch_slider) {
                    zoom_from_slider_y(tch_y);
                    continue;
                }
                int dx = tch_x - tch_x0, dy = tch_y - tch_y0;
                if (!tch_moved && (abs(dx) > 8 || abs(dy) > 8))
                    tch_moved = 1;
                if (tch_moved) {
                    g_follow = 0;
                    g_view_x = tch_view0x - (float)dx / g_zoom;
                    g_view_z = tch_view0z - (float)dy / g_zoom;
                }
            } else if (ev[i].type == TOUCH_UP && tch_active &&
                       (ev[i].id == tch_id || ev[i].id == -1)) {
                if (!tch_moved && !tch_slider) { /* tap */
                    if (tch_x0 >= BTN_X - 8 && tch_x0 < BTN_X + BTN_W + 8 &&
                        tch_y0 >= BTN_Y - 8 && tch_y0 < BTN_Y + BTN_H + 8) {
                        g_follow = 1; /* re-center on player */
                        fprintf(stderr, "bottomd: map centered on player\n");
                    } else if (!remote_world && in_view(tch_x0, tch_y0)) {
                        /* toggle waypoint at tap position */
                        float wwx, wwz;
                        screen_to_world(g_zoom, tch_x0, tch_y0, &wwx, &wwz);
                        int hit = -1;
                        for (int w = 0; w < g_nwp; ++w) {
                            float ddx = (g_wp[w].x - wwx) * g_zoom;
                            float ddz = (g_wp[w].z - wwz) * g_zoom;
                            if (ddx * ddx + ddz * ddz < 14.0f * 14.0f) {
                                hit = w;
                                break;
                            }
                        }
                        if (hit >= 0) {
                            g_wp[hit] = g_wp[--g_nwp];
                        } else if (g_nwp < 64) {
                            g_wp[g_nwp].x = wwx;
                            g_wp[g_nwp].z = wwz;
                            g_nwp++;
                        }
                        waypoints_save();
                    }
                }
                if (tch_slider)
                    fprintf(stderr, "bottomd: map zoom %.2f px/block\n", g_zoom);
                tch_active = 0;
                tch_slider = 0;
            }
        }

        switch (cur_mode) {
        case MODE_NOSIGNAL:
            render_nosignal(&canvas, (frame / fps) & 1);
            draw_status_stack(&canvas, &t, md.age_ms);
            pages_draw_tabs(&canvas);
            break;
#ifndef BOTTOMD_STABLE_RELEASE
        case MODE_MIRROR:
            /* Legacy enum value retained for log compatibility; the
             * independent renderer never resolves to this mode. */
            render_page(&canvas, &t, g_zoom, md.age_ms, remote_world);
            pages_draw_tabs(&canvas);
            break;
        case MODE_BLANK:
            render_blank(&canvas);
            break;
#endif
        case MODE_STALE:
            render_page(&canvas, &t, g_zoom, md.age_ms, remote_world);
            render_stale_overlay(&canvas, md.age_ms, (frame / fps) & 1);
            pages_draw_tabs(&canvas); /* after the dim, so tabs stay lit */
            break;
        case MODE_PAGE:
        default:
            render_page(&canvas, &t, g_zoom, md.age_ms, remote_world);
            pages_draw_tabs(&canvas);
            break;
        }
        be->present(be, pixels);
        tiles_tick();
        frame++;
        usleep(1000000 / fps);
    }

    map_source_write("unknown");
    screenflip_reset();
#ifdef BOTTOMD_STABLE_RELEASE
    paneltouch_close(&pt_map);
#else
    paneltouch_close(&pt_bottom);
    paneltouch_close(&pt_top);
#endif
#ifndef BOTTOMD_STABLE_RELEASE
    touchfwd_shutdown();
#endif
    if (g_inventory_context_command)
        keyfwd_toggle_inventory();
    keyfwd_shutdown();
    companion_close();
    texture_close();
    be->shutdown(be);
    return 0;
}
