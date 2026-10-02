// Exercise the production callback with real CoreVideo/IOSurface allocations.
#include "virgl-video-videotoolbox.m"
#include <assert.h>
#include <stdio.h>

// The backend logging helper is hidden in the production shared library.
void virgl_logv(enum virgl_log_level_flags level, const char *format, va_list arguments) {
    (void)level; vfprintf(stderr, format, arguments);
}

static CVPixelBufferRef surface(unsigned width, unsigned height) {
    CVPixelBufferRef image = NULL;
    NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                                  (id)kCVPixelBufferMetalCompatibilityKey: @YES};
    assert(CVPixelBufferCreate(kCFAllocatorDefault, width, height,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        (CFDictionaryRef)attributes, &image) == kCVReturnSuccess);
    assert(image && CVPixelBufferGetIOSurface(image));
    return image;
}

int main(void) {
    @autoreleasepool {
        initialized = true;
        const unsigned sizes[][2] = {{64,64}, {1280,720}, {1920,1080}, {3840,2160}};
        for (unsigned i = 0; i < 4; ++i) {
            struct virgl_video_create_buffer_args args = {
                .format = PIPE_FORMAT_NV12, .width = sizes[i][0], .height = sizes[i][1]};
            struct virgl_video_buffer *buffer = virgl_video_create_buffer(&args);
            assert(buffer);
            struct virgl_video_codec codec = {0};
            CVPixelBufferRef first = surface(args.width, args.height);
            size_t allocation = IOSurfaceGetAllocSize(CVPixelBufferGetIOSurface(first));
            decoded(&codec, buffer, 0, 0, first, kCMTimeZero, kCMTimeZero);
            assert(codec.error == 0 && buffer->image == first);
            CVPixelBufferRef replacement = surface(args.width, args.height);
            uint64_t reservation = buffer->reserved_bytes;
            buffer->reserved_bytes = allocation - 1;
            decoded(&codec, buffer, 0, 0, replacement, kCMTimeZero, kCMTimeZero);
            assert(codec.error != 0 && buffer->image == first);
            buffer->reserved_bytes = reservation;
            codec.error = 0;
            decoded(&codec, buffer, 0, 0, replacement, kCMTimeZero, kCMTimeZero);
            assert(codec.error == 0 && buffer->image == replacement);
            printf("VIDEO_SURFACE_BUDGET size=%ux%u allocated=%zu reserved=%llu\n",
                   args.width, args.height, allocation, (unsigned long long)reservation);
            CVPixelBufferRelease(first); CVPixelBufferRelease(replacement);
            virgl_video_destroy_buffer(buffer);
            assert(video_buffer_bytes == 0 && buffer_count == 0);
        }
        puts("BROMURE_VIDEO_SURFACE_BUDGET_PASS");
    }
    return 0;
}
