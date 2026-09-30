#import "RendererServiceProtocol.h"
#include <unistd.h>
#include <virglrenderer.h>
#include <os/log.h>
#include <poll.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <time.h>

extern int renderer_probe_main(int argc, char **argv);
extern IOSurfaceRef renderer_take_surface(void);

static void renderer_log(enum virgl_log_level_flags level, const char *message, void *unused)
{
    (void)unused;
    if (level >= VIRGL_LOG_LEVEL_WARNING) os_log_error(OS_LOG_DEFAULT, "VirGL: %{public}.512s", message);
}

static double monotonic_time(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec + now.tv_nsec / 1e9;
}
static int transfer(int fd, uint8_t *bytes, size_t count, int writing, double deadline)
{
    size_t offset = 0;
    while (offset < count) {
        double remaining = deadline - monotonic_time();
        if (remaining <= 0) return 0;
        struct pollfd readiness = {fd, writing ? POLLOUT : POLLIN, 0};
        int ready = poll(&readiness, 1, (int)(remaining * 1000));
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0 || !(readiness.revents & readiness.events)) return 0;
        ssize_t n = writing ? write(fd, bytes + offset, count - offset) : read(fd, bytes + offset, count - offset);
        if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (n <= 0) return 0;
        offset += (size_t)n;
    }
    return 1;
}

@interface RendererService : NSObject <BromureRendererService, NSXPCListenerDelegate>
@property int inputFD;
@property int outputFD;
@property dispatch_queue_t transportQueue;
@property BOOL connected;
@end

@implementation RendererService
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection
{
    (void)listener;
    // Embedded application XPC service: one owner, no public Mach service.
    if (self.connected || connection.effectiveUserIdentifier != geteuid()) return NO;
    self.connected = YES;
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(BromureRendererService)];
    connection.exportedObject = self;
    connection.invalidationHandler = ^{ _exit(0); };
    [connection resume];
    return YES;
}
- (void)processCommand:(NSData *)command
                 reply:(void (^)(NSData *, IOSurface *, NSError *))reply
{
    if (command.length < 24 || command.length > 65536) {
        reply(nil, nil, [NSError errorWithDomain:@"BromureRenderer" code:1 userInfo:nil]);
        return;
    }
    // An owned immutable copy before dispatch. All GPU requests remain ordered.
    NSData *snapshot = [command copy];
    dispatch_async(self.transportQueue, ^{
        uint32_t length = (uint32_t)snapshot.length;
        double deadline = monotonic_time() + 6;
        if (!transfer(self.inputFD, (uint8_t *)&length, 4, 1, deadline) ||
            !transfer(self.inputFD, (uint8_t *)snapshot.bytes, snapshot.length, 1, deadline) ||
            !transfer(self.outputFD, (uint8_t *)&length, 4, 0, deadline) || length < 24 || length > 65536) {
            reply(nil, nil, [NSError errorWithDomain:@"BromureRenderer" code:2 userInfo:nil]);
            _exit(1);
        }
        NSMutableData *response = [NSMutableData dataWithLength:length];
        if (!transfer(self.outputFD, response.mutableBytes, length, 0, deadline)) {
            reply(nil, nil, [NSError errorWithDomain:@"BromureRenderer" code:3 userInfo:nil]);
            _exit(1);
        }
        IOSurface *surface = CFBridgingRelease(renderer_take_surface());
        reply(response, surface, nil);
    });
}
@end

int renderer_xpc_main(void)
{
    @autoreleasepool {
        int request[2], response[2];
        if (pipe(request) || pipe(response)) return 1;
        if (dup2(request[0], STDIN_FILENO) < 0 || dup2(response[1], STDOUT_FILENO) < 0) return 1;
        close(request[0]); close(response[1]);
        signal(SIGPIPE, SIG_IGN);
        for (int i = 0; i < 2; ++i) {
            int fd = i ? response[0] : request[1];
            if (fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) < 0) return 1;
        }
        RendererService *service = [RendererService new];
        service.inputFD = request[1]; service.outputFD = response[0];
        service.transportQueue = dispatch_queue_create("io.bromure.renderer.transport", DISPATCH_QUEUE_SERIAL);
        dispatch_async(dispatch_queue_create("io.bromure.renderer.gpu", DISPATCH_QUEUE_SERIAL), ^{
            char *arguments[] = {"metal-probe", "--worker", NULL};
            virgl_set_log_callback(renderer_log, NULL, NULL);
            _exit(renderer_probe_main(2, arguments));
        });
        NSXPCListener *listener = [NSXPCListener serviceListener];
        listener.delegate = service;
        [listener resume];
        return 0;
    }
}
