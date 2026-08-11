#include <assert.h>
#include <stddef.h>

static void *fake_window = (void *)0x11;
static void *fake_context = (void *)0x22;
static void *bound_window;
static void *bound_context;

void *test_next_create_window(const char *t, int x, int y, int w, int h,
                              unsigned int f) {
    (void)t; (void)x; (void)y; (void)w; (void)h; (void)f;
    return fake_window;
}
void *test_next_create_context(void *window) {
    assert(window == fake_window);
    return fake_context;
}
int test_next_make_current(void *window, void *context) {
    bound_window = window; bound_context = context; return 0;
}

#define dlsym test_dlsym
void *test_dlsym(void *handle, const char *name);
#include "crusty_context_v1.c"
#undef dlsym
#include <string.h>
void *test_dlsym(void *handle, const char *name) {
    (void)handle;
    if (!strcmp(name, "_SDL_CreateWindow")) return test_next_create_window;
    if (!strcmp(name, "_SDL_GL_CreateContext")) return test_next_create_context;
    if (!strcmp(name, "_SDL_GL_MakeCurrent")) return test_next_make_current;
    return NULL;
}
int main(void) {
    assert(crusty_gamewindow_context_v1(1, 1) == -2);
    assert(_SDL_CreateWindow("test", 0, 0, 1, 1, 0) == fake_window);
    assert(_SDL_GL_CreateContext(fake_window) == fake_context);
    assert(crusty_gamewindow_context_v1(2, 1) == -1);
    assert(crusty_gamewindow_context_v1(1, 1) == 0);
    assert(bound_window == fake_window && bound_context == fake_context);
    assert(crusty_gamewindow_context_v1(1, 0) == 0);
    assert(bound_window == fake_window && bound_context == NULL);
    return 0;
}
