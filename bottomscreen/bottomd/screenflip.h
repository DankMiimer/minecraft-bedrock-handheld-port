/* screenflip.h — swap which physical panel shows the game.
 *
 * THE IDEA (user, 2026-07-27): instead of mirroring the game onto the
 * bottom panel, just MOVE the game window there and put the map on top.
 * Press SELECT to swap back. Your hands are already on the controller,
 * so the bottom screen is the one your thumbs can reach — whatever you
 * want to touch should be the thing that is down there.
 *
 * Why this is better than the mirror it replaces:
 *   - no glReadPixels at all, so no capture cost and no frame-rate hit;
 *   - the game is at native resolution, not a downscaled copy;
 *   - crucially, it needs NO "is the inventory open?" signal. That
 *     detection is impossible on 1.16.221.01 (no ScreenController
 *     exports for the player inventory, and lockCursor is never called)
 *     and every workaround for it has been a source of jank. The player
 *     decides, with a button.
 *
 * Touch still has to be routed: the game reads the TOP panel through the
 * nested weston, while bottomd owns the bottom panel through sway. So
 * when the game is displayed on the bottom, bottomd forwards the bottom
 * panel's touches into the game via touchfwd's uinput virtual touchscreen.
 */
#ifndef BOTTOMD_SCREENFLIP_H
#define BOTTOMD_SCREENFLIP_H

/* $BOTTOMD_TOP_OUTPUT / $BOTTOMD_BOTTOM_OUTPUT (default DSI-2 / DSI-1).
 * Reads the current arrangement as "normal" (game top, map bottom). */
void screenflip_init(void);

/* Retry the virtual touchscreen mapping after Sway has had time to enumerate
 * the freshly created uinput device. Safe and cheap to call periodically. */
void screenflip_refresh_touch(void);

/* 1 when the GAME currently occupies the bottom panel. */
int screenflip_game_is_bottom(void);

/* Swap the two windows between outputs. Best-effort; logs what it did. */
void screenflip_toggle(void);

/* Put the game back on top. Call on shutdown so the next launch — and
 * EmulationStation — start from the normal arrangement. */
void screenflip_reset(void);

#endif
