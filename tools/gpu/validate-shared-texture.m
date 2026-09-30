// Host GPU blits for IOSurface presentation and trusted texture correctness probes.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <mach/mach.h>
#include <stdint.h>
#include <stdio.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <pthread.h>

static pthread_mutex_t surface_lock = PTHREAD_MUTEX_INITIALIZER;
static IOSurfaceRef pending_surface;

IOSurfaceRef renderer_take_surface(void)
{
    pthread_mutex_lock(&surface_lock);
    IOSurfaceRef surface = pending_surface;
    pending_surface = NULL;
    pthread_mutex_unlock(&surface_lock);
    return surface;
}

int renderer_capture_surface(void *native_texture)
{
    @autoreleasepool {
        id<MTLTexture> source = (__bridge id<MTLTexture>)native_texture;
        if (!source || !source.width || !source.height || source.width > 8192 || source.height > 8192 ||
            source.pixelFormat != MTLPixelFormatBGRA8Unorm) return 0;
        NSDictionary *properties = @{
            (id)kIOSurfaceWidth: @(source.width), (id)kIOSurfaceHeight: @(source.height),
            (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @(0x42475241),
        };
        IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
        if (!surface) return 0;
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
            width:source.width height:source.height mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> destination = [source.device newTextureWithDescriptor:descriptor iosurface:surface plane:0];
        id<MTLCommandBuffer> command = [[source.device newCommandQueue] commandBuffer];
        id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
        if (!destination || !command || !blit) { CFRelease(surface); return 0; }
        [blit copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                  sourceSize:MTLSizeMake(source.width, source.height, 1)
                   toTexture:destination destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted) { CFRelease(surface); return 0; }
        pthread_mutex_lock(&surface_lock);
        if (pending_surface) CFRelease(pending_surface);
        pending_surface = surface;
        pthread_mutex_unlock(&surface_lock);
        return 1;
    }
}

int probe_containment(const char *outside_file)
{
    errno = 0;
    int descriptor = open(outside_file, O_RDONLY);
    int file_error = errno;
    if (descriptor >= 0) close(descriptor);
    errno = 0;
    int connection = socket(AF_INET, SOCK_STREAM, 0);
    int network_error = errno;
    if (connection >= 0) {
        struct sockaddr_in address = {0};
        address.sin_family = AF_INET;
        address.sin_port = htons(9);
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (connect(connection, (const struct sockaddr *)&address, sizeof(address)) == 0) {
            network_error = 0;
        } else { network_error = errno; }
        close(connection);
    }
    int success = descriptor < 0 && (file_error == EPERM || file_error == EACCES) &&
                  (network_error == EPERM || network_error == EACCES);
    if (success) puts("CONTAINMENT: outside sentinel file and network connection denied");
    else fprintf(stderr, "FAIL: containment (file errno %d, network errno %d)\n", file_error, network_error);
    return success;
}

int probe_shared_texture(void *native_texture)
{
    @autoreleasepool {
        id<MTLTexture> source = (__bridge id<MTLTexture>)native_texture;
        if (source.width != 64 || source.height != 64 || source.pixelFormat != MTLPixelFormatBGRA8Unorm)
            return 0;
        NSDictionary *properties = @{
            (id)kIOSurfaceWidth: @64, (id)kIOSurfaceHeight: @64,
            (id)kIOSurfaceBytesPerElement: @4,
            (id)kIOSurfacePixelFormat: @(0x42475241), // BGRA fourcc.
        };
        IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
        if (!surface) return 0;
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        id<MTLTexture> destination = [source.device newTextureWithDescriptor:descriptor iosurface:surface plane:0];
        id<MTLCommandQueue> queue = [source.device newCommandQueue];
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
        if (!destination || !command || !blit) { CFRelease(surface); return 0; }
        [blit copyFromTexture:source sourceSlice:0 sourceLevel:0
                sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(64, 64, 1)
                   toTexture:destination destinationSlice:0 destinationLevel:0
           destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
        [command commit];
        [command waitUntilCompleted]; // Probe only; production waits cannot block device/UI queues.
        int success = command.status == MTLCommandBufferStatusCompleted;
        mach_port_t port = IOSurfaceCreateMachPort(surface);
        IOSurfaceRef imported = port == MACH_PORT_NULL ? NULL : IOSurfaceLookupFromMachPort(port);
        success = success && imported && IOSurfaceGetWidth(imported) == 64;
        if (success && IOSurfaceLock(imported, kIOSurfaceLockReadOnly, NULL) == kIOReturnSuccess) {
            const uint8_t *pixel = IOSurfaceGetBaseAddress(imported);
            // Inspect only one pixel to validate the probe's red clear survived sharing.
            success = pixel && pixel[0] == 0 && pixel[1] == 0 && pixel[2] == 255 && pixel[3] == 255;
            IOSurfaceUnlock(imported, kIOSurfaceLockReadOnly, NULL);
        } else { success = 0; }
        if (success) puts("NATIVE TEXTURE: Metal GPU blit to IOSurface; Mach-port import and red pixel verified");
        if (imported) CFRelease(imported);
        if (port != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), port);
        CFRelease(surface);
        return success;
    }
}
