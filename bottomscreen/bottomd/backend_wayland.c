/*
 * Wayland backend — wl_shm software surface for RG DS under sway.
 *
 * The surface advertises app_id "bottomd" by default. Pin it to the bottom
 * panel with sway, for example:
 *   for_window [app_id="bottomd"] move container to output DSI-1, fullscreen enable
 */
#define _GNU_SOURCE
#include "backend.h"

#include "xdg-shell-client-protocol.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <wayland-client.h>

#ifndef MFD_CLOEXEC
#define MFD_CLOEXEC 0x0001U
#endif

#define NUM_BUFS 2

typedef struct {
    struct wl_buffer *wlbuf;
    void *data;
    size_t size;
    int busy;
} WlBuf;

#define TQ_LEN 64
/* Bind EVERY advertised seat, not just one: ROCKNIX/ES shuffles the
 * touchscreens between sway seats (ES attaches them to "seat1"), so
 * touch may arrive on any seat. Events for our surface are merged
 * into the one ring regardless of which seat delivered them. */
#define MAX_SEATS 4

typedef struct WaylandPriv WaylandPriv;

typedef struct {
    struct wl_seat *seat;
    struct wl_touch *touch;
    WaylandPriv *owner;
} SeatSlot;

struct WaylandPriv {
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_compositor *compositor;
    struct wl_shm *shm;
    struct xdg_wm_base *wm_base;
    struct wl_surface *surface;
    struct xdg_surface *xdg_surface;
    struct xdg_toplevel *toplevel;
    SeatSlot seats[MAX_SEATS];
    int nseats;
    int have_xrgb;
    int configured;
    int closed;
    WlBuf bufs[NUM_BUFS];
    /* touch event ring */
    TouchEvent tq[TQ_LEN];
    int tq_head, tq_tail;
};

static void tq_push(WaylandPriv *p, TouchType type, int id, int x, int y)
{
    int next = (p->tq_head + 1) % TQ_LEN;
    if (next == p->tq_tail)
        return; /* full: drop oldest-priority-less event */
    p->tq[p->tq_head] = (TouchEvent){ type, id, x, y };
    p->tq_head = next;
}

static void pump_events(WaylandPriv *p)
{
    while (wl_display_prepare_read(p->display) != 0)
        wl_display_dispatch_pending(p->display);

    wl_display_flush(p->display);
    struct pollfd fds = {
        .fd = wl_display_get_fd(p->display),
        .events = POLLIN,
        .revents = 0,
    };
    int r = poll(&fds, 1, 0);
    if (r > 0 && (fds.revents & POLLIN)) {
        if (wl_display_read_events(p->display) < 0)
            p->closed = 1;
    } else {
        wl_display_cancel_read(p->display);
        if (r > 0 && (fds.revents & (POLLERR | POLLHUP | POLLNVAL)))
            p->closed = 1;
    }
    wl_display_dispatch_pending(p->display);
}

static int create_shm_fd(size_t size)
{
#ifdef SYS_memfd_create
    int fd = (int)syscall(SYS_memfd_create, "bottomd-wayland", MFD_CLOEXEC);
    if (fd >= 0) {
        if (ftruncate(fd, (off_t)size) == 0)
            return fd;
        close(fd);
    }
#endif

    const char *runtime = getenv("XDG_RUNTIME_DIR");
    if (!runtime || !runtime[0])
        runtime = "/tmp";
    char path[512];
    snprintf(path, sizeof path, "%s/bottomd-shm-XXXXXX", runtime);
    int tmp_fd = mkstemp(path);
    if (tmp_fd < 0)
        return -1;
    unlink(path);
    if (ftruncate(tmp_fd, (off_t)size) != 0) {
        close(tmp_fd);
        return -1;
    }
    return tmp_fd;
}

static void wlbuf_release(void *data, struct wl_buffer *buffer)
{
    (void)buffer;
    ((WlBuf *)data)->busy = 0;
}

static const struct wl_buffer_listener wlbuf_listener = {
    .release = wlbuf_release,
};

