// Bounded VirGL renderer worker. Receives immutable bytes, never guest pointers.
#include <virglrenderer.h>
#include <virgl_hw.h>
#include <epoxy/gl.h>
#include <os/log.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <sys/uio.h>
#include <sys/sysctl.h>

enum { MAX_FRAME = 65536, MAX_REQUEST = 1048576, MAX_CONTEXTS = 32 };
enum { MAX_RESOURCES = 4096 };
extern int probe_shared_texture(void *native_texture);
extern int renderer_capture_surface(void *native_texture);
extern int renderer_capture_surface_region(void *native_texture, uint32_t x, uint32_t y, uint32_t width, uint32_t height);
static uint32_t retired_fence;
void renderer_worker_fence(uint32_t fence) { retired_fence = fence; }
static int wait_for_gpu(uint32_t token, uint32_t context)
{
    if (virgl_renderer_create_fence((int)token, context)) return 0;
    struct timespec start, now, interval = {0, 50000};
    clock_gettime(CLOCK_MONOTONIC, &start);
    for (;;) {
        virgl_renderer_poll();
        if (retired_fence == token) return 1;
        clock_gettime(CLOCK_MONOTONIC, &now);
        int64_t elapsed = (int64_t)(now.tv_sec - start.tv_sec) * 1000000000 +
                          now.tv_nsec - start.tv_nsec;
        if (elapsed >= 5000000000LL) return 0;
        // Most Metal fences complete well below a millisecond. A fixed 1ms
        // sleep serializes that delay into every fenced guest command. Poll
        // briefly at lower latency, then back off for genuinely long work.
        interval.tv_nsec = elapsed < 1000000 ? 50000 :
                           elapsed < 5000000 ? 250000 : 1000000;
        nanosleep(&interval, NULL);
    }
}
static uint32_t load32(const uint8_t *p)
{ return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static void store32(uint8_t *p, uint32_t value)
{ for (unsigned i = 0; i < 4; ++i) p[i] = (uint8_t)(value >> (i * 8)); }
static uint64_t load64(const uint8_t *p) { return load32(p) | (uint64_t)load32(p + 4) << 32; }

// Grow reservations in bounded 256-MiB steps for real live allocations.
// The guest cannot exceed the same RAM and absolute ceilings used for geometry.
static int grow_pool(uint64_t required, uint64_t *limit, uint64_t ram_ceiling, uint64_t hard_ceiling)
{
    if (required <= *limit) return 1;
    uint64_t ceiling = ram_ceiling < hard_ceiling ? ram_ceiling : hard_ceiling;
    if (required > ceiling) return 0;
    uint64_t quantum = 268435456;
    *limit = (required + quantum - 1) / quantum * quantum;
    return 1;
}

// Distinguish clean EOF from truncated frames. Never trust a short pipe read.
static int read_exact(int fd, uint8_t *buffer, size_t count)
{
    size_t done = 0;
    while (done < count) {
        ssize_t n = read(fd, buffer + done, count - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return n == 0 && done == 0 ? 0 : -1;
        done += (size_t)n;
    }
    return 1;
}
static int write_exact(int fd, const uint8_t *buffer, size_t count)
{
    size_t done = 0;
    while (done < count) {
        ssize_t n = write(fd, buffer + done, count - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return 0;
        done += (size_t)n;
    }
    return 1;
}

int run_renderer_worker(int output_fd)
{
    uint32_t contexts[MAX_CONTEXTS] = {0};
    uint32_t resources[MAX_RESOURCES] = {0}, fence_token = 0;
    uint64_t resource_bytes[MAX_RESOURCES] = {0}, total_resource_bytes = 0;
    uint64_t peak_resource_bytes = 0, peak_backing_bytes = 0;
    struct iovec backing[MAX_RESOURCES] = {0};
    uint64_t total_backing = 0;
    uint64_t gpu_limit = 1073741824, staging_limit = 1073741824, resource_limit = 268435456;
    uint64_t texture_pixel_limit = 33554432;
    uint64_t physical_memory = 8589934592; size_t memory_size = sizeof(physical_memory);
    if (sysctlbyname("hw.memsize", &physical_memory, &memory_size, NULL, 0)) physical_memory = 8589934592;
    // Both pools are bounded by one eighth of host RAM, with a 1 GiB floor.
    uint64_t ram_ceiling = physical_memory / 8 / 268435456 * 268435456;
    if (ram_ceiling < 1073741824) ram_ceiling = 1073741824;
    struct scanout_state {
        uint32_t display_x, display_y, display_width, display_height, enabled;
        uint32_t resource, x, y, width, height;
    } scanouts[16] = {0};
    uint32_t scanout_count = 1;
    // One ordered worker per process; keep the bounded submission buffer off the stack.
    _Alignas(8) static uint8_t request[MAX_REQUEST];
    _Alignas(8) uint8_t response[MAX_FRAME];
    uint8_t prefix[4];
    for (;;) {
        int got = read_exact(STDIN_FILENO, prefix, 4);
        if (got == 0) {
            virgl_renderer_reset();
            for (int i = 0; i < MAX_RESOURCES; ++i) free(backing[i].iov_base);
            return 0;
        }
        if (got < 0) return 1;
        uint32_t length = load32(prefix);
        if (length < 24 || length > MAX_REQUEST || read_exact(STDIN_FILENO, request, length) != 1) return 1;
        uint32_t type = load32(request), flags = load32(request + 4), context = load32(request + 16);
        uint32_t result = 0x1205, response_length = 24;
        memset(response, 0, sizeof(response));
        if (length > MAX_FRAME && type != 0x207) goto reply;
        // No multiple timelines/context-init feature is advertised.
        if (flags & ~1u) goto reply;
        store32(response + 4, flags);
        if (flags & 1u) memcpy(response + 8, request + 8, 8);
        store32(response + 16, context);
        switch (type) {
        case 0x100: // GET_DISPLAY_INFO: geometry is configured by the host before VM boot.
            if (length != 24) break;
            response_length = 24 + 384;
            for (uint32_t i = 0; i < scanout_count; ++i) {
                struct scanout_state *s = &scanouts[i];
                uint32_t base = 24 + i * 24;
                store32(response + base, s->display_x); store32(response + base + 4, s->display_y);
                store32(response + base + 8, s->display_width); store32(response + base + 12, s->display_height);
                store32(response + base + 16, s->enabled);
            }
            result = 0x1101;
            break;
        case 0x108: { // GET_CAPSET_INFO
            if (length != 32 || load32(request + 24) >= 2) break;
            uint32_t set = load32(request + 24) + 1, version = 0, size = 0;
            virgl_renderer_get_cap_set(set, &version, &size);
            if (!size || size > MAX_FRAME - 24) break;
            store32(response + 24, set); store32(response + 28, version); store32(response + 32, size);
            response_length = 40; result = 0x1102;
            break;
        }
        case 0x109: { // GET_CAPSET
            if (length != 32) break;
            uint32_t set = load32(request + 24), version = load32(request + 28), maximum = 0, size = 0;
            if (set < 1 || set > 2) break;
            virgl_renderer_get_cap_set(set, &maximum, &size);
            // Linux requests version zero when probing the base VirGL capset.
            if (version > maximum || !size || size > MAX_FRAME - 24) break;
            virgl_renderer_fill_caps(set, version, response + 24);
            response_length = 24 + size; result = 0x1103;
            break;
        }
        case 0x200: { // CTX_CREATE
            if (length != 96 || flags || !context || context > 0x7fffffff || load32(request + 24) > 64 || load32(request + 28)) break;
            int slot = -1;
            for (int i = 0; i < MAX_CONTEXTS; ++i) {
                if (contexts[i] == context) { slot = -2; break; }
                if (!contexts[i] && slot == -1) slot = i;
            }
            if (slot == -2) { result = 0x1204; break; }
            if (slot == -1) { result = 0x1201; break; }
            if (virgl_renderer_context_create(context, load32(request + 24), (const char *)request + 32)) {
                result = 0x1200; break;
            }
            contexts[slot] = context; result = 0x1100;
            break;
        }
        case 0x201: { // CTX_DESTROY
            if (length != 24 || flags || !context) break;
            result = 0x1204;
            for (int i = 0; i < MAX_CONTEXTS; ++i) {
                if (contexts[i] != context) continue;
                virgl_renderer_context_destroy(context); contexts[i] = 0; result = 0x1100; break;
            }
            break;
        }
        case 0x101: // RESOURCE_CREATE_2D
        case 0x204: { // RESOURCE_CREATE_3D: finite resource and dimension budgets.
            if (length != (type == 0x101 ? 40u : 72u)) break;
            uint32_t id = load32(request + 24);
            int slot = -1;
            for (int i = 0; i < MAX_RESOURCES; ++i) {
                if (resources[i] == id) { slot = -2; break; }
                if (!resources[i] && slot == -1) slot = i;
            }
            if (!id || id > 0x7fffffff || slot == -2) { result = 0x1203; break; }
            if (slot < 0) {
                os_log_error(OS_LOG_DEFAULT, "GPU resource slots exhausted id=%u limit=%u bytes=%llu", id, MAX_RESOURCES, (unsigned long long)total_resource_bytes);
                result = 0x1201; break;
            }
            struct virgl_renderer_resource_create_args args = {0};
            if (type == 0x101) {
                args = (struct virgl_renderer_resource_create_args){
                    .handle = id, .target = 2, .format = load32(request + 28),
                    .bind = VIRGL_BIND_RENDER_TARGET | VIRGL_BIND_SCANOUT,
                    .width = load32(request + 32), .height = load32(request + 36),
                    .depth = 1, .array_size = 1, .flags = 1,
                };
                if (args.format != 1 && args.format != 2) break;
            } else {
                args = (struct virgl_renderer_resource_create_args){
                .handle = id, .target = load32(request + 28), .format = load32(request + 32),
                .bind = load32(request + 36), .width = load32(request + 40),
                .height = load32(request + 44), .depth = load32(request + 48),
                .array_size = load32(request + 52), .last_level = load32(request + 56),
                .nr_samples = load32(request + 60), .flags = load32(request + 64),
            };
            }
            uint32_t max_width = args.target == 0 ? resource_limit : 8192;
            if (!args.width || args.width > max_width || !args.height || args.height > 8192 ||
                !args.depth || args.depth > 256 || !args.array_size || args.array_size > 256 ||
                args.last_level > 13 || args.nr_samples > 8 || args.flags & ~1u ||
                (args.target != 0 && (uint64_t)args.width * args.height * args.depth * args.array_size > texture_pixel_limit)) break;
            // Account common browser formats by storage size. A worst-case
            // fallback bounds other formats; only mipmapped resources double.
            uint32_t texel_bytes = 32;
            if ((args.format >= 1 && args.format <= 8) ||
                (args.format >= 99 && args.format <= 104) ||
                args.format == VIRGL_FORMAT_R8G8B8A8_UNORM || args.format == VIRGL_FORMAT_A8B8G8R8_UNORM)
                texel_bytes = 4;
            else if (args.format == VIRGL_FORMAT_R8_UNORM) texel_bytes = 1;
            else if (args.format == VIRGL_FORMAT_R8G8_UNORM) texel_bytes = 2;
            else if (args.format == VIRGL_FORMAT_Z16_UNORM) texel_bytes = 2;
            else if (args.format == VIRGL_FORMAT_S8_UINT) texel_bytes = 1;
            else if (args.format == VIRGL_FORMAT_Z32_UNORM || args.format == VIRGL_FORMAT_Z32_FLOAT ||
                     args.format == VIRGL_FORMAT_Z24_UNORM_S8_UINT || args.format == VIRGL_FORMAT_S8_UINT_Z24_UNORM ||
                     args.format == VIRGL_FORMAT_Z24X8_UNORM || args.format == VIRGL_FORMAT_X8Z24_UNORM)
                texel_bytes = 4;
            uint64_t budget = args.target == 0 ? args.width :
                (uint64_t)args.width * args.height * args.depth * args.array_size * texel_bytes *
                (args.last_level ? 2 : 1) * (args.nr_samples ? args.nr_samples : 1);
            if (budget < 65536) budget = 65536;
            if (budget > resource_limit || !grow_pool(total_resource_bytes + budget, &gpu_limit, ram_ceiling, 4294967296ULL)) {
                os_log_error(OS_LOG_DEFAULT, "GPU resource budget exceeded id=%u format=%u size=%ux%u estimate=%llu live=%llu", id, args.format, args.width, args.height, (unsigned long long)budget, (unsigned long long)total_resource_bytes);
                result = 0x1201; break;
            }
            if (virgl_renderer_resource_create(&args, NULL, 0)) { result = 0x1200; break; }
            resources[slot] = id; resource_bytes[slot] = budget;
            total_resource_bytes += budget;
            if (total_resource_bytes > peak_resource_bytes) peak_resource_bytes = total_resource_bytes;
            result = 0x1100;
            break;
        }
        case 0x102: // RESOURCE_UNREF
        case 0x202: // CTX_ATTACH_RESOURCE
        case 0x203: { // CTX_DETACH_RESOURCE
            if (length != 32) break;
            uint32_t id = load32(request + 24);
            int slot = -1, has_context = 0;
            for (int i = 0; i < MAX_RESOURCES; ++i) if (resources[i] == id && id) slot = i;
            if (slot < 0) { result = 0x1203; break; }
            if (type == 0x102) {
                virgl_renderer_resource_unref(id); resources[slot] = 0;
                total_resource_bytes -= resource_bytes[slot]; resource_bytes[slot] = 0;
                total_backing -= backing[slot].iov_len;
                free(backing[slot].iov_base); backing[slot] = (struct iovec){0};
                for (uint32_t i = 0; i < scanout_count; ++i)
                    if (scanouts[i].resource == id) scanouts[i].resource = 0;
            } else {
                for (int i = 0; i < MAX_CONTEXTS; ++i) if (contexts[i] == context && context) has_context = 1;
                if (!has_context) { result = 0x1204; break; }
                if (type == 0x202) virgl_renderer_ctx_attach_resource(context, id);
                else virgl_renderer_ctx_detach_resource(context, id);
            }
            result = 0x1100; break;
        }
        case 0x207: { // SUBMIT_3D: snapshot is aligned and immutable during decode.
            if (length < 32 || load32(request + 24) != length - 32 || (length - 32) % 4) break;
            int has_context = 0;
            for (int i = 0; i < MAX_CONTEXTS; ++i) if (contexts[i] == context && context) has_context = 1;
            if (!has_context) { result = 0x1204; break; }
            result = virgl_renderer_submit_cmd(request + 32, context, (length - 32) / 4) ? 0x1200 : 0x1100;
            break;
        }
        case 0x105: // TRANSFER_TO_HOST_2D
        case 0x205: // TRANSFER_TO_HOST_3D
        case 0x206: { // TRANSFER_FROM_HOST_3D: explicit guest readback, never scanout.
            if (length != (type == 0x105 ? 56u : 72u)) break;
            uint32_t id = load32(request + (type == 0x105 ? 48 : 56));
            int slot = -1;
            for (int i = 0; i < MAX_RESOURCES; ++i) if (id && resources[i] == id) slot = i;
            if (slot < 0 || !backing[slot].iov_base) { result = 0x1203; break; }
            struct virgl_box box = {load32(request + 24), load32(request + 28), load32(request + 32),
                load32(request + 36), load32(request + 40), load32(request + 44)};
            uint64_t offset = type == 0x105 ? 0 : load64(request + 48);
            uint32_t level = type == 0x105 ? 0 : load32(request + 60);
            uint32_t stride = type == 0x105 ? 0 : load32(request + 64);
            uint32_t layer_stride = type == 0x105 ? 0 : load32(request + 68);
            if (type == 0x105) {
                box = (struct virgl_box){load32(request + 24), load32(request + 28), 0,
                    load32(request + 32), load32(request + 36), 1};
                offset = load64(request + 40); level = 0; stride = 0; layer_stride = 0;
            }
            if (offset >= backing[slot].iov_len) break;
            int error = type != 0x206 ?
                virgl_renderer_transfer_write_iov(id, context, level, stride, layer_stride, &box, offset, NULL, 0) :
                virgl_renderer_transfer_read_iov(id, context, level, stride, layer_stride, &box, offset, NULL, 0);
            result = error ? 0x1205 : 0x1100; break;
        }
        case 0x103: // SET_SCANOUT
        case 0x104: { // RESOURCE_FLUSH
            if (length != 48) break;
            uint32_t id = load32(request + (type == 0x103 ? 44 : 40));
            uint32_t output = type == 0x103 ? load32(request + 40) : 0;
            if (output >= scanout_count) { result = 0x1202; break; }
            struct scanout_state *s = &scanouts[output];
            if (type == 0x103 && !id) { s->resource = 0; result = 0x1100; break; }
            struct virgl_renderer_resource_info_ext info = {0};
            if (!id || virgl_renderer_resource_get_info_ext(id, &info)) { result = 0x1203; break; }
            uint32_t x = load32(request + 24), y = load32(request + 28);
            uint32_t width = load32(request + 32), height = load32(request + 36);
            if (x > info.base.width || y > info.base.height || width > info.base.width - x ||
                height > info.base.height - y || !width || !height) break;
            if (type == 0x103) {
                s->resource = id;
                s->x = x; s->y = y;
                s->width = width; s->height = height;
            }
            // SET_SCANOUT binds the framebuffer; RESOURCE_FLUSH publishes its contents.
            // Publishing on SET exposes the modesetting buffer before guest repaint.
            if (type == 0x104 && s->enabled && id == s->resource) {
                if (++fence_token == 0) ++fence_token;
                if (!wait_for_gpu(fence_token, 0)) return 1;
                if (info.native_type != VIRGL_NATIVE_HANDLE_METAL_TEXTURE || !info.native_handle ||
                    !renderer_capture_surface_region(info.native_handle, s->x, s->y, s->width, s->height)) { result = 0x1200; break; }

            }
            result = 0x1100; break;
        }
        case 0x107: { // RESOURCE_DETACH_BACKING
            if (length != 32) break;
            uint32_t id = load32(request + 24);
            int slot = -1;
            for (int i = 0; i < MAX_RESOURCES; ++i) if (id && resources[i] == id) slot = i;
            if (slot < 0) { result = 0x1203; break; }
            virgl_renderer_resource_detach_iov(id, NULL, NULL);
            total_backing -= backing[slot].iov_len;
            free(backing[slot].iov_base); backing[slot] = (struct iovec){0};
            result = 0x1100; break;
        }
        case 0xffff0010: // Host-sanitized backing allocation: no guest addresses.
            // GPU storage and CPU staging each have a separate resolution-aware ceiling.
        case 0xffff0011: // Host-snapshotted backing upload.
        case 0xffff0012: { // Explicit readback chunk for guest API requests.
            if (length < 40 || flags || context) break;
            uint32_t id = load32(request + 24), count = load32(request + 36);
            uint64_t offset = load64(request + 28);
            int slot = -1;
            for (int i = 0; i < MAX_RESOURCES; ++i) if (id && resources[i] == id) slot = i;
            if (slot < 0) { result = 0x1203; break; }
            if (type == 0xffff0010) {
                if (length != 40 || count || !offset || offset > 134217728 || backing[slot].iov_base ||
                    !grow_pool(total_backing + offset, &staging_limit, ram_ceiling, 2147483648ULL)) break;
                backing[slot].iov_base = calloc(1, (size_t)offset);
                if (!backing[slot].iov_base) { result = 0x1201; break; }
                backing[slot].iov_len = (size_t)offset;
                if (virgl_renderer_resource_attach_iov(id, &backing[slot], 1)) {
                    free(backing[slot].iov_base); backing[slot] = (struct iovec){0}; break;
                }
                total_backing += offset;
                if (total_backing > peak_backing_bytes) peak_backing_bytes = total_backing;
            } else {
                if (!backing[slot].iov_base || !count || offset > backing[slot].iov_len ||
                    count > backing[slot].iov_len - offset) break;
                if (type == 0xffff0011) {
                    if (count != length - 40) break;
                    memcpy((uint8_t *)backing[slot].iov_base + offset, request + 40, count);
                } else {
                    if (length != 40 || count > MAX_FRAME - 24) break;
                    memcpy(response + 24, (uint8_t *)backing[slot].iov_base + offset, count);
                    response_length += count;
                }
            }
            result = 0x1100; break;
        }
        case 0xffff0001: // Host-only reset, blocked from guest forwarding.
            if (length != 24 || flags || context) break;
            virgl_renderer_reset(); memset(contexts, 0, sizeof(contexts));
            for (int i = 0; i < MAX_RESOURCES; ++i) free(backing[i].iov_base);
            memset(backing, 0, sizeof(backing)); total_backing = 0;
            memset(resources, 0, sizeof(resources)); memset(resource_bytes, 0, sizeof(resource_bytes));
            total_resource_bytes = 0; result = 0x1100;
            for (uint32_t i = 0; i < scanout_count; ++i) scanouts[i].resource = 0;
            break;
        case 0xffff0002: { // Trusted test only: verify a red 64x64 native texture.
            if (length != 32 || flags || context) break;
            uint32_t id = load32(request + 24);
            struct virgl_renderer_resource_info_ext info = {0};
            if (virgl_renderer_resource_get_info_ext(id, &info) ||
                info.native_type != VIRGL_NATIVE_HANDLE_METAL_TEXTURE || !info.native_handle ||
                info.base.width != 64 || info.base.height != 64) break;
            result = probe_shared_texture(info.native_handle) ? 0x1100 : 0x1200;
            break;
        }
        case 0xffff0003: { // Trusted host-side export; no guest-supplied native handles.
            if (length != 32 || flags || context) break;
            struct virgl_renderer_resource_info_ext info = {0};
            if (virgl_renderer_resource_get_info_ext(load32(request + 24), &info) ||
                info.native_type != VIRGL_NATIVE_HANDLE_METAL_TEXTURE || !info.native_handle) break;
            result = renderer_capture_surface(info.native_handle) ? 0x1100 : 0x1200;
            break;
        }
        case 0xffff0020: // Legacy primary geometry.
        case 0xffff0022: { // Trusted composite root budget; does not alter connectors.
            if (length != 32 || flags || context) break;
            uint32_t width = load32(request + 24), height = load32(request + 28);
            uint64_t maximum_pixels = type == 0xffff0022 ? 67108864 : 33554432;
            if (!width || !height || width > 8192 || height > 8192 || (uint64_t)width * height > maximum_pixels) break;
            uint64_t pixels = (uint64_t)width * height, quantum = 268435456;
            uint64_t wanted_gpu = (pixels * 64 + quantum - 1) / quantum * quantum;
            uint64_t wanted_staging = (pixels * 48 + quantum - 1) / quantum * quantum;
            if (wanted_gpu > 4294967296ULL) wanted_gpu = 4294967296ULL;
            if (wanted_staging > 2147483648ULL) wanted_staging = 2147483648ULL;
            if (wanted_gpu > ram_ceiling) wanted_gpu = ram_ceiling;
            if (wanted_staging > ram_ceiling) wanted_staging = ram_ceiling;
            // Preserve capacity while shrinking; resources release naturally.
            if (wanted_gpu > gpu_limit) gpu_limit = wanted_gpu;
            if (wanted_staging > staging_limit) staging_limit = wanted_staging;
            if (pixels > 16777216 && resource_limit < 536870912) resource_limit = 536870912;
            if (type == 0xffff0022 && pixels > 33554432) {
                resource_limit = 1073741824;
                if (pixels > texture_pixel_limit) texture_pixel_limit = pixels;
            }
            if (type == 0xffff0020) {
                scanouts[0].display_width = width; scanouts[0].display_height = height;
                scanouts[0].enabled = 1;
            }
            result = 0x1100;
            break;
        }
        case 0xffff0021: { // Host-only scanout count, fixed before resources/VM boot.
            if (length != 28 || flags || context) break;
            uint32_t count = load32(request + 24);
            if (!count || count > 16 || total_resource_bytes || total_backing) break;
            for (uint32_t i = 0; i < scanout_count; ++i) if (scanouts[i].resource) goto reply;
            if (count < scanout_count) memset(scanouts + count, 0, (16 - count) * sizeof(scanouts[0]));
            scanout_count = count; result = 0x1100; break;
        }
        case 0xffff0023: { // Host-only snapshot of one bound scanout; no guest native handles.
            if (length != 28 || flags || context) break;
            uint32_t index = load32(request + 24);
            if (index >= scanout_count) { result = 0x1202; break; }
            struct scanout_state *s = &scanouts[index];
            if (!s->enabled || !s->resource) { result = 0x1100; break; }
            struct virgl_renderer_resource_info_ext info = {0};
            if (virgl_renderer_resource_get_info_ext(s->resource, &info)) { result = 0x1203; break; }
            if (s->x > info.base.width || s->y > info.base.height || !s->width || !s->height ||
                s->width > info.base.width - s->x || s->height > info.base.height - s->y) break;
            if (++fence_token == 0) ++fence_token;
            if (!wait_for_gpu(fence_token, 0)) return 1;
            result = info.native_type == VIRGL_NATIVE_HANDLE_METAL_TEXTURE && info.native_handle &&
                renderer_capture_surface_region(info.native_handle, s->x, s->y, s->width, s->height)
                ? 0x1100 : 0x1200;
            break;
        }
        case 0xffff0024: { // Host-only preferred output geometry. Budget is set by root geometry (0020).
            if (length != 48 || flags || context) break;
            uint32_t index = load32(request + 24), width = load32(request + 28), height = load32(request + 32);
            uint32_t enabled = load32(request + 36), x = load32(request + 40), y = load32(request + 44);
            if (index >= scanout_count) { result = 0x1202; break; }
            if (enabled > 1 || !width || !height || width > 8192 || height > 8192 ||
                x > 8192 - width || y > 8192 - height || (uint64_t)width * height > 33554432) break;
            uint32_t root_width = enabled ? x + width : 0, root_height = enabled ? y + height : 0;
            for (uint32_t i = 0; i < scanout_count; ++i) if (i != index && scanouts[i].enabled) {
                uint32_t right = scanouts[i].display_x + scanouts[i].display_width;
                uint32_t bottom = scanouts[i].display_y + scanouts[i].display_height;
                if (right > root_width) root_width = right;
                if (bottom > root_height) root_height = bottom;
            }
            if ((uint64_t)root_width * root_height > texture_pixel_limit) break;
            struct scanout_state *s = &scanouts[index];
            s->display_x = x; s->display_y = y; s->display_width = width; s->display_height = height;
            s->enabled = enabled;
            result = 0x1100; break;
        }
        case 0xffff0030: { // Host-only diagnostics, excluded from guest allowlist.
            if (length != 24 || flags || context) break;
            uint32_t live_resources = 0, live_contexts = 0;
            for (int i = 0; i < MAX_RESOURCES; ++i) if (resources[i]) ++live_resources;
            for (int i = 0; i < MAX_CONTEXTS; ++i) if (contexts[i]) ++live_contexts;
            store32(response + 24, live_resources);
            store32(response + 28, live_contexts);
            store32(response + 32, (uint32_t)total_resource_bytes);
            store32(response + 36, (uint32_t)(total_resource_bytes >> 32));
            store32(response + 40, (uint32_t)total_backing);
            store32(response + 44, (uint32_t)(total_backing >> 32));
            store32(response + 48, (uint32_t)peak_resource_bytes);
            store32(response + 52, (uint32_t)(peak_resource_bytes >> 32));
            store32(response + 56, (uint32_t)peak_backing_bytes);
            store32(response + 60, (uint32_t)(peak_backing_bytes >> 32));
            store32(response + 64, (uint32_t)gpu_limit);
            store32(response + 68, (uint32_t)(gpu_limit >> 32));
            store32(response + 72, (uint32_t)staging_limit);
            store32(response + 76, (uint32_t)(staging_limit >> 32));
            store32(response + 80, (uint32_t)resource_limit);
            store32(response + 84, (uint32_t)(resource_limit >> 32));
            response_length = 88; result = 0x1100;
            break;
        }
        default:
            result = 0x1200;
        }
reply:
        // This standalone worker waits on its own rendering thread. The app
        // transport must dispatch asynchronously and retain queue elements
        // until this completion; never claim a GPU fence on submission alone.
        if (result == 0x1100 && (flags & 1u)) {
            if (++fence_token == 0) ++fence_token;
            if (!wait_for_gpu(fence_token, context)) return 1;
        }
        GLenum command_error = glGetError();
        if (command_error) {
            os_log_error(OS_LOG_DEFAULT, "GPU command GL error type=%u ctx=%u error=%x", type, context, command_error);
            if (result >= 0x1100 && result < 0x1200) result = 0x1200;
        }
        store32(response, result);
        uint32_t wire_length = response_length;
#ifdef BROMURE_RENDERER_XPC
        extern int renderer_worker_publish_surface(void);
        int exported = renderer_worker_publish_surface();
        if (exported < 0) return 1;
        if (exported) wire_length |= 0x80000000u;
#endif
        store32(prefix, wire_length);
        if (!write_exact(output_fd, prefix, 4) || !write_exact(output_fd, response, response_length)) return 1;
    }
}
