// Chromium's VA ARGB route uses DRM ARGB8888 (BGRA bytes). Mesa calls that
// layout VA BGRA. This Chromium-only libva facade translates the three RGB
// metadata calls, retaining actual DRM plane layout, storage and driver caps.
// All other symbols resolve through its renamed, unmodified libva dependency.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <string.h>
#include <va/va.h>
#include <va/va_drmcommon.h>

static pthread_once_t initialized = PTHREAD_ONCE_INIT;
static VAStatus (*query)(VADisplay, VAConfigID, VASurfaceAttrib *, unsigned *);
static VAStatus (*create)(VADisplay, unsigned, unsigned, unsigned, VASurfaceID *, unsigned, VASurfaceAttrib *, unsigned);
static VAStatus (*export_surface)(VADisplay, VASurfaceID, uint32_t, uint32_t, void *);
static const char *(*vendor)(VADisplay);
static void initialize(void) {
    void *library = dlopen("/opt/bromure/chromium-vaapi/libbromure-va.so.2", RTLD_NOW | RTLD_LOCAL);
    if (!library) return;
    query = dlsym(library, "vaQuerySurfaceAttributes");
    create = dlsym(library, "vaCreateSurfaces");
    export_surface = dlsym(library, "vaExportSurfaceHandle");
    vendor = dlsym(library, "vaQueryVendorString");
}
static bool virgl(VADisplay display) {
    const char *name = vendor ? vendor(display) : NULL;
    return name && strstr(name, " for virgl");
}
VAStatus vaQuerySurfaceAttributes(VADisplay display, VAConfigID config, VASurfaceAttrib *attributes, unsigned *count) {
    pthread_once(&initialized, initialize);
    if (!query) return VA_STATUS_ERROR_OPERATION_FAILED;
    VAStatus status = query(display, config, attributes, count);
    if (status == VA_STATUS_SUCCESS && attributes && count && *count <= 128 && virgl(display))
        for (unsigned i = 0; i < *count; ++i)
            if (attributes[i].type == VASurfaceAttribPixelFormat &&
                attributes[i].value.type == VAGenericValueTypeInteger &&
                attributes[i].value.value.i == VA_FOURCC_BGRA)
                attributes[i].value.value.i = VA_FOURCC_ARGB;
    return status;
}
VAStatus vaCreateSurfaces(VADisplay display, unsigned format, unsigned width, unsigned height,
                         VASurfaceID *ids, unsigned surfaces, VASurfaceAttrib *attributes, unsigned count) {
    pthread_once(&initialized, initialize);
    if (!create) return VA_STATUS_ERROR_OPERATION_FAILED;
    if (format != VA_RT_FORMAT_RGB32 || !virgl(display))
        return create(display, format, width, height, ids, surfaces, attributes, count);
    if (count > 128 || (count && !attributes)) return VA_STATUS_ERROR_INVALID_PARAMETER;
    VASurfaceAttrib copy[129];
    VADRMPRIMESurfaceDescriptor descriptor;
    bool specified = false, prime2 = false;
    for (unsigned i = 0; i < count; ++i) {
        copy[i] = attributes[i];
        if (copy[i].type == VASurfaceAttribMemoryType && copy[i].value.type == VAGenericValueTypeInteger)
            prime2 = copy[i].value.value.i == VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2;
        if (copy[i].type == VASurfaceAttribPixelFormat || copy[i].type == VASurfaceAttribExternalBufferDescriptor)
            specified = true;
        if (copy[i].type == VASurfaceAttribPixelFormat && copy[i].value.type == VAGenericValueTypeInteger &&
            copy[i].value.value.i == VA_FOURCC_ARGB) copy[i].value.value.i = VA_FOURCC_BGRA;
    }
    for (unsigned i = 0; prime2 && i < count; ++i)
        if (copy[i].type == VASurfaceAttribExternalBufferDescriptor &&
            copy[i].value.type == VAGenericValueTypePointer && copy[i].value.value.p) {
            descriptor = *(const VADRMPRIMESurfaceDescriptor *)copy[i].value.value.p;
            if (descriptor.fourcc == VA_FOURCC_ARGB) {
                descriptor.fourcc = VA_FOURCC_BGRA;
                copy[i].value.value.p = &descriptor;
            }
        }
    if (!specified) copy[count++] = (VASurfaceAttrib){
        .type = VASurfaceAttribPixelFormat, .flags = VA_SURFACE_ATTRIB_SETTABLE,
        .value = {.type = VAGenericValueTypeInteger, .value.i = VA_FOURCC_BGRA}};
    return create(display, format, width, height, ids, surfaces, copy, count);
}
VAStatus vaExportSurfaceHandle(VADisplay display, VASurfaceID surface, uint32_t type, uint32_t flags, void *output) {
    pthread_once(&initialized, initialize);
    if (!export_surface) return VA_STATUS_ERROR_OPERATION_FAILED;
    VAStatus status = export_surface(display, surface, type, flags, output);
    if (status == VA_STATUS_SUCCESS && type == VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2 && output && virgl(display)) {
        VADRMPRIMESurfaceDescriptor *descriptor = output;
        if (descriptor->fourcc == VA_FOURCC_BGRA) descriptor->fourcc = VA_FOURCC_ARGB;
    }
    return status;
}
