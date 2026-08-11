/* pages.h — AYN-Thor-style bottom navigation for the RGDS companion.
 *
 * The reference UI keeps vital information at the top, the selected tool in
 * the middle, and a row of equal Minecraft-style buttons along the bottom.
 * RGDS uses the same shell, but its data sources are native Bedrock telemetry,
 * LevelDB snapshots and (for screens Bedrock does not expose structurally) the
 * existing readback mirror.
 */
#ifndef BOTTOMD_PAGES_H
#define BOTTOMD_PAGES_H

#include "draw.h"

typedef enum {
    PAGE_HUD = 0,
    PAGE_CHAT,
    PAGE_ITEMS,
    PAGE_INPUT,
    PAGE_SETTINGS,
    PAGE_COUNT
} Page;

/* 640x480 RGDS layout. The status stack is persistent on every page except
 * ITEMS, which needs the full panel for the native Bedrock screen mirror. */
#define STATUS_H       82
#define TAB_STRIP_H    46
#define CONTENT_Y0     STATUS_H
#define CONTENT_Y1     (BOTTOMD_H - TAB_STRIP_H)

/* The HUD tab presents the terrain on a square paper sheet. */
#define MAP_SIZE       326
#define VIEW_X0        ((BOTTOMD_W - MAP_SIZE) / 2)
#define VIEW_X1        (VIEW_X0 + MAP_SIZE)
#define VIEW_Y0        (CONTENT_Y0 + ((CONTENT_Y1 - CONTENT_Y0 - MAP_SIZE) / 2))
#define VIEW_Y1        (VIEW_Y0 + MAP_SIZE)
#define VIEW_CX        ((VIEW_X0 + VIEW_X1) / 2)
#define VIEW_CY        ((VIEW_Y0 + VIEW_Y1) / 2)

/* Compatibility aliases used by the stale overlay and older tests. */
#define STRIP_H        TAB_STRIP_H
#define TABS_H         TAB_STRIP_H

const char *page_name(Page page);
void pages_init(int dev_enabled);
Page pages_active(void);
int pages_count(void);

/* A deliberate tab selection cancels automatic Items restoration. */
void pages_set(Page page);

/* Enable/disable the open-container takeover used by the Settings page. */
void pages_set_auto_items(int enabled);
int pages_auto_items(void);

/* Edge-triggered open-screen state. Rising edge selects Items and remembers
 * the previous tab; falling edge restores it unless the user chose a tab. */
void pages_container(int open);
void pages_auto_release(void);

/* Bottom-strip hit test and rendering. */
int pages_hit_tab(int x, int y);
void pages_draw_tabs(Canvas *canvas);

#endif
