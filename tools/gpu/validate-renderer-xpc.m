#import "RendererServiceProtocol.h"
#import <Metal/Metal.h>
#include <stdio.h>

static NSData *request(uint32_t type, uint32_t context, uint32_t flags,
                       const uint32_t *body, size_t words)
{
    NSMutableData *data = [NSMutableData dataWithLength:24 + words * 4];
    uint32_t *buffer = data.mutableBytes;
    buffer[0] = type; buffer[1] = flags; buffer[2] = 123; buffer[4] = context;
    if (words) memcpy(buffer + 6, body, words * 4);
    return data;
}

int main(void)
{
    @autoreleasepool {
        if (@available(macOS 27.0, *)) {} else { puts("SKIP: macOS 27 required"); return 0; }
        NSXPCConnection *connection = [[NSXPCConnection alloc] initWithServiceName:@"io.bromure.gpu.renderer"];
        connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(BromureRendererService)];
        [connection resume];
        uint32_t create[18] = {4, 0, 0x74736574};
        uint32_t resource[] = {9, 2, 1, (1 << 1) | (1 << 18), 64, 64, 1, 1, 0, 0, 0, 0};
        uint32_t attach[] = {9, 0};
        uint32_t geometry[] = {64, 64};
        uint32_t scanout[] = {0, 0, 64, 64, 0, 9};
        uint32_t flush[] = {0, 0, 64, 64, 9, 0};
        uint32_t stream[] = {
            1 | (8 << 8) | (5 << 16), 11, 9, 1, 0, 0,
            5 | (3 << 16), 1, 0, 11,
            7 | (8 << 16), 4, 0x3f800000, 0, 0, 0x3f800000, 0, 0, 0,
        };
        uint32_t submit[2 + sizeof(stream) / 4];
        submit[0] = sizeof(stream); submit[1] = 0; memcpy(submit + 2, stream, sizeof(stream));
        NSArray<NSData *> *commands = @[
            request(0xffff0020, 0, 0, geometry, 2),
            request(0x200, 7, 0, create, 18), request(0x204, 0, 0, resource, 12),
            request(0x202, 7, 0, attach, 2), request(0x207, 7, 1, submit, sizeof(submit) / 4),
            request(0x103, 0, 0, scanout, 6), request(0x104, 0, 0, flush, 6),
        ];
        __block IOSurface *received = nil;
        for (NSData *command in commands) {
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            __block BOOL valid = NO;
            id<BromureRendererService> proxy = [connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
                fprintf(stderr, "XPC ERROR: %s\n", error.localizedDescription.UTF8String);
                dispatch_semaphore_signal(done);
            }];
            [proxy processCommand:command reply:^(NSData *response, IOSurface *surface, NSError *error) {
                uint32_t type = 0;
                if (response.length >= 24) memcpy(&type, response.bytes, 4);
                valid = !error && type == 0x1100;
                if (surface) received = surface;
                dispatch_semaphore_signal(done);
            }];
            if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) || !valid) {
                fputs("FAIL: renderer XPC command\n", stderr); [connection invalidate]; return 1;
            }
        }
        IOSurfaceRef surface = (__bridge IOSurfaceRef)received;
        if (!surface || IOSurfaceGetWidth(surface) != 64 || IOSurfaceGetHeight(surface) != 64 ||
            IOSurfaceGetPixelFormat(surface) != 0x42475241 || IOSurfaceGetAllocSize(surface) > 1048576 ||
            IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL) != kIOReturnSuccess) return 1;
        const uint8_t *pixel = IOSurfaceGetBaseAddress(surface);
        BOOL correct = pixel && pixel[0] == 0 && pixel[1] == 0 && pixel[2] == 255 && pixel[3] == 255;
        IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> texture = [MTLCreateSystemDefaultDevice() newTextureWithDescriptor:descriptor iosurface:surface plane:0];
        [connection invalidate];
        if (!correct || !texture) return 1;
        puts("PASS: embedded sandboxed XPC renderer executed VirGL commands; cross-process IOSurface imported as Metal texture and red pixel verified");
        return 0;
    }
}
