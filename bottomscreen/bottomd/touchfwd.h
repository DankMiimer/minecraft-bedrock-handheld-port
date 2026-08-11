/* touchfwd.h — forward bottom-panel touches into the game.
 *
 * The mirror shows the game on the bottom panel, but the panel's real
 * touches belong to bottomd. While the mirror is up we replay them through
 * an in-process uinput virtual touchscreen which Sway maps to the output that
 * currently contains the game.
 *
 * Coordinates pass through unchanged: the game window is 640x480, the
 * same as the panel, so panel (x,y) IS game (x,y).
 *
 * Everything here is best-effort and silent on failure. If the injector
 * is not running, touches simply do nothing — they must never become an
 * error path that disturbs the map.
 */
#ifndef BOTTOMD_TOUCHFWD_H
#define BOTTOMD_TOUCHFWD_H

/* $BOTTOMD_UINPUT (default /dev/uinput). Lazily opened. */
void touchfwd_init(void);

/* 1 if forwarding is possible (fifo present and writable). */
int touchfwd_available(void);

void touchfwd_down(int slot, int x, int y);
void touchfwd_move(int slot, int x, int y);
void touchfwd_up(int slot);

/* Lift anything still held — call when leaving the mirror so a touch
 * cannot be left stuck down in the game. */
void touchfwd_release_all(void);
void touchfwd_shutdown(void);

#endif
