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

enum { MAX_FRAME = 65536, MAX_CONTEXTS = 32 };
enum { MAX_RESOURCES = 256 };
extern int probe_shared_texture(void *native_texture);
extern int renderer_capture_surface(void *native_texture);
static uint32_t retired_fence;
void renderer_worker_fence(uint32_t fence) { retired_fence = fence; }
static int wait_for_gpu(uint32_t token, uint32_t context)
{
    if (virgl_renderer_create_fence((int)token, context)) return 0;
    struct timespec start, now, interval = {0, 1000000};
    clock_gettime(CLOCK_MONOTONIC, &start);
    do {
        virgl_renderer_poll();
        if (retired_fence == token) return 1;
        nanosleep(&interval, NULL);
        clock_gettime(CLOCK_MONOTONIC, &now);
    } while (now.tv_sec - start.tv_sec < 5);
    return 0;
}
static uint32_t load32(const uint8_t *p)
{ return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static void store32(uint8_t *p, uint32_t value)
{ for (unsigned i = 0; i < 4; ++i) p[i] = (uint8_t)(value >> (i * 8)); }
static uint64_t load64(const uint8_t *p) { return load32(p) | (uint64_t)load32(p + 4) << 32; }

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
    struct iovec backing[MAX_RESOURCES] = {0};
    uint64_t total_backing = 0;
    uint32_t display_width = 0, display_height = 0, scanout_resource = 0;
    _Alignas(8) uint8_t request[MAX_FRAME], response[MAX_FRAME];
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
        if (length < 24 || length > MAX_FRAME || read_exact(STDIN_FILENO, request, length) != 1) return 1;
        uint32_t type = load32(request), flags = load32(request + 4), context = load32(request + 16);
        uint32_t result = 0x1205, response_length = 24;
        memset(response, 0, sizeof(response));
        // No multiple timelines/context-init feature is advertised.
        if (flags & ~1u) goto reply;
        store32(response + 4, flags);
        if (flags & 1u) memcpy(response + 8, request + 8, 8);
        store32(response + 16, context);
        switch (type) {
        case 0x100: // GET_DISPLAY_INFO: geometry is configured by the host before VM boot.
            if (length != 24) break;
            response_length = 24 + 384;
            if (display_width) {
                store32(response + 32, display_width); store32(response + 36, display_height);
                store32(response + 40, 1);
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
            if (slot < 0) { result = 0x1201; break; }
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
            uint32_t max_width = args.target == 0 ? 16777216 : 8192;
            if (!args.width || args.width > max_width || !args.height || args.height > 8192 ||
                !args.depth || args.depth > 256 || !args.array_size || args.array_size > 256 ||
                args.last_level > 13 || args.nr_samples > 8 || args.flags & ~1u ||
                (uint64_t)args.width * args.height * args.depth * args.array_size > 16777216) break;
            // Account common browser formats by storage size. A worst-case
            // fallback bounds other formats; only mipmapped resources double.
            uint32_t texel_bytes = 32;
            if ((args.format >= 1 && args.format <= 8) ||
                (args.format >= 99 && args.format <= 104) ||
                args.format == VIRGL_FORMAT_R8G8B8A8_UNORM || args.format == VIRGL_FORMAT_A8B8G8R8_UNORM)
                texel_bytes = 4;
            else if (args.format == VIRGL_FORMAT_R8_UNORM) texel_bytes = 1;
            else if (args.format == VIRGL_FORMAT_R8G8_UNORM) texel_bytes = 2;
            uint64_t budget = args.target == 0 ? args.width :
                (uint64_t)args.width * args.height * args.depth * args.array_size * texel_bytes *
                (args.last_level ? 2 : 1) * (args.nr_samples ? args.nr_samples : 1);
            if (budget < 65536) budget = 65536;
            if (budget > 268435456 || total_resource_bytes + budget > 1073741824) {
                result = 0x1201; break;
            }
            if (virgl_renderer_resource_create(&args, NULL, 0)) { result = 0x1200; break; }
            resources[slot] = id; resource_bytes[slot] = budget;
            total_resource_bytes += budget; result = 0x1100;
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
                if (scanout_resource == id) scanout_resource = 0;
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
            if (type == 0x103 && load32(request + 40)) { result = 0x1202; break; }
            if (type == 0x103 && !id) { scanout_resource = 0; result = 0x1100; break; }
            struct virgl_renderer_resource_info_ext info = {0};
            if (!id || virgl_renderer_resource_get_info_ext(id, &info)) { result = 0x1203; break; }
            uint32_t x = load32(request + 24), y = load32(request + 28);
            uint32_t width = load32(request + 32), height = load32(request + 36);
            if (x > info.base.width || y > info.base.height || width > info.base.width - x ||
                height > info.base.height - y || !width || !height) break;
            if (type == 0x103) {
                // Cropped resources need a separate blit region contract.
                if (x || y || width != info.base.width || height != info.base.height) break;
                scanout_resource = id;
            }
            if (id == scanout_resource) {
                if (++fence_token == 0) ++fence_token;
                if (!wait_for_gpu(fence_token, 0)) return 1;
                if (info.native_type != VIRGL_NATIVE_HANDLE_METAL_TEXTURE || !info.native_handle ||
                    !renderer_capture_surface(info.native_handle)) { result = 0x1200; break; }
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
                    total_backing + offset > 268435456) break;
                backing[slot].iov_base = calloc(1, (size_t)offset);
                if (!backing[slot].iov_base) { result = 0x1201; break; }
                backing[slot].iov_len = (size_t)offset;
                if (virgl_renderer_resource_attach_iov(id, &backing[slot], 1)) {
                    free(backing[slot].iov_base); backing[slot] = (struct iovec){0}; break;
                }
                total_backing += offset;
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
            scanout_resource = 0;
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
        case 0xffff0020: { // Host-only initial display geometry.
            if (length != 32 || flags || context) break;
            uint32_t width = load32(request + 24), height = load32(request + 28);
            if (!width || !height || width > 8192 || height > 8192 || (uint64_t)width * height > 16777216) break;
            if (total_resource_bytes) break;
            display_width = width; display_height = height; result = 0x1100;
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
        store32(prefix, response_length);
        if (!write_exact(output_fd, prefix, 4) || !write_exact(output_fd, response, response_length)) return 1;
    }
}
