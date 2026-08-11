/*
 * backend.h — display backend abstraction for bottomd.
 * All rendering is software into an XRGB8888 buffer; a backend only
 * initializes a target and presents the buffer. Selected at runtime:
 *   --backend ppm    frames to PPM files (headless dev/testing)
 *   --backend fbdev  /dev/fb1 (or $BOTTOMD_FB) — device path
 *   --backend wayland  wl_shm client under sway (RG DS)
 */
#ifndef BOTTOMD_BACKEND_H
#define BOTTOMD_BACKEND_H

#include <stdint.h>

#define BOTTOMD_W 640
#define BOTTOMD_H 480

typedef enum { TOUCH_DOWN, TOUCH_MOTION, TOUCH_UP } TouchType;

typedef struct {
    TouchType type;
    int id;      /* touch point id */
    int x, y;    /* surface-local pixels */
} TouchEvent;

typedef struct Backend {
    const char *name;
    /* returns 0 on success */
    int  (*init)(struct Backend *self);
    /* pixels: BOTTOMD_W * BOTTOMD_H XRGB8888 */
    void (*present)(struct Backend *self, const uint32_t *pixels);
    void (*shutdown)(struct Backend *self);
    /* optional: drain queued touch events, returns count (0 if none).
     * NULL when the backend has no input (ppm, fbdev). */
    int  (*poll_touch)(struct Backend *self, TouchEvent *out, int max);
    void *priv;
} Backend;

Backend *backend_ppm_create(const char *out_dir);
Backend *backend_fbdev_create(void); /* $BOTTOMD_FB, default /dev/fb1 */
#ifdef BOTTOMD_HAVE_WAYLAND
Backend *backend_wayland_create(void);
#endif

#endif
