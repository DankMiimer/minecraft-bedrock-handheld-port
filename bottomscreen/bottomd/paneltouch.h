/* paneltouch.h — read a touch panel straight off evdev.
 *
 * WHY (2026-07-27, after the SELECT flip shipped): bottomd normally gets
 * touch from sway, on whatever OUTPUT its window sits on. That breaks
 * the moment the flip moves it:
 *
 *   the game's touch comes from event1 — the TOP panel — ALWAYS, because
 *   the nested weston reads raw evdev and westonfix hides event2 from it.
 *   Confirmed by the udev calibration matrices: event1 has no x-offset
 *   (top half of the 1280x480 layout), event2 has 0.5 (bottom half).
 *
 * So after a flip the DISPLAY swaps but the INPUT does not. Fix: while
 * flipped, bottomd grabs BOTH panels (EVIOCGRAB, so neither weston nor
 * sway sees them) and routes them explicitly by what is ON each panel:
 *
 *   bottom panel -> the game, via touchfwd's uinput virtual touchscreen
 *   top panel    -> bottomd's own UI (map, tabs, zoom)
 *
 * Two independent instances, because both are live at once and each
 * carries its own slot/position state.
 */
#ifndef BOTTOMD_PANELTOUCH_H
#define BOTTOMD_PANELTOUCH_H

#include "backend.h"  /* TouchEvent */

typedef struct {
    int fd;
    int min_x, max_x, min_y, max_y;
    int x, y;
    int down, pending_down, pending_up, moved;
    int slot;             /* persists across polls — the panel only
                             re-sends ABS_MT_SLOT when it changes */
    char name[64];
} PanelTouch;

/* Open + EVIOCGRAB. 0 on success. Safe to call when already open. */
int  paneltouch_open(PanelTouch *p, const char *devnode);
void paneltouch_close(PanelTouch *p);
int  paneltouch_is_open(const PanelTouch *p);

/* Drain pending events into `out` (slot 0 only — one finger is all the
 * inventory and the map need). Returns how many were written. */
int  paneltouch_poll(PanelTouch *p, TouchEvent *out, int max);

#endif
