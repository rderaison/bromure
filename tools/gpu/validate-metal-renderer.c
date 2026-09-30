// Trusted standalone dependency probe. No guest commands or app integration.
#include <epoxy/egl.h>
#include <epoxy/gl.h>
#include <virglrenderer.h>
#include <virgl_hw.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct renderer {
    EGLDisplay display;
    EGLConfig config;
    EGLContext root;
};

extern int probe_shared_texture(void *native_texture);
extern int probe_containment(const char *outside_file);

static virgl_renderer_gl_context create_context(void *cookie, int scanout,
                                               struct virgl_renderer_gl_ctx_param *param)
{
    (void)scanout;
    struct renderer *r = cookie;
    EGLint attrs[] = {EGL_CONTEXT_MAJOR_VERSION_KHR, param->major_ver,
                     EGL_CONTEXT_MINOR_VERSION_KHR, param->minor_ver, EGL_NONE};
    EGLContext ctx = eglCreateContext(r->display, r->config,
                                     param->shared ? r->root : EGL_NO_CONTEXT, attrs);
    return ctx == EGL_NO_CONTEXT ? NULL : ctx;
}

static void destroy_context(void *cookie, virgl_renderer_gl_context context)
{
    struct renderer *r = cookie;
    eglDestroyContext(r->display, context);
}

static int make_current(void *cookie, int scanout, virgl_renderer_gl_context context)
{
    (void)scanout;
    struct renderer *r = cookie;
    return eglMakeCurrent(r->display, EGL_NO_SURFACE, EGL_NO_SURFACE, context) ? 0 : -1;
}

static void *get_display(void *cookie) { return ((struct renderer *)cookie)->display; }
static void write_fence(void *cookie, uint32_t fence) { (void)cookie; (void)fence; }

static void require(int success, const char *operation)
{
    if (!success) {
        fprintf(stderr, "FAIL: %s (EGL 0x%x)\n", operation, eglGetError());
        exit(1);
    }
}

int main(int argc, char **argv)
{
    if (argc != 1 && !(argc == 3 && strcmp(argv[1], "--sandbox-check") == 0)) {
        fputs("Usage: metal-probe [--sandbox-check outside-sentinel-file]\n", stderr);
        return 1;
    }
    if (argc == 3 && !probe_containment(argv[2])) return 1;
    struct renderer r = {0};
    // Force Metal and hardware. Never allow silent CGL or software fallback.
    EGLint display_attrs[] = {EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE,
                             EGL_PLATFORM_ANGLE_DEVICE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_DEVICE_TYPE_HARDWARE_ANGLE,
                             EGL_NONE};
    r.display = eglGetPlatformDisplayEXT(EGL_PLATFORM_ANGLE_ANGLE, NULL, display_attrs);
    require(r.display != EGL_NO_DISPLAY && eglInitialize(r.display, NULL, NULL), "initialize ANGLE Metal");
    require(eglBindAPI(EGL_OPENGL_ES_API), "bind GLES");
    EGLint config_attrs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR,
                            EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                            EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
                            EGL_ALPHA_SIZE, 8, EGL_NONE};
    EGLint count = 0;
    require(eglChooseConfig(r.display, config_attrs, &r.config, 1, &count) && count == 1, "choose GLES config");
    EGLint context_attrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    r.root = eglCreateContext(r.display, r.config, EGL_NO_CONTEXT, context_attrs);
    require(r.root != EGL_NO_CONTEXT, "create root GLES context");
    require(make_current(&r, 0, r.root) == 0, "make root current");
    const char *identity = (const char *)glGetString(GL_RENDERER);
    require(identity && strstr(identity, "ANGLE Metal Renderer"), "verify Metal renderer identity");
    printf("RENDERER: %s\n", identity);

    // One-pixel correctness readback is confined to this dependency probe.
    // Normal VM presentation must keep full frames on the host GPU.
    GLuint texture = 0, framebuffer = 0;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
    require(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "create framebuffer");
    glClearColor(0, 1, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    unsigned char pixel[4] = {0};
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    require(glGetError() == GL_NO_ERROR && pixel[0] == 0 && pixel[1] == 255 && pixel[2] == 0 && pixel[3] == 255,
            "Metal clear/readback correctness");
    glDeleteFramebuffers(1, &framebuffer);
    glDeleteTextures(1, &texture);

    struct virgl_renderer_callbacks callbacks = {
        .version = 4, .write_fence = write_fence,
        .create_gl_context = create_context, .destroy_gl_context = destroy_context,
        .make_current = make_current, .get_egl_display = get_display,
    };
    require(virgl_renderer_init(&r, VIRGL_RENDERER_USE_GLES | VIRGL_RENDERER_NATIVE_SHARE_TEXTURE, &callbacks) == 0,
            "initialize VirGL with external Metal EGL display");
    for (uint32_t set = 1; set <= 2; ++set) {
        uint32_t version = 0, size = 0;
        virgl_renderer_get_cap_set(set, &version, &size);
        require(version > 0 && size > 0 && size <= 65536, "query bounded VirGL capability set");
        void *caps = calloc(1, size);
        require(caps != NULL, "allocate capset");
        virgl_renderer_fill_caps(set, version, caps);
        printf("CAPSET %u: version %u, %u bytes\n", set, version, size);
        free(caps);
    }
    struct virgl_renderer_resource_create_args resource = {
        .handle = 1, .target = 2, // PIPE_TEXTURE_2D in the pinned Gallium ABI.
        .format = VIRGL_FORMAT_B8G8R8A8_UNORM,
        .bind = VIRGL_BIND_RENDER_TARGET | VIRGL_BIND_SCANOUT,
        .width = 64, .height = 64, .depth = 1, .array_size = 1,
    };
    require(virgl_renderer_resource_create(&resource, NULL, 0) == 0, "create scanout resource");
    struct virgl_renderer_resource_info_ext info = {0};
    require(virgl_renderer_resource_get_info_ext(1, &info) == 0 &&
            info.native_type == VIRGL_NATIVE_HANDLE_METAL_TEXTURE && info.native_handle != NULL,
            "export native Metal scanout texture");
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, info.base.tex_id, 0);
    require(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "attach Metal-backed resource");
    glClearColor(1, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glFinish(); // Probe only; production fences must be asynchronous.
    require(glGetError() == GL_NO_ERROR && probe_shared_texture(info.native_handle),
            "GPU blit to IOSurface and shared-handle correctness");
    glDeleteFramebuffers(1, &framebuffer);
    virgl_renderer_resource_unref(1);
    virgl_renderer_cleanup(&r);
    eglMakeCurrent(r.display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(r.display, r.root);
    eglTerminate(r.display);
    puts("PASS: ANGLE Metal, VirGL capsets, native scanout texture and IOSurface GPU blit");
    puts("NOT TESTED: guest 3D submissions, presentation, helper IPC, adversarial containment, GPU timing or Chromium");
    return 0;
}