static int create_buffer(WaylandPriv *p, WlBuf *b)
{
    const int stride = BOTTOMD_W * 4;
    b->size = (size_t)stride * BOTTOMD_H;
    int fd = create_shm_fd(b->size);
    if (fd < 0) {
        fprintf(stderr, "bottomd: wayland shm fd failed: %s\n",
                strerror(errno));
        return -1;
    }

    b->data = mmap(NULL, b->size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (b->data == MAP_FAILED) {
        fprintf(stderr, "bottomd: wayland mmap failed: %s\n",
                strerror(errno));
        close(fd);
        return -1;
    }

    struct wl_shm_pool *pool = wl_shm_create_pool(p->shm, fd, (int)b->size);
    close(fd);
    if (!pool) {
        munmap(b->data, b->size);
        b->data = NULL;
        return -1;
    }
    b->wlbuf = wl_shm_pool_create_buffer(pool, 0, BOTTOMD_W, BOTTOMD_H,
                                         stride, WL_SHM_FORMAT_XRGB8888);
    wl_shm_pool_destroy(pool);
    if (!b->wlbuf) {
        munmap(b->data, b->size);
        b->data = NULL;
        return -1;
    }
    wl_buffer_add_listener(b->wlbuf, &wlbuf_listener, b);
    return 0;
}

static void shm_format(void *data, struct wl_shm *shm, uint32_t format)
{
    (void)shm;
    WaylandPriv *p = data;
    if (format == WL_SHM_FORMAT_XRGB8888)
        p->have_xrgb = 1;
}

static const struct wl_shm_listener shm_listener = {
    .format = shm_format,
};

static void wm_ping(void *data, struct xdg_wm_base *wm_base,
                    uint32_t serial)
{
    (void)data;
    xdg_wm_base_pong(wm_base, serial);
}

static const struct xdg_wm_base_listener wm_listener = {
    .ping = wm_ping,
};

static void xdg_surface_configure(void *data, struct xdg_surface *surface,
                                  uint32_t serial)
{
    WaylandPriv *p = data;
    xdg_surface_ack_configure(surface, serial);
    p->configured = 1;
}

static const struct xdg_surface_listener xdg_surface_listener = {
    .configure = xdg_surface_configure,
};

static void toplevel_configure(void *data, struct xdg_toplevel *toplevel,
                               int32_t width, int32_t height,
                               struct wl_array *states)
{
    (void)data;
    (void)toplevel;
    (void)width;
    (void)height;
    (void)states;
}

static void toplevel_close(void *data, struct xdg_toplevel *toplevel)
{
    (void)toplevel;
    ((WaylandPriv *)data)->closed = 1;
}

static const struct xdg_toplevel_listener toplevel_listener = {
    .configure = toplevel_configure,
    .close = toplevel_close,
};

/* ---- touch ---------------------------------------------------------- */
static void touch_down(void *data, struct wl_touch *t, uint32_t serial,
                       uint32_t time, struct wl_surface *surface,
                       int32_t id, wl_fixed_t x, wl_fixed_t y)
{
    (void)t; (void)serial; (void)time; (void)surface;
    tq_push(data, TOUCH_DOWN, (int)id, wl_fixed_to_int(x),
            wl_fixed_to_int(y));
}
static void touch_up(void *data, struct wl_touch *t, uint32_t serial,
                     uint32_t time, int32_t id)
{
    (void)t; (void)serial; (void)time;
    tq_push(data, TOUCH_UP, (int)id, -1, -1);
}
static void touch_motion(void *data, struct wl_touch *t, uint32_t time,
                         int32_t id, wl_fixed_t x, wl_fixed_t y)
{
    (void)t; (void)time;
    tq_push(data, TOUCH_MOTION, (int)id, wl_fixed_to_int(x),
            wl_fixed_to_int(y));
}
static void touch_frame(void *data, struct wl_touch *t)
{
    (void)data; (void)t;
}
static void touch_cancel(void *data, struct wl_touch *t)
{
    (void)t;
    /* treat as lift of all points */
    tq_push(data, TOUCH_UP, -1, -1, -1);
}
static void touch_shape(void *data, struct wl_touch *t, int32_t id,
                        wl_fixed_t major, wl_fixed_t minor)
{
    (void)data; (void)t; (void)id; (void)major; (void)minor;
}
static void touch_orientation(void *data, struct wl_touch *t, int32_t id,
                              wl_fixed_t o)
{
    (void)data; (void)t; (void)id; (void)o;
}
static const struct wl_touch_listener touch_listener = {
    .down = touch_down,
    .up = touch_up,
    .motion = touch_motion,
    .frame = touch_frame,
    .cancel = touch_cancel,
    .shape = touch_shape,
    .orientation = touch_orientation,
};

static void seat_capabilities(void *data, struct wl_seat *seat,
                              uint32_t caps)
{
    SeatSlot *s = data;
    if ((caps & WL_SEAT_CAPABILITY_TOUCH) && !s->touch) {
        s->touch = wl_seat_get_touch(seat);
        wl_touch_add_listener(s->touch, &touch_listener, s->owner);
    } else if (!(caps & WL_SEAT_CAPABILITY_TOUCH) && s->touch) {
        wl_touch_destroy(s->touch);
        s->touch = NULL;
    }
}
static void seat_name(void *data, struct wl_seat *seat, const char *name)
{
    (void)data; (void)seat; (void)name;
}
static const struct wl_seat_listener seat_listener = {
    .capabilities = seat_capabilities,
    .name = seat_name,
};

static void registry_global(void *data, struct wl_registry *registry,
                            uint32_t name, const char *interface,
                            uint32_t version)
{
    WaylandPriv *p = data;
    if (!strcmp(interface, wl_seat_interface.name)) {
        if (p->nseats >= MAX_SEATS) return;
        SeatSlot *s = &p->seats[p->nseats++];
        s->owner = p;
        uint32_t v = version < 5 ? version : 5;
        s->seat = wl_registry_bind(registry, name, &wl_seat_interface, v);
        wl_seat_add_listener(s->seat, &seat_listener, s);
    } else if (!strcmp(interface, wl_compositor_interface.name)) {
        uint32_t v = version < 4 ? version : 4;
        p->compositor = wl_registry_bind(registry, name,
                                         &wl_compositor_interface, v);
    } else if (!strcmp(interface, wl_shm_interface.name)) {
        p->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
        wl_shm_add_listener(p->shm, &shm_listener, p);
    } else if (!strcmp(interface, xdg_wm_base_interface.name)) {
        p->wm_base = wl_registry_bind(registry, name,
                                      &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(p->wm_base, &wm_listener, p);
    }
}

static void registry_remove(void *data, struct wl_registry *registry,
                            uint32_t name)
{
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_remove,
};

static int wayland_init(Backend *self)
{
    WaylandPriv *p = self->priv;
    p->display = wl_display_connect(NULL);
    if (!p->display) {
        fprintf(stderr, "bottomd: wl_display_connect failed\n");
        return -1;
    }

    p->registry = wl_display_get_registry(p->display);
    wl_registry_add_listener(p->registry, &registry_listener, p);
    wl_display_roundtrip(p->display);
    wl_display_roundtrip(p->display); /* receive wl_shm formats */

    if (!p->compositor || !p->shm || !p->wm_base) {
        fprintf(stderr, "bottomd: wayland missing globals "
                "(compositor=%p shm=%p xdg_wm_base=%p)\n",
                (void *)p->compositor, (void *)p->shm, (void *)p->wm_base);
        return -1;
    }
    if (!p->have_xrgb) {
        fprintf(stderr, "bottomd: compositor lacks WL_SHM_FORMAT_XRGB8888\n");
        return -1;
    }

    for (int i = 0; i < NUM_BUFS; ++i)
        if (create_buffer(p, &p->bufs[i]) != 0)
            return -1;

    p->surface = wl_compositor_create_surface(p->compositor);
    p->xdg_surface = xdg_wm_base_get_xdg_surface(p->wm_base, p->surface);
    xdg_surface_add_listener(p->xdg_surface, &xdg_surface_listener, p);
    p->toplevel = xdg_surface_get_toplevel(p->xdg_surface);
    xdg_toplevel_add_listener(p->toplevel, &toplevel_listener, p);

    const char *app_id = getenv("BOTTOMD_APP_ID");
    if (!app_id || !app_id[0])
        app_id = "bottomd";
    xdg_toplevel_set_app_id(p->toplevel, app_id);
    xdg_toplevel_set_title(p->toplevel, "bottomd");
    const char *fullscreen = getenv("BOTTOMD_WAYLAND_FULLSCREEN");
    if (!fullscreen || fullscreen[0] != '0')
        xdg_toplevel_set_fullscreen(p->toplevel, NULL);
    wl_surface_commit(p->surface);

    while (!p->configured && wl_display_dispatch(p->display) != -1) {}
    if (!p->configured) {
        fprintf(stderr, "bottomd: wayland surface was not configured\n");
        return -1;
    }

    fprintf(stderr, "bottomd: wayland wl_shm %dx%d app_id=%s\n",
            BOTTOMD_W, BOTTOMD_H, app_id);
    return 0;
}

static WlBuf *next_buffer(WaylandPriv *p)
{
    for (int i = 0; i < NUM_BUFS; ++i)
        if (!p->bufs[i].busy)
            return &p->bufs[i];
    pump_events(p);
    for (int i = 0; i < NUM_BUFS; ++i)
        if (!p->bufs[i].busy)
            return &p->bufs[i];
    return NULL;
}

static void wayland_present(Backend *self, const uint32_t *pixels)
{
    WaylandPriv *p = self->priv;
    if (p->closed)
        return;
    pump_events(p);
    WlBuf *b = next_buffer(p);
    if (!b)
        return; /* compositor has not released either buffer; drop frame */

    memcpy(b->data, pixels, b->size);
    wl_surface_attach(p->surface, b->wlbuf, 0, 0);
    wl_surface_damage(p->surface, 0, 0, BOTTOMD_W, BOTTOMD_H);
    wl_surface_commit(p->surface);
    b->busy = 1;
    pump_events(p);
}

static int wayland_poll_touch(Backend *self, TouchEvent *out, int max)
{
    WaylandPriv *p = self->priv;
    pump_events(p);
    int n = 0;
    while (n < max && p->tq_tail != p->tq_head) {
        out[n++] = p->tq[p->tq_tail];
        p->tq_tail = (p->tq_tail + 1) % TQ_LEN;
    }
    return n;
}

static void wayland_shutdown(Backend *self)
{
    WaylandPriv *p = self->priv;
    for (int i = 0; i < p->nseats; ++i) {
        if (p->seats[i].touch) wl_touch_destroy(p->seats[i].touch);
        if (p->seats[i].seat) wl_seat_destroy(p->seats[i].seat);
    }
    for (int i = 0; i < NUM_BUFS; ++i) {
        if (p->bufs[i].wlbuf)
            wl_buffer_destroy(p->bufs[i].wlbuf);
        if (p->bufs[i].data && p->bufs[i].data != MAP_FAILED)
            munmap(p->bufs[i].data, p->bufs[i].size);
    }
    if (p->toplevel) xdg_toplevel_destroy(p->toplevel);
    if (p->xdg_surface) xdg_surface_destroy(p->xdg_surface);
    if (p->surface) wl_surface_destroy(p->surface);
    if (p->wm_base) xdg_wm_base_destroy(p->wm_base);
    if (p->shm) wl_shm_destroy(p->shm);
    if (p->compositor) wl_compositor_destroy(p->compositor);
    if (p->registry) wl_registry_destroy(p->registry);
    if (p->display) wl_display_disconnect(p->display);
    free(p);
    free(self);
}

Backend *backend_wayland_create(void)
{
    Backend *b = calloc(1, sizeof *b);
    WaylandPriv *p = calloc(1, sizeof *p);
    if (!b || !p) { free(b); free(p); return NULL; }
    b->name = "wayland";
    b->init = wayland_init;
    b->present = wayland_present;
    b->shutdown = wayland_shutdown;
    b->poll_touch = wayland_poll_touch;
    b->priv = p;
    return b;
}
