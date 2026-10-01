#import "RendererServiceProtocol.h"
#include <unistd.h>
#include <virglrenderer.h>
#include <os/log.h>
#include <poll.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <spawn.h>
#include <sys/wait.h>
#include <mach/mach.h>

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


// One inherited, private Mach channel per worker. IOSurface send rights never
// enter a global namespace; pixel data stays on the GPU across both hops.
typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t surface;
} SurfaceMessage;
static mach_port_t worker_surface_port;

int renderer_worker_publish_surface(void)
{
    IOSurfaceRef surface = renderer_take_surface();
    if (!surface) return 0;
    mach_port_t port = IOSurfaceCreateMachPort(surface);
    if (surface) CFRelease(surface);
    SurfaceMessage message = {0};
    message.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    message.header.msgh_size = sizeof(message);
    message.header.msgh_remote_port = worker_surface_port;
    message.header.msgh_id = 0x42524750;
    message.body.msgh_descriptor_count = 1;
    message.surface.name = port;
    message.surface.disposition = MACH_MSG_TYPE_MOVE_SEND;
    message.surface.type = MACH_MSG_PORT_DESCRIPTOR;
    kern_return_t status = mach_msg(&message.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                                   sizeof(message), 0, MACH_PORT_NULL, 6000, MACH_PORT_NULL);
    if (status != KERN_SUCCESS && port) mach_port_deallocate(mach_task_self(), port);
    return status == KERN_SUCCESS ? 1 : -1;
}

@interface RendererService : NSObject <BromureRendererService>
@property int inputFD;
@property int outputFD;
@property pid_t workerPID;
@property mach_port_t surfacePort;
@property dispatch_queue_t transportQueue;
@property BOOL stopped;
- (BOOL)start;
- (void)stop;
@end

