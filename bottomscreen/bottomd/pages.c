#include "pages.h"

#include <stdio.h>

#define COL_STRIP       0xcc101010u
#define COL_BUTTON      0xff666666u
#define COL_BUTTON_TOP  0xffa0a0a0u
#define COL_BUTTON_EDGE 0xff292929u
#define COL_ACTIVE      0xff8a8a8au
#define COL_ACTIVE_TOP  0xffc6c6c6u
#define COL_TEXT        0xfff2f2f2u
#define COL_TEXT_SHADOW 0xff303030u

static Page g_page = PAGE_HUD;
static Page g_saved = PAGE_HUD;
static int g_auto = 0;
static int g_container = 0;
static int g_auto_items = 1;

const char *page_name(Page page)
{
    switch (page) {
    case PAGE_HUD:      return "HUD";
    case PAGE_CHAT:     return "CHAT";
    case PAGE_ITEMS:    return "ITEMS";
    case PAGE_INPUT:    return "INPUT";
    case PAGE_SETTINGS: return "SETTINGS";
    default:            return "?";
    }
}

void pages_init(int dev_enabled)
{
    (void)dev_enabled;
    g_page = g_saved = PAGE_HUD;
    g_auto = 0;
    g_container = 0;
    g_auto_items = 1;
}

Page pages_active(void) { return g_page; }
int pages_count(void) { return PAGE_COUNT; }

static void set_page(Page page, const char *reason)
{
    if ((int)page < 0 || page >= PAGE_COUNT || page == g_page) return;
    fprintf(stderr, "bottomd: page %s -> %s (%s)\n",
            page_name(g_page), page_name(page), reason);
    fflush(stderr);
    g_page = page;
}

void pages_set(Page page)
{
    set_page(page, "user tab");
    g_auto = 0;
}

void pages_set_auto_items(int enabled)
{
    g_auto_items = !!enabled;
    if (!g_auto_items) g_auto = 0;
}

int pages_auto_items(void) { return g_auto_items; }

void pages_container(int open)
{
    open = !!open;
    if (open && !g_container && g_auto_items) {
        g_saved = g_page;
        g_auto = 1;
        set_page(PAGE_ITEMS, "Bedrock screen opened");
    } else if (!open && g_container) {
        if (g_auto && g_page == PAGE_ITEMS)
            set_page(g_saved, "Bedrock screen closed, restoring");
        g_auto = 0;
    }
    g_container = open;
}

void pages_auto_release(void)
{
    if (g_page != PAGE_ITEMS) return;
    set_page(g_saved == PAGE_ITEMS ? PAGE_HUD : g_saved,
             "player moving, releasing Items");
    g_auto = 0;
}

int pages_hit_tab(int x, int y)
{
    if (x < 0 || x >= BOTTOMD_W || y < CONTENT_Y1 || y >= BOTTOMD_H)
        return -1;
    int width = BOTTOMD_W / PAGE_COUNT;
    int index = x / width;
    if (index >= PAGE_COUNT) index = PAGE_COUNT - 1;
    return index;
}

static void draw_button(Canvas *canvas, int x, int y, int width, int height,
                        const char *label, int active)
{
    uint32_t face = active ? COL_ACTIVE : COL_BUTTON;
    uint32_t top = active ? COL_ACTIVE_TOP : COL_BUTTON_TOP;
    draw_rect(canvas, x, y, width, height, COL_BUTTON_EDGE);
    draw_rect(canvas, x + 2, y + 2, width - 4, height - 4, face);
    draw_rect(canvas, x + 2, y + 2, width - 4, 2, top);
    draw_rect(canvas, x + 2, y + height - 4, width - 4, 2,
              active ? 0xff505050u : 0xff393939u);
    if (active)
        draw_rect(canvas, x + 5, y + height - 5, width - 10, 2,
                  0xff80c440u);

    int tw = draw_text_width(label, 1);
    int tx = x + (width - tw) / 2;
    int ty = y + (height - 7) / 2;
    draw_text(canvas, tx + 1, ty + 1, label, 1, COL_TEXT_SHADOW);
    draw_text(canvas, tx, ty, label, 1, COL_TEXT);
}

void pages_draw_tabs(Canvas *canvas)
{
    draw_rect(canvas, 0, CONTENT_Y1, BOTTOMD_W, TAB_STRIP_H, COL_STRIP);
    int gap = 3;
    int button_y = CONTENT_Y1 + 3;
    int button_h = TAB_STRIP_H - 6;
    int cell = BOTTOMD_W / PAGE_COUNT;
    for (int i = 0; i < PAGE_COUNT; ++i) {
        int x = i * cell + gap;
        int right = (i == PAGE_COUNT - 1) ? BOTTOMD_W : (i + 1) * cell;
        draw_button(canvas, x, button_y, right - x - gap, button_h,
                    page_name((Page)i), g_page == (Page)i);
    }
}
