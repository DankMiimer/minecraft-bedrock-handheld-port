#define _GNU_SOURCE
#include "touchfwd.h"
#include "draw.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define TF_SLOTS 4

static int g_fd = -1;
static int g_state = 0; /* 0 retry, 1 ready, -1 last attempt failed */
static int g_down[TF_SLOTS];
static int g_tracking[TF_SLOTS];
static int g_next_tracking = 1;
static char g_device[256];

static int configure_device(int fd)
{
    if (ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_DIRECT) != 0 ||
        ioctl(fd, UI_SET_EVBIT, EV_SYN) != 0 ||
        ioctl(fd, UI_SET_EVBIT, EV_KEY) != 0 ||
        ioctl(fd, UI_SET_KEYBIT, BTN_TOUCH) != 0 ||
        ioctl(fd, UI_SET_EVBIT, EV_ABS) != 0 ||
        ioctl(fd, UI_SET_ABSBIT, ABS_X) != 0 ||
        ioctl(fd, UI_SET_ABSBIT, ABS_Y) != 0 ||
        ioctl(fd, UI_SET_ABSBIT, ABS_MT_SLOT) != 0 ||
        ioctl(fd, UI_SET_ABSBIT, ABS_MT_TRACKING_ID) != 0 ||
        ioctl(fd, UI_SET_ABSBIT, ABS_MT_POSITION_X) != 0 ||
        ioctl(fd, UI_SET_ABSBIT, ABS_MT_POSITION_Y) != 0)
        return -1;

    /* The legacy uinput_user_dev setup works on old ROCKNIX kernels as well
     * as current ones. Sway's stable identifier becomes
     * 19779:20549:mcpe-rgds-touchinject (vendor/product are decimal). */
    struct uinput_user_dev setup;
    memset(&setup, 0, sizeof setup);
    snprintf(setup.name, sizeof setup.name, "mcpe-rgds-touchinject");
    setup.id.bustype = BUS_VIRTUAL;
    setup.id.vendor = 0x4d43;
    setup.id.product = 0x5045;
    setup.id.version = 1;
    setup.absmin[ABS_X] = setup.absmin[ABS_Y] = 0;
    setup.absmax[ABS_X] = setup.absmax[ABS_MT_POSITION_X] = BOTTOMD_W - 1;
    setup.absmax[ABS_Y] = setup.absmax[ABS_MT_POSITION_Y] = BOTTOMD_H - 1;
    setup.absmin[ABS_MT_SLOT] = 0;
    setup.absmax[ABS_MT_SLOT] = TF_SLOTS - 1;
    setup.absmin[ABS_MT_TRACKING_ID] = 0;
    setup.absmax[ABS_MT_TRACKING_ID] = 65535;
    if (write(fd, &setup, sizeof setup) != (ssize_t)sizeof setup ||
        ioctl(fd, UI_DEV_CREATE) != 0)
        return -1;
    return 0;
}

void touchfwd_init(void)
{
    const char *path = getenv("BOTTOMD_UINPUT");
    snprintf(g_device, sizeof g_device, "%s",
             path && path[0] ? path : "/dev/uinput");
    memset(g_down, 0, sizeof g_down);
    memset(g_tracking, 0, sizeof g_tracking);
    g_state = 0;
}

static int ensure_open(void)
{
    if (g_fd >= 0) return 1;
    int fd = open(g_device, O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0 || configure_device(fd) != 0) {
        int saved = errno;
        if (fd >= 0) close(fd);
        if (g_state != -1)
            fprintf(stderr, "bottomd: virtual touch unavailable at %s (%s)\n",
                    g_device, strerror(saved));
        g_state = -1;
        return 0;
    }
    g_fd = fd;
    g_state = 1;
    fprintf(stderr, "bottomd: virtual touch ready via %s\n", g_device);
    return 1;
}

static int emit_event(unsigned short type, unsigned short code, int value)
{
    struct input_event event;
    memset(&event, 0, sizeof event);
    event.type = type;
    event.code = code;
    event.value = value;
    ssize_t wrote = write(g_fd, &event, sizeof event);
    if (wrote == (ssize_t)sizeof event) return 1;
    if (errno != EAGAIN && errno != EINTR)
        fprintf(stderr, "bottomd: virtual touch write failed (%s)\n",
                strerror(errno));
    return 0;
}

static void sync_frame(void)
{
    emit_event(EV_SYN, SYN_REPORT, 0);
}

int touchfwd_available(void)
{
    return ensure_open();
}

void touchfwd_down(int slot, int x, int y)
{
    if (slot < 0 || slot >= TF_SLOTS || !ensure_open()) return;
    if (g_down[slot]) touchfwd_up(slot);
    int tracking = g_next_tracking++ & 65535;
    if (tracking == 0) tracking = g_next_tracking++ & 65535;
    g_tracking[slot] = tracking;
    g_down[slot] = 1;
    emit_event(EV_ABS, ABS_MT_SLOT, slot);
    emit_event(EV_ABS, ABS_MT_TRACKING_ID, tracking);
    emit_event(EV_ABS, ABS_MT_POSITION_X, x);
    emit_event(EV_ABS, ABS_MT_POSITION_Y, y);
    emit_event(EV_ABS, ABS_X, x);
    emit_event(EV_ABS, ABS_Y, y);
    emit_event(EV_KEY, BTN_TOUCH, 1);
    sync_frame();
}

void touchfwd_move(int slot, int x, int y)
{
    if (slot < 0 || slot >= TF_SLOTS || !g_down[slot] || !ensure_open())
        return;
    emit_event(EV_ABS, ABS_MT_SLOT, slot);
    emit_event(EV_ABS, ABS_MT_POSITION_X, x);
    emit_event(EV_ABS, ABS_MT_POSITION_Y, y);
    emit_event(EV_ABS, ABS_X, x);
    emit_event(EV_ABS, ABS_Y, y);
    sync_frame();
}

void touchfwd_up(int slot)
{
    if (slot < 0 || slot >= TF_SLOTS || !g_down[slot]) return;
    g_down[slot] = 0;
    if (!ensure_open()) return;
    emit_event(EV_ABS, ABS_MT_SLOT, slot);
    emit_event(EV_ABS, ABS_MT_TRACKING_ID, -1);
    int any_down = 0;
    for (int i = 0; i < TF_SLOTS; ++i) any_down |= g_down[i];
    if (!any_down) emit_event(EV_KEY, BTN_TOUCH, 0);
    sync_frame();
}

void touchfwd_release_all(void)
{
    for (int i = 0; i < TF_SLOTS; ++i)
        if (g_down[i]) touchfwd_up(i);
}

void touchfwd_shutdown(void)
{
    touchfwd_release_all();
    if (g_fd >= 0) {
        ioctl(g_fd, UI_DEV_DESTROY);
        close(g_fd);
        g_fd = -1;
    }
    g_state = 0;
}
