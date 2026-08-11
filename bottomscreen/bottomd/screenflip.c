#define _GNU_SOURCE
#include "screenflip.h"

#include <stdarg.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char g_top[64] = "";
static char g_bottom[64] = "";
static char g_inject_touch[96] = "19779:20549:mcpe-rgds-touchinject";
static int g_game_bottom = 0;
static int g_enabled = 0;
static int g_touch_mapped = 0;

/* app_id of the game window under sway. The port's window reports
 * app_id "mcpelauncher-client" (title "Crusty SDL2 Backend"). */
#define GAME_APP "mcpelauncher-client"
#define MAP_APP  "bottomd"

static int sway(const char *fmt, ...)
{
    char cmd[512], full[640];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(cmd, sizeof cmd, fmt, ap);
    va_end(ap);
    /* bottomd normally ignores SIGCHLD so the detached OSK launcher cannot
     * leave zombies.  system(3) consequently executes swaymsg successfully
     * but reports ECHILD, which used to make every successful flip look like
     * a failure and caused endless touch-map retries.  Restore the default
     * disposition only for this synchronous child, then put the reaper policy
     * back exactly as it was. */
    snprintf(full, sizeof full, "swaymsg '%s' >/dev/null 2>&1", cmd);
    struct sigaction old_child, default_child;
    memset(&default_child, 0, sizeof default_child);
    default_child.sa_handler = SIG_DFL;
    sigemptyset(&default_child.sa_mask);
    sigaction(SIGCHLD, NULL, &old_child);
    sigaction(SIGCHLD, &default_child, NULL);
    int result = system(full);
    sigaction(SIGCHLD, &old_child, NULL);
    if (result != 0) {
        /* Best-effort: a failed flip leaves the windows where they were,
         * which is survivable. Never abort the frame loop over it. */
        fprintf(stderr, "bottomd: swaymsg failed: %s\n", cmd);
        return 0;
    }
    return 1;
}

void screenflip_refresh_touch(void)
{
    /* The virtual device is lazy and is only used while the physical bottom
     * panel is displaying the game.  In the normal layout Bedrock consumes
     * the top panel directly, so retrying a virtual-device map there merely
     * spams Sway before uinput has ever been created. */
    if (!g_enabled || !g_game_bottom || g_touch_mapped) return;
    const char *output = g_bottom;
    if (sway("input %s map_to_output %s", g_inject_touch, output)) {
        g_touch_mapped = 1;
        fprintf(stderr, "bottomd: virtual touch mapped to %s\n", output);
    }
}

void screenflip_init(void)
{
    const char *t = getenv("BOTTOMD_TOP_OUTPUT");
    const char *b = getenv("BOTTOMD_BOTTOM_OUTPUT");
    const char *inject = getenv("BOTTOMD_INJECT_TOUCH_ID");
    if (t && t[0]) snprintf(g_top, sizeof g_top, "%s", t);
    if (b && b[0]) snprintf(g_bottom, sizeof g_bottom, "%s", b);
    if (inject && inject[0])
        snprintf(g_inject_touch, sizeof g_inject_touch, "%s", inject);
    g_enabled = g_top[0] && g_bottom[0] && strcmp(g_top, g_bottom) != 0;
    g_game_bottom = 0;
    g_touch_mapped = 0;
    fprintf(stderr, "bottomd: screenflip %s top=%s bottom=%s\n",
            g_enabled ? "enabled" : "disabled", g_top, g_bottom);
    /* The injector is lazy: while the game is on the top panel its physical
     * touchscreen goes straight to the game and bottomd reads the other
     * panel itself.  Mapping here used to race a uinput device that did not
     * exist yet and then spam swaymsg forever.  The flip path creates the
     * injector first and the frame-loop retry maps it once Sway enumerates
     * the new device. */
}

int screenflip_game_is_bottom(void) { return g_game_bottom; }

void screenflip_toggle(void)
{
    if (!g_enabled) return;
    g_game_bottom = !g_game_bottom;
    const char *game_out = g_game_bottom ? g_bottom : g_top;
    const char *map_out = g_game_bottom ? g_top : g_bottom;
    /* Input mapping is a separate IPC command. Older ROCKNIX/Sway accepts the
     * bare identifier but may reject an input command embedded in a compound
     * criteria transaction. A mapping failure must not cancel the window
     * swap. */
    g_touch_mapped = sway("input %s map_to_output %s", g_inject_touch,
                          game_out);
    sway("[app_id=\"%s\"] move container to output %s, fullscreen enable; "
         "[app_id=\"%s\"] move container to output %s, fullscreen enable; "
         "[app_id=\"%s\"] focus",
         MAP_APP, map_out, GAME_APP, game_out, GAME_APP);
    fprintf(stderr, "bottomd: FLIP — game on %s, map on %s\n", game_out,
            map_out);
    fflush(stderr);
}

void screenflip_reset(void)
{
    if (!g_enabled || !g_game_bottom) return;
    g_game_bottom = 0;
    g_touch_mapped = sway("input %s map_to_output %s", g_inject_touch, g_top);
    sway("[app_id=\"%s\"] move container to output %s, fullscreen enable; "
         "[app_id=\"%s\"] move container to output %s, fullscreen enable; "
         "[app_id=\"%s\"] focus",
         MAP_APP, g_bottom, GAME_APP, g_top, GAME_APP);
    fprintf(stderr, "bottomd: screenflip reset (game back on %s)\n", g_top);
    fflush(stderr);
}
