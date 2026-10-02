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
        NSXPCConnection *connection = [[NSXPCConnection alloc] initWithServiceName:@"io.bromure.gpu.renderer.broker"];
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
        NSXPCConnection *second = [[NSXPCConnection alloc] initWithServiceName:@"io.bromure.gpu.renderer.broker"];
        second.remoteObjectInterface = connection.remoteObjectInterface;
        [second resume];
        NSArray<NSXPCConnection *> *connections = @[connection, second];
        NSMutableArray<IOSurface *> *surfaces = [NSMutableArray new];
        __block IOSurface *received = nil;
        for (NSUInteger index = 0; index < connections.count; ++index) {
            NSXPCConnection *current = connections[index];
            received = nil;
        for (NSData *original in commands) {
            NSMutableData *command = [original mutableCopy];
            if (index == 1 && *(const uint32_t *)command.bytes == 0x207) {
                uint32_t *words = command.mutableBytes; words[20] = 0; words[22] = 0x3f800000;
            }
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            __block BOOL valid = NO;
            id<BromureRendererService> proxy = [current remoteObjectProxyWithErrorHandler:^(NSError *error) {
                fprintf(stderr, "XPC ERROR: %s\n", error.localizedDescription.UTF8String);
                dispatch_semaphore_signal(done);
            }];
            [proxy processCommand:command reply:^(NSData *response, IOSurface *surface, NSError *error) {
                uint32_t type = 0;
                if (response.length >= 24) memcpy(&type, response.bytes, 4);
                valid = !error && type == 0x1100;
                if (!valid) fprintf(stderr, "command=%x response=%x error=%s\n", *(const uint32_t *)command.bytes, type, error.description.UTF8String);
                if (surface) received = surface;
                dispatch_semaphore_signal(done);
            }];
            if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) || !valid) {
                fputs("FAIL: renderer XPC command\n", stderr); [connection invalidate]; return 1;
            }
        }
            if (!received) return 1;
            [surfaces addObject:received];
        }
        received = surfaces[0];
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
        if (!correct || !texture) return 1;
        [connection invalidate];
        // The second renderer survives the first VM's teardown and retains its
        // own resource 9/context 7, despite identical IDs in both guests.
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block BOOL blue = NO;
        id<BromureRendererService> proxy = [second remoteObjectProxyWithErrorHandler:^(NSError *error) {
            fprintf(stderr, "second renderer: %s\n", error.description.UTF8String);
            dispatch_semaphore_signal(done);
        }];
        [proxy processCommand:request(0x104, 0, 0, flush, 6) reply:^(NSData *response, IOSurface *frame, NSError *error) {
            IOSurfaceRef surface = (__bridge IOSurfaceRef)frame;
            if (!error && response.length == 24 && surface && IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL) == kIOReturnSuccess) {
                const uint8_t *pixel = IOSurfaceGetBaseAddress(surface);
                blue = pixel && pixel[0] == 255 && pixel[1] == 0 && pixel[2] == 0 && pixel[3] == 255;
                IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
            }
            dispatch_semaphore_signal(done);
        }];
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) || !blue) return 1;
        [second invalidate];
        puts("PASS: two simultaneous sandboxed Metal workers isolate identical resource/context IDs, transfer correct red/blue IOSurfaces, and survive independent teardown");
        return 0;
    }
}
