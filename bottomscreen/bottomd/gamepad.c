#define _GNU_SOURCE
#include "gamepad.h"

#include <fcntl.h>
#include <linux/input.h>
#include <dirent.h>
#include <sys/ioctl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* struct input_event on 64-bit: timeval(2x s64) + type u16 + code u16 +
 * value s32 = 24 bytes. */
struct ev64 {
    long long sec, usec;
    unsigned short type, code;
    int value;
};

#define BTN_SELECT_CODE 314 /* verified present on retrogame_joypad */

static int g_fd = -1;
static int g_btn = BTN_SELECT_CODE;
static int g_down = 0;
static int g_edge = 0;

static int supports_select(const char *path)
{
    int fd = open(path, O_RDONLY | O_NONBLOCK);
    if (fd < 0) return 0;
    unsigned long keys[(KEY_MAX + 8 * sizeof(unsigned long)) /
                       (8 * sizeof(unsigned long))];
    memset(keys, 0, sizeof keys);
    int ok = ioctl(fd, EVIOCGBIT(EV_KEY, sizeof keys), keys) >= 0;
    int bit = ok && (keys[BTN_SELECT / (8 * sizeof(unsigned long))] &
                     (1UL << (BTN_SELECT % (8 * sizeof(unsigned long)))));
    close(fd);
    return bit;
}

static const char *discover_gamepad(void)
{
    static char path[128];
    DIR *dir = opendir("/dev/input");
    if (!dir) return NULL;
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (strncmp(entry->d_name, "event", 5) != 0) continue;
        if (strlen(entry->d_name) > 32) continue;
        snprintf(path, sizeof path, "/dev/input/%s", entry->d_name);
        if (supports_select(path)) { closedir(dir); return path; }
    }
    closedir(dir);
    return NULL;
}

void gamepad_init(void)
{
    const char *p = getenv("BOTTOMD_JOYPAD");
    if (!p || !p[0]) p = discover_gamepad();
    const char *b = getenv("BOTTOMD_FLIP_BTN");
    if (b && b[0]) {
        int v = atoi(b);
        if (v > 0) g_btn = v;
    }
    g_fd = p ? open(p, O_RDONLY | O_NONBLOCK) : -1;
    if (g_fd < 0) {
        fprintf(stderr, "bottomd: screen-flip button disabled (%s)\n",
                p ? p : "no gamepad with BTN_SELECT found");
        return;
    }
    fprintf(stderr, "bottomd: screen-flip on button %d via %s\n", g_btn, p);
}

int gamepad_flip_pressed(void)
{
    if (g_fd < 0) return 0;
    struct ev64 buf[64];
    for (;;) {
        ssize_t n = read(g_fd, buf, sizeof buf);
        if (n <= 0) break;
        size_t cnt = (size_t)n / sizeof buf[0];
        for (size_t i = 0; i < cnt; ++i) {
            if (buf[i].type != EV_KEY || buf[i].code != g_btn) continue;
            if (buf[i].value && !g_down) g_edge = 1; /* press edge only */
            g_down = buf[i].value ? 1 : 0;
        }
    }
    if (g_edge) {
        g_edge = 0;
        return 1;
    }
    return 0;
}
