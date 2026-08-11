#define _GNU_SOURCE
#include "keyfwd.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static int g_fd = -1;
static int g_attempted;
static char g_device[256];

static int emit_event(unsigned short type, unsigned short code, int value)
{
    struct input_event event;
    memset(&event, 0, sizeof event);
    event.type = type;
    event.code = code;
    event.value = value;
    return write(g_fd, &event, sizeof event) == (ssize_t)sizeof event;
}

static int configure_device(int fd)
{
    if (ioctl(fd, UI_SET_EVBIT, EV_SYN) != 0 ||
        ioctl(fd, UI_SET_EVBIT, EV_KEY) != 0 ||
        ioctl(fd, UI_SET_KEYBIT, KEY_E) != 0)
        return 0;

    struct uinput_user_dev setup;
    memset(&setup, 0, sizeof setup);
    snprintf(setup.name, sizeof setup.name, "mcpe-rgds-keyinject");
    setup.id.bustype = BUS_VIRTUAL;
    setup.id.vendor = 0x4d43;
    setup.id.product = 0x4b45;
    setup.id.version = 1;
    return write(fd, &setup, sizeof setup) == (ssize_t)sizeof setup &&
           ioctl(fd, UI_DEV_CREATE) == 0;
}

static int ensure_open(void)
{
    if (g_fd >= 0) return 1;
    int fd = open(g_device, O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0 || !configure_device(fd)) {
        int saved = errno;
        if (fd >= 0) close(fd);
        if (!g_attempted)
            fprintf(stderr,
                    "bottomd: native inventory key injector unavailable at %s (%s)\n",
                    g_device, strerror(saved));
        g_attempted = 1;
        return 0;
    }
    g_fd = fd;
    g_attempted = 1;
    fprintf(stderr, "bottomd: native inventory key injector ready via %s\n",
            g_device);
    return 1;
}

void keyfwd_init(void)
{
    const char *path = getenv("BOTTOMD_UINPUT");
    snprintf(g_device, sizeof g_device, "%s",
             path && path[0] ? path : "/dev/uinput");
    g_attempted = 0;
    ensure_open();
}

int keyfwd_available(void)
{
    return ensure_open();
}

int keyfwd_toggle_inventory(void)
{
    if (!ensure_open()) return 0;
    if (!emit_event(EV_KEY, KEY_E, 1) ||
        !emit_event(EV_SYN, SYN_REPORT, 0))
        return 0;
    usleep(30000);
    if (!emit_event(EV_KEY, KEY_E, 0) ||
        !emit_event(EV_SYN, SYN_REPORT, 0))
        return 0;
    return 1;
}

void keyfwd_shutdown(void)
{
    if (g_fd >= 0) {
        ioctl(g_fd, UI_DEV_DESTROY);
        close(g_fd);
        g_fd = -1;
    }
    g_attempted = 0;
}
