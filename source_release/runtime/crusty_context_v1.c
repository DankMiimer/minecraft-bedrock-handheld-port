#define _GNU_SOURCE
#include <dlfcn.h>
#include <stddef.h>
#include <stdint.h>

typedef void *(*create_window_fn)(const char *, int, int, int, int, unsigned int);
typedef void *(*create_context_fn)(void *);
typedef int (*make_current_fn)(void *, void *);

static void *recorded_window;
static void *recorded_context;

void *_SDL_CreateWindow(const char *title, int x, int y, int w, int h,
                        unsigned int flags) {
    static create_window_fn next;
    if (!next)
        next = (create_window_fn)dlsym(RTLD_NEXT, "_SDL_CreateWindow");
    if (!next)
        return NULL;
    recorded_window = next(title, x, y, w, h, flags);
    return recorded_window;
}

void *_SDL_GL_CreateContext(void *window) {
    static create_context_fn next;
    if (!next)
        next = (create_context_fn)dlsym(RTLD_NEXT, "_SDL_GL_CreateContext");
    if (!next)
        return NULL;
    recorded_context = next(window);
    if (window)
        recorded_window = window;
    return recorded_context;
}

__attribute__((visibility("default")))
int crusty_gamewindow_context_v1(unsigned int api_version, int active) {
    static make_current_fn next;
    if (api_version != 1U)
        return -1;
    if (!recorded_window || (active && !recorded_context))
        return -2;
    if (!next)
        next = (make_current_fn)dlsym(RTLD_NEXT, "_SDL_GL_MakeCurrent");
    if (!next)
        return -3;
    return next(recorded_window, active ? recorded_context : NULL);
}
