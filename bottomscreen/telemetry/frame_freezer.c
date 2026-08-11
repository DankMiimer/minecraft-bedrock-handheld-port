/* GPU-only top-screen frame cache.  The independent lower inventory needs a
 * short-lived native Bedrock inventory context for server validation.  While
 * that context is active, restore the latest gameplay framebuffer so its UI
 * never appears on top.  No Mojang pixels are persisted or sent anywhere. */
#include "frame_freezer.h"

#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <stdio.h>

typedef void (*GetIntegervFn)(GLenum, GLint *);
typedef void (*ActiveTextureFn)(GLenum);
typedef void (*GenTexturesFn)(GLsizei, GLuint *);
typedef void (*BindTextureFn)(GLenum, GLuint);
typedef void (*TexParameteriFn)(GLenum, GLenum, GLint);
typedef void (*TexImage2DFn)(GLenum, GLint, GLint, GLsizei, GLsizei, GLint,
                             GLenum, GLenum, const void *);
typedef void (*CopyTexSubImage2DFn)(GLenum, GLint, GLint, GLint, GLint, GLint,
                                    GLsizei, GLsizei);
typedef void (*GenFramebuffersFn)(GLsizei, GLuint *);
typedef void (*BindFramebufferFn)(GLenum, GLuint);
typedef void (*FramebufferTexture2DFn)(GLenum, GLenum, GLenum, GLuint, GLint);
typedef GLenum (*CheckFramebufferStatusFn)(GLenum);
typedef void (*BlitFramebufferFn)(GLint, GLint, GLint, GLint, GLint, GLint,
                                  GLint, GLint, GLbitfield, GLenum);

static GetIntegervFn p_get_integer;
static ActiveTextureFn p_active_texture;
static GenTexturesFn p_gen_textures;
static BindTextureFn p_bind_texture;
static TexParameteriFn p_tex_parameter;
static TexImage2DFn p_tex_image;
static CopyTexSubImage2DFn p_copy_texture;
static GenFramebuffersFn p_gen_framebuffers;
static BindFramebufferFn p_bind_framebuffer;
static FramebufferTexture2DFn p_framebuffer_texture;
static CheckFramebufferStatusFn p_check_framebuffer;
static BlitFramebufferFn p_blit;
static GLuint g_texture;
static GLuint g_framebuffer;
static int g_width;
static int g_height;
static int g_loaded;
static int g_ready;
static int g_logged_error;
static int g_logged_capture;
static int g_logged_restore;

static void *load_proc(const char *name)
{
    return (void *)eglGetProcAddress(name);
}

static int load_functions(void)
{
    if (g_loaded) return g_loaded > 0;
    p_get_integer = (GetIntegervFn)load_proc("glGetIntegerv");
    p_active_texture = (ActiveTextureFn)load_proc("glActiveTexture");
    p_gen_textures = (GenTexturesFn)load_proc("glGenTextures");
    p_bind_texture = (BindTextureFn)load_proc("glBindTexture");
    p_tex_parameter = (TexParameteriFn)load_proc("glTexParameteri");
    p_tex_image = (TexImage2DFn)load_proc("glTexImage2D");
    p_copy_texture = (CopyTexSubImage2DFn)load_proc("glCopyTexSubImage2D");
    p_gen_framebuffers =
        (GenFramebuffersFn)load_proc("glGenFramebuffers");
    p_bind_framebuffer =
        (BindFramebufferFn)load_proc("glBindFramebuffer");
    p_framebuffer_texture =
        (FramebufferTexture2DFn)load_proc("glFramebufferTexture2D");
    p_check_framebuffer =
        (CheckFramebufferStatusFn)load_proc("glCheckFramebufferStatus");
    p_blit = (BlitFramebufferFn)load_proc("glBlitFramebuffer");
    g_loaded = p_get_integer && p_active_texture && p_gen_textures &&
               p_bind_texture && p_tex_parameter && p_tex_image &&
               p_copy_texture && p_gen_framebuffers && p_bind_framebuffer &&
               p_framebuffer_texture && p_check_framebuffer && p_blit ? 1 : -1;
    return g_loaded > 0;
}

