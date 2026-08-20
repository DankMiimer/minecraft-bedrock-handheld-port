/*
 * Compatibility shim for PortMaster's headless XWayland on Knulli/H700.
 *
 * The server's Xlib extension list can expose GLX while xcb's GLX probe is
 * unavailable. Qt refuses to load its xcb_glx integration in that state,
 * before the Crusty/GL4ES frontend gets a chance to provide the context.
 * Report only the two initialization probes Qt 6.4 performs. All real GLX
 * entry points and rendering remain implemented by Crusty and GL4ES.
 */
#define _GNU_SOURCE

#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct xcb_connection_t xcb_connection_t;
typedef struct {
    const char *name;
    int global_id;
} xcb_extension_t;
typedef struct {
    uint8_t response_type;
    uint8_t pad0;
    uint16_t sequence;
    uint32_t length;
    uint8_t present;
    uint8_t major_opcode;
    uint8_t first_event;
    uint8_t first_error;
    uint8_t pad1[20];
} xcb_query_extension_reply_t;
typedef struct {
    unsigned int sequence;
} xcb_glx_query_version_cookie_t;
typedef struct {
    uint8_t response_type;
    uint8_t pad0;
    uint16_t sequence;
    uint32_t length;
    uint32_t major_version;
    uint32_t minor_version;
    uint8_t pad1[16];
} xcb_glx_query_version_reply_t;

static xcb_query_extension_reply_t fake_glx_extension = {
    .response_type = 1,
    .present = 1,
    .major_opcode = 0,
    .first_event = 0,
    .first_error = 0,
};

const xcb_query_extension_reply_t *
xcb_get_extension_data(xcb_connection_t *connection, xcb_extension_t *extension)
{
    typedef const xcb_query_extension_reply_t *(*real_fn)(
        xcb_connection_t *, xcb_extension_t *);
    static real_fn real_get_extension_data;

    if (extension && extension->name && strcmp(extension->name, "GLX") == 0)
        return &fake_glx_extension;

    if (!real_get_extension_data) {
        real_get_extension_data = (real_fn)dlsym(RTLD_NEXT, "xcb_get_extension_data");
        if (!real_get_extension_data) {
            fputs("qt-xcb-glx-compat: xcb_get_extension_data is unavailable\n", stderr);
            abort();
        }
    }
    return real_get_extension_data(connection, extension);
}

xcb_glx_query_version_cookie_t
xcb_glx_query_version(xcb_connection_t *connection, uint32_t major, uint32_t minor)
{
    (void)connection;
    (void)major;
    (void)minor;
    return (xcb_glx_query_version_cookie_t){ .sequence = 0 };
}

xcb_glx_query_version_reply_t *
xcb_glx_query_version_reply(xcb_connection_t *connection,
                            xcb_glx_query_version_cookie_t cookie,
                            void **protocol_error)
{
    (void)connection;
    (void)cookie;
    if (protocol_error)
        *protocol_error = NULL;

    xcb_glx_query_version_reply_t *reply = calloc(1, sizeof(*reply));
    if (!reply)
        return NULL;
    reply->response_type = 1;
    reply->major_version = 1;
    reply->minor_version = 4;
    return reply;
}

typedef void *(*get_proc_fn)(const unsigned char *);
static get_proc_fn crusty_get_proc;

static get_proc_fn get_crusty_proc(void)
{
    if (!crusty_get_proc)
        crusty_get_proc = (get_proc_fn)dlsym(
            RTLD_NEXT, "crusty_glXGetProcAddressARB");
    return crusty_get_proc;
}

/* The glxpass build shipped by PortMaster intentionally has no ELF constructor.
 * Crusty's resolver is the supported initialization entry point: it wires
 * GL4ES to SDL_GL_GetProcAddress before calling initialize_gl4es. Calling the
 * GL4ES initializer directly leaves every underlying GLES function null. */
static void ensure_gl4es_initialized(void)
{
    static int attempted;
    get_proc_fn resolver;

    if (attempted)
        return;
    attempted = 1;
    resolver = get_crusty_proc();
    if (!resolver) {
        fputs("qt-xcb-glx-compat: Crusty's GL resolver is unavailable\n", stderr);
        return;
    }
    (void)resolver((const unsigned char *)"glGetString");
}

/*
 * Qt asks the newly-created auxiliary WebEngine context for its version before
 * Crusty's dummy GLX context has been attached to GL4ES. These conservative
 * strings describe the GL4ES target selected by run.sh and prevent that early
 * probe from entering GL4ES; normal GL entry points still resolve to GL4ES.
 */
const unsigned char *glGetString(uint32_t name)
{
    ensure_gl4es_initialized();
    switch (name) {
    case 0x1f00: return (const unsigned char *)"ARM";                 /* GL_VENDOR */
    case 0x1f01: return (const unsigned char *)"Mali GL4ES";          /* GL_RENDERER */
    case 0x1f02: return (const unsigned char *)"2.1 gl4es wrapper";   /* GL_VERSION */
    case 0x1f03: return (const unsigned char *)"";                    /* GL_EXTENSIONS */
    case 0x8b8c: return (const unsigned char *)"1.20";                /* GLSL version */
    default: return NULL;
    }
}

/* Crusty 0.4's GLX frontend leaves glXMakeContextCurrent as a successful
 * no-op. Qt 6 uses it for its off-screen and Qt Quick contexts. Route it to
 * GL4ES's working glXMakeCurrent path so the requested context really becomes
 * current before Qt resolves GL functions. */
int glXMakeContextCurrent(void *display, unsigned long draw,
                          unsigned long read, void *context)
{
    typedef int (*make_current_fn)(void *, unsigned long, void *);
    static make_current_fn real_make_current;
    if (!real_make_current) {
        real_make_current = (make_current_fn)dlsym(RTLD_NEXT, "glXMakeCurrent");
        if (!real_make_current)
            return 0;
    }
    return real_make_current(display, draw ? draw : read, context);
}

static void *resolve_gl_proc(const unsigned char *name)
{
    get_proc_fn resolver;

    if (!name)
        return NULL;
    if (name && strcmp((const char *)name, "glGetString") == 0)
        return (void *)(uintptr_t)&glGetString;

    /* Call Crusty's real ARB resolver by its non-interposable internal name.
     * Its public glXGetProcAddress wrapper jumps through the interposable ARB
     * PLT entry, which returns to this shim and recurses. The internal resolver
     * calls GL4ES's gl4es_GetProcAddress directly, including extension symbols
     * that are not exported for dlsym and are required by Qt's QRhi endFrame. */
    resolver = get_crusty_proc();
    return resolver ? resolver(name) : NULL;
}

void *glXGetProcAddress(const unsigned char *name)
{
    return resolve_gl_proc(name);
}

void *glXGetProcAddressARB(const unsigned char *name)
{
    return resolve_gl_proc(name);
}
