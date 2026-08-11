#define _GNU_SOURCE
#include "paneltouch.h"

#include <fcntl.h>
#include <linux/input.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

struct ev64 {
    long long sec, usec;
    unsigned short type, code;
    int value;
};

static int get_abs(int fd, int code, int *min, int *max)
{
    struct input_absinfo ai;
    if (ioctl(fd, EVIOCGABS(code), &ai) != 0) return 0;
    if (ai.maximum <= ai.minimum) return 0;
    *min = ai.minimum;
    *max = ai.maximum;
    return 1;
}

int paneltouch_open(PanelTouch *p, const char *devnode)
{
    if (p->fd > 0) return 0;
    memset(p, 0, sizeof *p);
    p->fd = open(devnode, O_RDONLY | O_NONBLOCK);
    if (p->fd <= 0) {
        p->fd = 0;
        fprintf(stderr, "bottomd: paneltouch open %s failed\n", devnode);
        return -1;
    }
    snprintf(p->name, sizeof p->name, "%s", devnode);
    /* Ranges differ per panel and per firmware — never assume 0..639. */
    if (!get_abs(p->fd, ABS_MT_POSITION_X, &p->min_x, &p->max_x) &&
        !get_abs(p->fd, ABS_X, &p->min_x, &p->max_x)) {
        p->min_x = 0;
        p->max_x = BOTTOMD_W - 1;
    }
    if (!get_abs(p->fd, ABS_MT_POSITION_Y, &p->min_y, &p->max_y) &&
        !get_abs(p->fd, ABS_Y, &p->min_y, &p->max_y)) {
        p->min_y = 0;
        p->max_y = BOTTOMD_H - 1;
    }
    /* EVIOCGRAB is the point of the exercise: it stops weston and sway
     * both seeing this panel, which is what removes the double input. */
    if (ioctl(p->fd, EVIOCGRAB, 1) != 0) {
        fprintf(stderr, "bottomd: paneltouch GRAB %s failed (in use?)\n",
                devnode);
        close(p->fd);
        p->fd = 0;
        return -1;
    }
    /* Drop whatever the panel buffered before we grabbed it. Without
     * this the first gesture after a flip replays stale fragments —
     * typically a DOWN with no matching motion, which is exactly the
     * "first swap only registers taps, not swipes" the user hit. */
    struct ev64 junk[64];
    while (read(p->fd, junk, sizeof junk) > 0) { }

    fprintf(stderr, "bottomd: paneltouch grabbed %s x[%d..%d] y[%d..%d]\n",
            devnode, p->min_x, p->max_x, p->min_y, p->max_y);
    return 0;
}

void paneltouch_close(PanelTouch *p)
{
    if (p->fd <= 0) return;
    ioctl(p->fd, EVIOCGRAB, 0);
    close(p->fd);
    fprintf(stderr, "bottomd: paneltouch released %s\n", p->name);
    memset(p, 0, sizeof *p);
}

int paneltouch_is_open(const PanelTouch *p) { return p->fd > 0; }

static int scale(int v, int lo, int hi, int out)
{
    if (hi <= lo) return 0;
    if (v < lo) v = lo;
    if (v > hi) v = hi;
    long long r = (long long)(v - lo) * (out - 1) / (hi - lo);
    return (int)r;
}

int paneltouch_poll(PanelTouch *p, TouchEvent *out, int max)
{
    if (p->fd <= 0 || max <= 0) return 0;
    int n = 0;
    struct ev64 buf[64];

    for (;;) {
        ssize_t got = read(p->fd, buf, sizeof buf);
        if (got <= 0) break;
        size_t cnt = (size_t)got / sizeof buf[0];
        for (size_t i = 0; i < cnt && n < max; ++i) {
            struct ev64 *e = &buf[i];
            if (e->type == EV_ABS) {
                switch (e->code) {
                case ABS_MT_SLOT:
                    p->slot = e->value;
                    break;
                case ABS_MT_TRACKING_ID:
                    if (p->slot != 0) break;
                    if (e->value >= 0) p->pending_down = 1;
                    else               p->pending_up = 1;
                    break;
                case ABS_MT_POSITION_X:
                case ABS_X:
                    if (p->slot == 0) {
                        p->x = scale(e->value, p->min_x, p->max_x,
                                     BOTTOMD_W);
                        p->moved = 1;
                    }
                    break;
                case ABS_MT_POSITION_Y:
                case ABS_Y:
                    if (p->slot == 0) {
                        p->y = scale(e->value, p->min_y, p->max_y,
                                     BOTTOMD_H);
                        p->moved = 1;
                    }
                    break;
                default: break;
                }
            } else if (e->type == EV_KEY && e->code == BTN_TOUCH) {
                if (e->value) p->pending_down = 1;
                else          p->pending_up = 1;
            } else if (e->type == EV_SYN && e->code == SYN_REPORT) {
                if (p->pending_down && !p->down) {
                    p->down = 1;
                    out[n].type = TOUCH_DOWN;
                    out[n].id = 0;
                    out[n].x = p->x;
                    out[n].y = p->y;
                    n++;
                } else if (p->moved && p->down && n < max) {
                    out[n].type = TOUCH_MOTION;
                    out[n].id = 0;
                    out[n].x = p->x;
                    out[n].y = p->y;
                    n++;
                }
                if (p->pending_up && p->down && n < max) {
                    p->down = 0;
                    out[n].type = TOUCH_UP;
                    out[n].id = 0;
                    out[n].x = p->x;
                    out[n].y = p->y;
                    n++;
                }
                p->pending_down = p->pending_up = p->moved = 0;
            }
        }
        if (n >= max) break;
    }
    return n;
}