static void restore_bindings(GLint active_texture, GLint texture,
                             GLint read_framebuffer, GLint draw_framebuffer)
{
    p_bind_framebuffer(GL_READ_FRAMEBUFFER, (GLuint)read_framebuffer);
    p_bind_framebuffer(GL_DRAW_FRAMEBUFFER, (GLuint)draw_framebuffer);
    p_active_texture((GLenum)active_texture);
    p_bind_texture(GL_TEXTURE_2D, (GLuint)texture);
}

static int ensure_cache(int width, int height, GLint active_texture,
                        GLint texture, GLint read_framebuffer,
                        GLint draw_framebuffer)
{
    if (!g_texture) p_gen_textures(1, &g_texture);
    if (!g_framebuffer) p_gen_framebuffers(1, &g_framebuffer);
    if (!g_texture || !g_framebuffer) return 0;

    p_active_texture(GL_TEXTURE0);
    p_bind_texture(GL_TEXTURE_2D, g_texture);
    if (width != g_width || height != g_height) {
        p_tex_parameter(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        p_tex_parameter(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        p_tex_parameter(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        p_tex_parameter(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        p_tex_image(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA,
                    GL_UNSIGNED_BYTE, NULL);
        g_width = width;
        g_height = height;
        g_ready = 0;
    }
    p_bind_framebuffer(GL_FRAMEBUFFER, g_framebuffer);
    p_framebuffer_texture(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                          g_texture, 0);
    int complete = p_check_framebuffer(GL_FRAMEBUFFER) ==
                   GL_FRAMEBUFFER_COMPLETE;
    restore_bindings(active_texture, texture, read_framebuffer,
                     draw_framebuffer);
    return complete;
}

void mcpe_frame_freezer_apply(int action, int width, int height)
{
    if (!action || width <= 0 || height <= 0 || !load_functions()) return;

    GLint active_texture = GL_TEXTURE0;
    GLint texture = 0;
    GLint read_framebuffer = 0;
    GLint draw_framebuffer = 0;
    p_get_integer(GL_ACTIVE_TEXTURE, &active_texture);
    p_get_integer(GL_TEXTURE_BINDING_2D, &texture);
    p_get_integer(GL_READ_FRAMEBUFFER_BINDING, &read_framebuffer);
    p_get_integer(GL_DRAW_FRAMEBUFFER_BINDING, &draw_framebuffer);

    if (!ensure_cache(width, height, active_texture, texture,
                      read_framebuffer, draw_framebuffer)) {
        if (!g_logged_error) {
            fprintf(stderr, "mcpe-frame-freezer: framebuffer guard failed\n");
            g_logged_error = 1;
        }
        return;
    }

    if (action == 1) {
        p_active_texture(GL_TEXTURE0);
        p_bind_texture(GL_TEXTURE_2D, g_texture);
        p_bind_framebuffer(GL_READ_FRAMEBUFFER, (GLuint)read_framebuffer);
        p_copy_texture(GL_TEXTURE_2D, 0, 0, 0, 0, 0, width, height);
        g_ready = 1;
        if (!g_logged_capture) {
            fprintf(stderr,
                    "mcpe-frame-freezer: gameplay cache ready %dx%d read-fbo=%d draw-fbo=%d\n",
                    width, height, read_framebuffer, draw_framebuffer);
            g_logged_capture = 1;
        }
    } else if (action == 2 && g_ready) {
        p_bind_framebuffer(GL_READ_FRAMEBUFFER, g_framebuffer);
        /* EGLUTWindow::swapBuffers presents the host window's default
         * framebuffer. Bedrock may leave a private render FBO bound while a
         * screen transition is active, so restoring to `draw_framebuffer`
         * writes somewhere that is never presented. Always replace FBO 0,
         * then restore Bedrock's bindings below. */
        p_bind_framebuffer(GL_DRAW_FRAMEBUFFER, 0);
        p_blit(0, 0, width, height, 0, 0, width, height,
               GL_COLOR_BUFFER_BIT, GL_NEAREST);
        if (!g_logged_restore) {
            fprintf(stderr,
                    "mcpe-frame-freezer: native inventory concealed with gameplay cache previous-draw-fbo=%d target-fbo=0\n",
                    draw_framebuffer);
            g_logged_restore = 1;
        }
    }
    restore_bindings(active_texture, texture, read_framebuffer,
                     draw_framebuffer);
}