@implementation RendererService
- (BOOL)start
{
    os_log(OS_LOG_DEFAULT, "GPU worker starting");
    self.inputFD = -1; self.outputFD = -1;
    int request[2], response[2];
    if (pipe(request)) return NO;
    if (pipe(response)) { close(request[0]); close(request[1]); return NO; }
    mach_port_t port = MACH_PORT_NULL;
    posix_spawnattr_t attributes;
    posix_spawn_file_actions_t actions;
    posix_spawnattr_init(&attributes); posix_spawn_file_actions_init(&actions);
    int status = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
    if (!status) status = mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
    mach_port_array_t savedPorts = NULL;
    mach_msg_type_number_t savedCount = 0;
    if (!status) status = mach_ports_lookup(mach_task_self(), &savedPorts, &savedCount);
    if (!status) status = mach_ports_register(mach_task_self(), &port, 1);
    posix_spawn_file_actions_adddup2(&actions, request[0], STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, response[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, request[1]);
    posix_spawn_file_actions_addclose(&actions, response[0]);
    posix_spawn_file_actions_addclose(&actions, request[0]);
    posix_spawn_file_actions_addclose(&actions, response[1]);
    NSString *path = [[NSBundle mainBundle].executablePath.stringByDeletingLastPathComponent
                     stringByAppendingPathComponent:@"renderer-worker"];
    char *arguments[] = {(char *)path.fileSystemRepresentation, "--surface-worker", NULL};
    char *environment[] = {"PATH=/usr/bin:/bin", "LANG=C", "LC_ALL=C", NULL};
    pid_t pid = 0;
    os_log(OS_LOG_DEFAULT, "GPU worker spawning status=%d", status);
    if (!status) status = posix_spawn(&pid, arguments[0], &actions, &attributes, arguments, environment);
    if (savedPorts) {
        mach_ports_register(mach_task_self(), savedPorts, savedCount);
        for (unsigned i = 0; i < savedCount; ++i) if (savedPorts[i]) mach_port_deallocate(mach_task_self(), savedPorts[i]);
        vm_deallocate(mach_task_self(), (vm_address_t)savedPorts, savedCount * sizeof(mach_port_t));
    }
    os_log(OS_LOG_DEFAULT, "GPU worker spawned status=%d pid=%d", status, pid);
    posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes);
    close(request[0]); close(response[1]);
    if (status) {
        close(request[1]); close(response[0]);
        if (port) { mach_port_deallocate(mach_task_self(), port); mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1); }
        os_log_error(OS_LOG_DEFAULT, "GPU worker spawn failed: %d", status);
        return NO;
    }
    // This private channel belongs to one child until its VM disconnects.
    self.workerPID = pid; self.surfacePort = port;
    self.inputFD = request[1]; self.outputFD = response[0];
    for (int i = 0; i < 2; ++i) {
        int fd = i ? self.outputFD : self.inputFD;
        if (fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) < 0) { [self stop]; return NO; }
        fcntl(fd, F_SETFD, FD_CLOEXEC);
    }
    self.transportQueue = dispatch_queue_create("io.bromure.renderer.transport", DISPATCH_QUEUE_SERIAL);
    return YES;
}
- (void)stop
{
    @synchronized(self) {
        if (self.stopped) return;
        self.stopped = YES;
        if (self.inputFD >= 0) close(self.inputFD);
        if (self.outputFD >= 0) close(self.outputFD);
        if (self.surfacePort) { mach_port_deallocate(mach_task_self(), self.surfacePort); mach_port_mod_refs(mach_task_self(), self.surfacePort, MACH_PORT_RIGHT_RECEIVE, -1); }
        if (self.workerPID > 0) {
            kill(self.workerPID, SIGTERM);
            pid_t pid = self.workerPID;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ waitpid(pid, NULL, 0); });
        }
    }
}
- (void)processCommand:(NSData *)command reply:(void (^)(NSData *, IOSurface *, NSError *))reply
{
    uint32_t kind = 0;
    if (command.length >= 24) memcpy(&kind, command.bytes, sizeof(kind));
    if (command.length < 24 || command.length > (kind == 0x207 ? 1048576u : 65536u)) {
        reply(nil, nil, [NSError errorWithDomain:@"BromureRenderer" code:1 userInfo:nil]); return;
    }
    NSData *snapshot = [command copy];
    dispatch_async(self.transportQueue, ^{
        if (self.stopped) { reply(nil, nil, [NSError errorWithDomain:@"BromureRenderer" code:2 userInfo:nil]); return; }
        uint32_t length = (uint32_t)snapshot.length;
        double deadline = monotonic_time() + 6;
        if (!transfer(self.inputFD, (uint8_t *)&length, 4, 1, deadline) ||
            !transfer(self.inputFD, (uint8_t *)snapshot.bytes, snapshot.length, 1, deadline) ||
            !transfer(self.outputFD, (uint8_t *)&length, 4, 0, deadline)) {
            reply(nil, nil, [NSError errorWithDomain:@"BromureRenderer" code:2 userInfo:nil]); [self stop]; return;
        }
        BOOL hasSurface = (length & 0x80000000u) != 0;
        length &= 0x7fffffffu;
        if (length < 24 || length > 65536) {
            reply(nil, nil, [NSError errorWithDomain:@"BromureRenderer" code:2 userInfo:nil]); [self stop]; return;
        }
        NSMutableData *response = [NSMutableData dataWithLength:length];
        if (!transfer(self.outputFD, response.mutableBytes, length, 0, deadline)) {
            reply(nil, nil, [NSError errorWithDomain:@"BromureRenderer" code:3 userInfo:nil]); [self stop]; return;
        }
        if (!hasSurface) { reply(response, nil, nil); return; }
        struct { SurfaceMessage message; mach_msg_max_trailer_t trailer; } incoming = {0};
        kern_return_t status = mach_msg(&incoming.message.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT,
            0, sizeof(incoming), self.surfacePort, 6000, MACH_PORT_NULL);
        SurfaceMessage *m = &incoming.message;
        if (status != KERN_SUCCESS || m->header.msgh_id != 0x42524750 ||
            m->header.msgh_size != sizeof(*m) || !(m->header.msgh_bits & MACH_MSGH_BITS_COMPLEX) ||
            m->body.msgh_descriptor_count != 1 || m->surface.type != MACH_MSG_PORT_DESCRIPTOR) {
            os_log_error(OS_LOG_DEFAULT, "GPU surface receive status=%d id=%x size=%u expected=%zu bits=%x descriptors=%u type=%u", status, m->header.msgh_id, m->header.msgh_size, sizeof(*m), m->header.msgh_bits, m->body.msgh_descriptor_count, m->surface.type);
            if (status == KERN_SUCCESS) mach_msg_destroy(&m->header);
            reply(nil, nil, [NSError errorWithDomain:@"BromureRenderer" code:4 userInfo:nil]); [self stop]; return;
        }
        IOSurface *surface = m->surface.name ? CFBridgingRelease(IOSurfaceLookupFromMachPort(m->surface.name)) : nil;
        mach_msg_destroy(&m->header);
        reply(response, surface, nil);
    });
}
@end

@interface RendererBroker : NSObject <NSXPCListenerDelegate>
@end
@implementation RendererBroker
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection
{
    (void)listener;
    if (connection.effectiveUserIdentifier != geteuid()) return NO;
    RendererService *service = [RendererService new];
    @synchronized(RendererService.class) { if (![service start]) return NO; }
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(BromureRendererService)];
    connection.exportedObject = service;
    connection.invalidationHandler = ^{ dispatch_async(service.transportQueue, ^{ [service stop]; }); };
    [connection resume];
    return YES;
}
@end

int renderer_xpc_main(int argc, char **argv)
{
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        if (argc == 2 && !strcmp(argv[1], "--surface-worker")) {
            mach_port_array_t ports = NULL;
            mach_msg_type_number_t count = 0;
            if (mach_ports_lookup(mach_task_self(), &ports, &count) || count < 1 || !ports[0]) return 1;
            worker_surface_port = ports[0];
            vm_deallocate(mach_task_self(), (vm_address_t)ports, count * sizeof(mach_port_t));
            char *arguments[] = {"metal-probe", "--worker", NULL};
            virgl_set_log_callback(renderer_log, NULL, NULL);
            return renderer_probe_main(2, arguments);
        }
        __attribute__((objc_precise_lifetime)) RendererBroker *broker = [RendererBroker new];
        NSXPCListener *listener = [NSXPCListener serviceListener];
        listener.delegate = broker;
        [listener resume];
        return 0;
    }
}
