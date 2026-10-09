// Hardware H.264 decode for the isolated macOS VirGL renderer.
// Guest addresses never enter this backend; compressed data and descriptors
// have already been copied into renderer-owned resources.
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <os/log.h>
#include "virgl_video.h"
#include "virgl_video_hw.h"
#include "virgl_hw.h"
#include "virgl_util.h"
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <time.h>

#define VIDEO_MAX_BYTES (8u * 1024u * 1024u)
#define VIDEO_MAX_DIMENSION 4096u
struct virgl_video_codec {
    struct virgl_video_create_codec_args args;
    VTDecompressionSessionRef session;
    CMVideoFormatDescriptionRef format;
    unsigned char parameters[8192];
    size_t parameters_length;
    OSStatus error;
    uint32_t diagnostic_id;
    unsigned frame_count;
};
struct virgl_video_buffer {
    struct virgl_video_create_buffer_args args;
    CVPixelBufferRef image;
    uint32_t id;
    uint64_t reserved_bytes;
};
static struct virgl_video_callbacks callbacks;
static unsigned codec_count, buffer_count;
static uint64_t video_buffer_bytes;
// Charge every live buffer before a decoded image exists. Two bytes per pixel,
// with padded rows/heights, conservatively cover the retained NV12 image.
static uint64_t video_buffer_reservation(unsigned width, unsigned height) {
    return (((uint64_t)width + 255) & ~UINT64_C(255)) *
           (((uint64_t)height + 15) & ~UINT64_C(15)) * 2;
}
static uint64_t video_buffer_budget(void) {
    uint64_t budget = [[NSProcessInfo processInfo] physicalMemory] / 32;
    if (budget < (UINT64_C(128) << 20)) budget = UINT64_C(128) << 20;
    if (budget > (UINT64_C(512) << 20)) budget = UINT64_C(512) << 20;
    return budget;
}
static uint32_t next_buffer_id;
static unsigned decoded_frames;
static uint32_t next_codec_id;
static double video_milliseconds(void) {
    struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec * 1000.0 + now.tv_nsec / 1000000.0;
}
static id<MTLComputePipelineState> split_pipeline;
static id<MTLCommandQueue> video_queue;
static unsigned planar_copies;
static unsigned plane_copies;
// Renderer commands are serialized. Reuse the queue while preserving the
// completion wait before guest texture consumers can run.
static id<MTLCommandQueue> retained_video_queue(id<MTLDevice> device) {
    if (video_queue && video_queue.device != device) { [video_queue release]; video_queue = nil; }
    if (!video_queue) video_queue = [device newCommandQueue];
    return [video_queue retain];
}
static bool initialized;
static bool supported(enum pipe_video_profile profile) {
    return profile == PIPE_VIDEO_PROFILE_MPEG4_AVC_BASELINE ||
           profile == PIPE_VIDEO_PROFILE_MPEG4_AVC_CONSTRAINED_BASELINE ||
           profile == PIPE_VIDEO_PROFILE_MPEG4_AVC_MAIN ||
           profile == PIPE_VIDEO_PROFILE_MPEG4_AVC_HIGH;
}

// Finite RBSP encoder. All guest-derived variable-length integers are bounded
// before encoding; a failed writer cannot silently produce parameter sets.
struct bits { uint8_t data[4096]; size_t pos; bool failed; };
static void bit(struct bits *b, unsigned value) {
    if (b->pos >= sizeof(b->data) * 8) { b->failed = true; return; }
    if (value & 1) b->data[b->pos / 8] |= 1u << (7 - b->pos % 8);
    ++b->pos;
}
static void fixed(struct bits *b, uint32_t value, unsigned count) {
    for (unsigned i = count; i; --i) bit(b, value >> (i - 1));
}
static void ue(struct bits *b, uint32_t value) {
    if (value == UINT32_MAX) { b->failed = true; return; }
    uint32_t code = value + 1; unsigned count = 0;
    for (uint32_t n = code; n > 1; n >>= 1) ++count;
    for (unsigned i = 0; i < count; ++i) bit(b, 0);
    fixed(b, code, count + 1);
}
static void se(struct bits *b, int32_t value) {
    if (value < -32767 || value > 32767) { b->failed = true; return; }
    ue(b, value <= 0 ? (uint32_t)(-value * 2) : (uint32_t)(value * 2 - 1));
}
static size_t finish_nal(struct bits *b, uint8_t header, uint8_t *out, size_t capacity) {
    bit(b, 1); while (b->pos % 8) bit(b, 0);
    if (b->failed || !capacity) return 0;
    size_t length = 1; unsigned zeros = 0; out[0] = header;
    for (size_t i = 0; i < b->pos / 8; ++i) {
        uint8_t value = b->data[i];
        if (zeros == 2 && value <= 3) {
            if (length >= capacity) return 0;
            out[length++] = 3; zeros = 0;
        }
        if (length >= capacity) return 0;
        out[length++] = value; zeros = value ? 0 : zeros + 1;
    }
    return length;
}
struct reader { uint8_t bytes[128]; size_t length, pos; bool failed; };
static unsigned readbit(struct reader *r) {
    if (r->pos >= r->length * 8) { r->failed = true; return 0; }
    unsigned result = (r->bytes[r->pos / 8] >> (7 - r->pos % 8)) & 1;
    ++r->pos; return result;
}
static uint32_t readue(struct reader *r) {
    unsigned count = 0;
    while (!readbit(r) && !r->failed) if (++count > 16) { r->failed = true; break; }
    uint32_t value = 1;
    for (unsigned i = 0; i < count; ++i) value = (value << 1) | readbit(r);
    return value - 1;
}
static bool slice_pps_id(const uint8_t *nal, size_t length, uint32_t *id) {
    struct reader r = {0}; unsigned zeros = 0;
    for (size_t i = 1; i < length && r.length < sizeof(r.bytes); ++i) {
        uint8_t v = nal[i];
        if (zeros == 2 && v == 3) { zeros = 0; continue; }
        r.bytes[r.length++] = v; zeros = v ? 0 : zeros + 1;
    }
    (void)readue(&r); (void)readue(&r); *id = readue(&r);
    return !r.failed && *id <= 255;
}
// VA/Gallium IQ matrices use raster order; H.264 writes diagonal scan order.
static bool scaling_list(struct bits *b, const uint8_t *values, unsigned width, bool required) {
    unsigned count = width * width; bool empty = true;
    for (unsigned i = 0; i < count; ++i) if (values[i]) empty = false;
    if (empty && required) return false;
    bit(b, 1); int last = 8;
    for (unsigned diagonal = 0; diagonal < 2 * width - 1; ++diagonal) {
        unsigned low = diagonal >= width ? diagonal - width + 1 : 0;
        unsigned high = diagonal < width ? diagonal : width - 1;
        for (unsigned n = low; n <= high; ++n) {
            unsigned row = diagonal & 1 ? n : high - (n - low);
            unsigned col = diagonal - row;
            int value = empty ? 16 : values[row * width + col];
            if (!value) return false;
            int delta = ((value - last + 128) & 255) - 128;
            se(b, delta); last = value;
        }
    }
    return !b->failed;
}
static bool build_parameters(struct virgl_video_codec *c,
                              const struct virgl_h264_picture_desc *d, uint32_t pps_id,
                              uint8_t *sps, size_t *sps_size, uint8_t *pps, size_t *pps_size) {
    const struct virgl_h264_sps *s = &d->pps.sps;
    const struct virgl_h264_pps *p = &d->pps;
    if (s->chroma_format_idc != 1 || s->bit_depth_luma_minus8 || s->bit_depth_chroma_minus8 ||
        !s->frame_mbs_only_flag || s->separate_colour_plane_flag ||
        s->pic_order_cnt_type > 2 || s->log2_max_frame_num_minus4 > 12 ||
        s->log2_max_pic_order_cnt_lsb_minus4 > 12 || s->max_num_ref_frames > 16 || d->num_ref_frames > 16 ||
        d->num_ref_idx_l0_active_minus1 > 31 || d->num_ref_idx_l1_active_minus1 > 31 ||
        p->num_slice_groups_minus1 || p->weighted_bipred_idc > 2 ||
        p->num_ref_idx_l0_default_active_minus1 > 31 || p->num_ref_idx_l1_default_active_minus1 > 31)
        return false;
    unsigned profile = c->args.profile == PIPE_VIDEO_PROFILE_MPEG4_AVC_HIGH ? 100 :
                       c->args.profile == PIPE_VIDEO_PROFILE_MPEG4_AVC_MAIN ? 77 : 66;
    struct bits b = {0}; fixed(&b, profile, 8); fixed(&b, c->args.profile == PIPE_VIDEO_PROFILE_MPEG4_AVC_CONSTRAINED_BASELINE ? 0xc0 : 0, 8);
    fixed(&b, s->level_idc ? s->level_idc : 51, 8); ue(&b, 0);
    if (profile == 100) { ue(&b, 1); ue(&b, 0); ue(&b, 0); bit(&b, 0); bit(&b, 0); }
    ue(&b, s->log2_max_frame_num_minus4); ue(&b, s->pic_order_cnt_type);
    if (!s->pic_order_cnt_type) ue(&b, s->log2_max_pic_order_cnt_lsb_minus4);
    else if (s->pic_order_cnt_type == 1) {
        bit(&b, s->delta_pic_order_always_zero_flag); se(&b, s->offset_for_non_ref_pic);
        se(&b, s->offset_for_top_to_bottom_field); ue(&b, s->num_ref_frames_in_pic_order_cnt_cycle);
        for (unsigned i = 0; i < s->num_ref_frames_in_pic_order_cnt_cycle; ++i) se(&b, s->offset_for_ref_frame[i]);
    }
    ue(&b, d->num_ref_frames ? d->num_ref_frames : s->max_num_ref_frames); bit(&b, 0);
    unsigned mbw = (c->args.width + 15) / 16, mbh = (c->args.height + 15) / 16;
    ue(&b, mbw - 1); ue(&b, mbh - 1); bit(&b, 1); bit(&b, s->direct_8x8_inference_flag);
    unsigned right = mbw * 16 - c->args.width, bottom = mbh * 16 - c->args.height;
    bit(&b, right || bottom);
    if (right || bottom) { ue(&b, 0); ue(&b, right / 2); ue(&b, 0); ue(&b, bottom / 2); }
    bit(&b, 0); *sps_size = finish_nal(&b, 0x67, sps, 4096);
    memset(&b, 0, sizeof(b)); ue(&b, pps_id); ue(&b, 0);
    bit(&b, p->entropy_coding_mode_flag); bit(&b, p->bottom_field_pic_order_in_frame_present_flag);
    // VAAPI supplies effective slice reference counts rather than PPS defaults.
    ue(&b, 0); ue(&b, d->num_ref_idx_l0_active_minus1); ue(&b, d->num_ref_idx_l1_active_minus1);
    bit(&b, p->weighted_pred_flag); fixed(&b, p->weighted_bipred_idc, 2);
    se(&b, p->pic_init_qp_minus26); se(&b, p->pic_init_qs_minus26); se(&b, p->chroma_qp_index_offset);
    bit(&b, p->deblocking_filter_control_present_flag); bit(&b, p->constrained_intra_pred_flag);
    bit(&b, p->redundant_pic_cnt_present_flag);
    if (profile == 100) {
        bit(&b, p->transform_8x8_mode_flag); bit(&b, 1);
        for (unsigned i = 0; i < 6; ++i)
            if (!scaling_list(&b, p->ScalingList4x4[i], 4, s->seq_scaling_matrix_present_flag)) return false;
        if (p->transform_8x8_mode_flag)
            for (unsigned i = 0; i < 2; ++i)
                if (!scaling_list(&b, p->ScalingList8x8[i], 8, s->seq_scaling_matrix_present_flag)) return false;
        se(&b, p->second_chroma_qp_index_offset);
    }
    *pps_size = finish_nal(&b, 0x68, pps, 4096);
    return *sps_size && *pps_size;
}
static void decoded(void *cookie, void *frame, OSStatus status, VTDecodeInfoFlags flags,
                     CVImageBufferRef image, CMTime time, CMTime duration) {
    (void)flags; (void)time; (void)duration;
    struct virgl_video_codec *c = cookie; struct virgl_video_buffer *b = frame;
    if (status || !image || !b) { c->error = status ? status : -1; return; }
    if (CVPixelBufferGetWidth(image) != b->args.width || CVPixelBufferGetHeight(image) != b->args.height ||
        CVPixelBufferGetPixelFormatType(image) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        !CVPixelBufferGetIOSurface(image)) { c->error = -1; return; }
    size_t actual_bytes = IOSurfaceGetAllocSize(CVPixelBufferGetIOSurface(image));
    if (!actual_bytes || actual_bytes > b->reserved_bytes) {
        os_log_error(OS_LOG_DEFAULT, "VideoToolbox decoded surface exceeds buffer reservation codec=%u", c->diagnostic_id);
        c->error = -1; return;
    }
    if (b->image) CVPixelBufferRelease(b->image);
    b->image = CVPixelBufferRetain(image);
}
static bool configure(struct virgl_video_codec *c, const uint8_t *sps, size_t ns,
                       const uint8_t *pps, size_t np) {
    double started = video_milliseconds();
    if (!ns || !np || ns + np > sizeof(c->parameters) - 8) return false;
    uint8_t key[8192]; uint32_t sizes[2] = {(uint32_t)ns, (uint32_t)np};
    memcpy(key, sizes, 8); memcpy(key + 8, sps, ns); memcpy(key + 8 + ns, pps, np);
    size_t length = 8 + ns + np;
    if (c->session && c->parameters_length == length && !memcmp(c->parameters, key, length)) return true;
    CMVideoFormatDescriptionRef format = NULL; const uint8_t *sets[2] = {sps, pps}; size_t lengths[2] = {ns, np};
    OSStatus format_status = CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, 2, sets, lengths, 4, &format);
    if (format_status) { c->error = format_status; return false; }
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(format);
    if (dims.width != (int)c->args.width || dims.height != (int)c->args.height) { os_log(OS_LOG_DEFAULT, "VideoToolbox format dimensions %dx%d expected %ux%u",dims.width,dims.height,c->args.width,c->args.height); CFRelease(format); return false; }
    if (c->session && VTDecompressionSessionCanAcceptFormatDescription(c->session, format)) {
        // Preserve the decoded-picture buffer when effective PPS counts change.
        if (c->format) CFRelease(c->format); c->format = format;
        memcpy(c->parameters, key, length); c->parameters_length = length;
        return true;
    }
    if (c->session) { VTDecompressionSessionInvalidate(c->session); CFRelease(c->session); c->session = NULL; }
    if (c->format) CFRelease(c->format); c->format = format;
    @autoreleasepool {
        NSDictionary *spec = @{(id)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: @YES};
        NSDictionary *attrs = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES};
        VTDecompressionOutputCallbackRecord cb = {decoded, c};
        OSStatus create_status = VTDecompressionSessionCreate(NULL, format, (CFDictionaryRef)spec, (CFDictionaryRef)attrs, &cb, &c->session);
        if (create_status) {
            c->error = create_status;
            os_log_error(OS_LOG_DEFAULT, "VideoToolbox session create failed codec=%u status=%d liveCodecs=%u liveBuffers=%u ms=%.3f",
                         c->diagnostic_id, (int)create_status, codec_count, buffer_count, video_milliseconds() - started);
            return false;
        }
    }
    CFTypeRef hardware = NULL;
    OSStatus status = VTSessionCopyProperty(c->session, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, NULL, &hardware);
    bool available = !status && hardware == kCFBooleanTrue;
    if (hardware) CFRelease(hardware);
    if (!available) { VTDecompressionSessionInvalidate(c->session); CFRelease(c->session); c->session = NULL; return false; }
    memcpy(c->parameters, key, length); c->parameters_length = length;
    os_log(OS_LOG_DEFAULT, "VideoToolbox hardware H.264 decoder active (%ux%u) codec=%u setupMs=%.3f liveCodecs=%u liveBuffers=%u", c->args.width, c->args.height, c->diagnostic_id, video_milliseconds() - started, codec_count, buffer_count);
    return true;
}

int virgl_video_init(int drm_fd, struct virgl_video_callbacks *cbs, unsigned flags) {
    (void)drm_fd; (void)flags;
    if (!cbs || !VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)) return -1;
    callbacks = *cbs; initialized = true; return 0;
}
void virgl_video_destroy(void) { initialized = false; memset(&callbacks, 0, sizeof(callbacks)); [split_pipeline release]; split_pipeline = nil; [video_queue release]; video_queue = nil; }
int virgl_video_fill_caps(union virgl_caps *caps) {
    if (!initialized || !caps) return -1;
    caps->v2.num_video_caps = 0;
    enum pipe_video_profile profiles[] = {PIPE_VIDEO_PROFILE_MPEG4_AVC_BASELINE, PIPE_VIDEO_PROFILE_MPEG4_AVC_CONSTRAINED_BASELINE, PIPE_VIDEO_PROFILE_MPEG4_AVC_MAIN, PIPE_VIDEO_PROFILE_MPEG4_AVC_HIGH};
    for (unsigned i = 0; i < 4; ++i) {
        struct virgl_video_caps *v = &caps->v2.video_caps[caps->v2.num_video_caps++]; memset(v, 0, sizeof(*v));
        v->profile = profiles[i]; v->entrypoint = PIPE_VIDEO_ENTRYPOINT_BITSTREAM;
        v->max_level = 51; v->max_width = VIDEO_MAX_DIMENSION; v->max_height = VIDEO_MAX_DIMENSION;
        v->prefered_format = VIRGL_FORMAT_NV12; v->max_macroblocks = 36864;
        v->npot_texture = 1; v->supports_progressive = 1;
    }
    return 0;
}
struct virgl_video_codec *virgl_video_create_codec(const struct virgl_video_create_codec_args *args) {
    if (args) os_log(OS_LOG_DEFAULT, "VideoToolbox codec request profile=%u entry=%u chroma=%u size=%ux%u refs=%u", args->profile,args->entrypoint,args->chroma_format,args->width,args->height,args->max_references);
    if (!initialized || !args || !supported(args->profile) || args->entrypoint != PIPE_VIDEO_ENTRYPOINT_BITSTREAM ||
        args->chroma_format != PIPE_VIDEO_CHROMA_FORMAT_420 || !args->width || !args->height ||
        args->width > VIDEO_MAX_DIMENSION || args->height > VIDEO_MAX_DIMENSION ||
        ((args->width + 15) / 16) * ((args->height + 15) / 16) > 36864 ||
        (args->width & 1) || (args->height & 1) || args->max_references > 16 || codec_count >= 16) {
        os_log_error(OS_LOG_DEFAULT, "VideoToolbox codec rejected liveCodecs=%u liveBuffers=%u", codec_count, buffer_count);
        return NULL;
    }
    struct virgl_video_codec *c = calloc(1, sizeof(*c)); if (c) { c->args = *args; if (++next_codec_id == 0) ++next_codec_id; c->diagnostic_id = next_codec_id; ++codec_count; } return c;
}
void virgl_video_destroy_codec(struct virgl_video_codec *c) {
    if (!c) return;
    if (c->session) { VTDecompressionSessionWaitForAsynchronousFrames(c->session); VTDecompressionSessionInvalidate(c->session); CFRelease(c->session); }
    os_log(OS_LOG_DEFAULT, "VideoToolbox codec destroyed codec=%u frames=%u remainingCodecs=%u liveBuffers=%u",
           c->diagnostic_id, c->frame_count, codec_count ? codec_count - 1 : 0, buffer_count);
    if (c->format) CFRelease(c->format); free(c); if (codec_count) --codec_count;
}
enum pipe_video_profile virgl_video_codec_profile(const struct virgl_video_codec *c) { return c ? c->args.profile : PIPE_VIDEO_PROFILE_UNKNOWN; }
void *virgl_video_codec_opaque_data(struct virgl_video_codec *c) { return c ? c->args.opaque : NULL; }
struct virgl_video_buffer *virgl_video_create_buffer(const struct virgl_video_create_buffer_args *args) {
    if (!initialized || !args || (args->format != PIPE_FORMAT_NV12 && args->format != PIPE_FORMAT_IYUV && args->format != PIPE_FORMAT_YV12 && args->format != PIPE_FORMAT_B8G8R8A8_UNORM && args->format != PIPE_FORMAT_R8G8B8A8_UNORM) || args->interlaced || !args->width || !args->height ||
        args->width > VIDEO_MAX_DIMENSION || args->height > VIDEO_MAX_DIMENSION ||
        ((args->width + 15) / 16) * ((args->height + 15) / 16) > 36864 || (args->width & 1) || (args->height & 1) || buffer_count >= 512) {
        if (args) virgl_error("VideoToolbox buffer rejected format=%u expected=%u size=%ux%u interlaced=%u ready=%u count=%u\n", args->format, PIPE_FORMAT_NV12, args->width, args->height, args->interlaced, initialized, buffer_count);
        return NULL;
    }
    uint64_t reservation = video_buffer_reservation(args->width, args->height);
    uint64_t budget = video_buffer_budget();
    if (video_buffer_bytes > budget || reservation > budget - video_buffer_bytes) {
        os_log_error(OS_LOG_DEFAULT, "VideoToolbox buffer budget rejected count=%u bytes=%llu requested=%llu limit=%llu",
                     buffer_count, (unsigned long long)video_buffer_bytes,
                     (unsigned long long)reservation, (unsigned long long)budget);
        return NULL;
    }
    struct virgl_video_buffer *b = calloc(1, sizeof(*b));
    if (b) { b->args = *args; b->reserved_bytes = reservation; video_buffer_bytes += reservation; if (++next_buffer_id == 0) ++next_buffer_id; b->id = next_buffer_id; ++buffer_count; } return b;
}
void virgl_video_destroy_buffer(struct virgl_video_buffer *b) { if (!b) return; if (b->image) CVPixelBufferRelease(b->image); video_buffer_bytes -= b->reserved_bytes; free(b); if (buffer_count) --buffer_count; }
uint32_t virgl_video_buffer_id(const struct virgl_video_buffer *b) { return b ? b->id : UINT32_MAX; }
void *virgl_video_buffer_opaque_data(struct virgl_video_buffer *b) { return b ? b->args.opaque : NULL; }
int virgl_video_begin_frame(struct virgl_video_codec *c, struct virgl_video_buffer *b) {
    if (!c || !b || (b->args.format != PIPE_FORMAT_NV12 && b->args.format != PIPE_FORMAT_IYUV && b->args.format != PIPE_FORMAT_YV12) || c->args.width != b->args.width || c->args.height != b->args.height) return -1;
    c->error = 0; if (b->image) { CVPixelBufferRelease(b->image); b->image = NULL; } return 0;
}
static size_t startcode(const uint8_t *p, size_t length, size_t offset, size_t *prefix) {
    for (size_t i = offset; i + 3 <= length; ++i) {
        if (p[i] || p[i + 1]) continue;
        if (p[i + 2] == 1) { *prefix = 3; return i; }
        if (i + 4 <= length && !p[i + 2] && p[i + 3] == 1) { *prefix = 4; return i; }
    }
    return length;
}
int virgl_video_decode_bitstream(struct virgl_video_codec *c, struct virgl_video_buffer *b,
                                  const union virgl_picture_desc *desc, unsigned count,
                                  const void * const *buffers, const unsigned *sizes) {
    if (!c || !b || !desc || !count || count > 128 || !buffers || !sizes || desc->base.protected_playback || desc->base.key_size ||
        desc->base.profile != c->args.profile || desc->h264.field_pic_flag) return -1;
    double started = video_milliseconds();
    size_t total = 0; for (unsigned i = 0; i < count; ++i) { if (!buffers[i] || sizes[i] > VIDEO_MAX_BYTES - total) return -1; total += sizes[i]; }
    if (!total) return -1;
    uint8_t *data = malloc(total), *avcc = malloc(total + 512); if (!data || !avcc) { free(data); free(avcc); return -1; }
    size_t cursor = 0; for (unsigned i = 0; i < count; ++i) { memcpy(data + cursor, buffers[i], sizes[i]); cursor += sizes[i]; }
    uint8_t generated_sps[4096], generated_pps[4096];
    const uint8_t *sps = NULL, *pps = NULL; size_t ns = 0, np = 0, out = 0, prefix = 0;
    size_t position = startcode(data, total, 0, &prefix); unsigned nals = 0; uint32_t pps_id = 0; bool slice = false, valid = position < total;
    while (valid && position < total) {
        size_t begin = position + prefix, next_prefix = 0;
        size_t next = startcode(data, total, begin, &next_prefix), end = next;
        while (end > begin && data[end - 1] == 0) --end;
        if (begin >= end || ++nals > 128) { valid = false; break; }
        size_t n = end - begin; unsigned kind = data[begin] & 31;
        if (kind == 7) { sps = data + begin; ns = n; }
        else if (kind == 8) { pps = data + begin; np = n; }
        else if (kind != 9 && kind != 12) {
            if (out + 4 + n > total + 512) { valid = false; break; }
            avcc[out++] = n >> 24; avcc[out++] = n >> 16; avcc[out++] = n >> 8; avcc[out++] = n;
            memcpy(avcc + out, data + begin, n); out += n;
            if (kind == 1 || kind == 5) { valid = slice_pps_id(data + begin, n, &pps_id); slice = true; }
        }
        position = next; prefix = next_prefix;
    }
    if (valid && slice && (!sps || !pps)) {
        valid = build_parameters(c, &desc->h264, pps_id, generated_sps, &ns, generated_pps, &np);
        if (!valid) os_log(OS_LOG_DEFAULT, "VideoToolbox parameter reconstruction rejected chroma=%u frameonly=%u scaling=%u", desc->h264.pps.sps.chroma_format_idc, desc->h264.pps.sps.frame_mbs_only_flag, desc->h264.pps.sps.seq_scaling_matrix_present_flag);
        sps = generated_sps; pps = generated_pps;
    }
    if (valid && slice) valid = configure(c, sps, ns, pps, np); else valid = false;
    CMBlockBufferRef block = NULL; CMSampleBufferRef sample = NULL;
    if (valid) {
        valid = CMBlockBufferCreateWithMemoryBlock(NULL, NULL, out, NULL, NULL, 0, out, 0, &block) == 0 &&
                CMBlockBufferReplaceDataBytes(avcc, block, 0, out) == 0;
        if (valid) valid = CMSampleBufferCreateReady(NULL, block, c->format, 1, 0, NULL, 1, &out, &sample) == 0;
        if (valid) {
            OSStatus decode_status = VTDecompressionSessionDecodeFrame(c->session, sample, 0, b, NULL);
            OSStatus wait_status = decode_status ? 0 : VTDecompressionSessionWaitForAsynchronousFrames(c->session);
            if (decode_status || wait_status) c->error = decode_status ? decode_status : wait_status;
            valid = !c->error && b->image;
        }
    }
    if (sample) CFRelease(sample); if (block) CFRelease(block); free(avcc); free(data);
    double elapsed = video_milliseconds() - started;
    ++c->frame_count;
    if (c->frame_count == 1 || (c->frame_count <= 50 && c->frame_count % 10 == 0) ||
        (elapsed >= 20 && c->frame_count % 30 == 0))
        os_log(OS_LOG_DEFAULT, "VideoToolbox decode timing codec=%u frame=%u ms=%.3f liveCodecs=%u liveBuffers=%u",
               c->diagnostic_id, c->frame_count, elapsed, codec_count, buffer_count);
    if (!valid) os_log_error(OS_LOG_DEFAULT, "VideoToolbox frame rejected codec=%u frame=%u status=%d image=%d", c->diagnostic_id, c->frame_count, (int)c->error, b->image != NULL);
    return valid ? 0 : -1;
}
int virgl_video_encode_bitstream(struct virgl_video_codec *c, struct virgl_video_buffer *b, const union virgl_picture_desc *d) { (void)c; (void)b; (void)d; return -1; }
int virgl_video_end_frame(struct virgl_video_codec *c, struct virgl_video_buffer *b) {
    if (!c || !b || c->error || !b->image || !callbacks.decode_completed) return -1;
    struct virgl_video_dma_buf surface = {.buf = b, .width = b->args.width, .height = b->args.height,
        .flags = VIRGL_VIDEO_DMABUF_READ_ONLY, .num_planes = 2, .native_surface = CVPixelBufferGetIOSurface(b->image)};
    callbacks.decode_completed(c, &surface);
    if (c->error) return -1;
    ++decoded_frames;
    if (decoded_frames == 1 || decoded_frames % 120 == 0)
        os_log(OS_LOG_DEFAULT, "VideoToolbox hardware frames delivered: %u", decoded_frames);
    return 0;
}
void virgl_video_copy_result(struct virgl_video_codec *codec, int result) {
    if (codec && result) codec->error = -1;
}

// Copy decoded NV12 planes directly on the destination texture's Metal device.
// No guest pointer, cross-process native handle, or decoded CPU frame copy.
int virgl_video_copy_plane(void *native_surface, unsigned plane, void *native_texture) {
    @autoreleasepool {
        double started = video_milliseconds();
        IOSurfaceRef surface = native_surface; id<MTLTexture> destination = (id<MTLTexture>)native_texture;
        if (!surface || !destination || plane > 1 || IOSurfaceGetPlaneCount(surface) != 2) return -1;
        MTLPixelFormat format = plane ? MTLPixelFormatRG8Unorm : MTLPixelFormatR8Unorm;
        size_t width = IOSurfaceGetWidthOfPlane(surface, plane), height = IOSurfaceGetHeightOfPlane(surface, plane);
        if (destination.pixelFormat != format || destination.width < width || destination.height < height) return -1;
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height mipmapped:NO];
        d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> source = [destination.device newTextureWithDescriptor:d iosurface:surface plane:plane];
        id<MTLCommandQueue> queue = retained_video_queue(destination.device);
        id<MTLCommandBuffer> command = [queue commandBuffer]; id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
        bool valid = source && queue && command && blit;
        if (valid) {
            [blit copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                      sourceSize:MTLSizeMake(width,height,1) toTexture:destination destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
            [blit endEncoding]; [command commit]; [command waitUntilCompleted]; valid = command.status == MTLCommandBufferStatusCompleted;
        }
        [source release]; [queue release];
        unsigned copy = ++plane_copies;
        double elapsed = video_milliseconds() - started;
        if (copy == 1 || copy == 50 || (elapsed >= 10 && copy % 30 == 0))
            os_log(OS_LOG_DEFAULT, "VideoToolbox plane copy=%u plane=%u ms=%.3f valid=%u liveBuffers=%u",
                   copy, plane, elapsed, valid, buffer_count);
        return valid ? 0 : -1;
    }
}

int virgl_video_copy_planar(void *native_surface, void *native_y, void *native_u, void *native_v) {
    @autoreleasepool {
        double started = video_milliseconds();
        IOSurfaceRef surface = native_surface;
        id<MTLTexture> y = (id<MTLTexture>)native_y, u = (id<MTLTexture>)native_u, v = (id<MTLTexture>)native_v;
        if (!surface || !y || !u || !v || IOSurfaceGetPlaneCount(surface) != 2) return -1;
        size_t width = IOSurfaceGetWidthOfPlane(surface, 0), height = IOSurfaceGetHeightOfPlane(surface, 0);
        size_t cw = IOSurfaceGetWidthOfPlane(surface, 1), ch = IOSurfaceGetHeightOfPlane(surface, 1);
        if (!width || !height || width > VIDEO_MAX_DIMENSION || height > VIDEO_MAX_DIMENSION ||
            y.pixelFormat != MTLPixelFormatR8Unorm || u.pixelFormat != MTLPixelFormatR8Unorm || v.pixelFormat != MTLPixelFormatR8Unorm ||
            y.width < width || y.height < height || u.width < cw || u.height < ch || v.width < cw || v.height < ch ||
            y.device != u.device || y.device != v.device) return -1;
        // Intermediate writable textures avoid changing guest resource usage.
        MTLTextureDescriptor *yd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:width height:height mipmapped:NO];
        yd.storageMode = MTLStorageModeShared; yd.usage = MTLTextureUsageShaderRead;
        MTLTextureDescriptor *uvd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG8Unorm width:cw height:ch mipmapped:NO];
        uvd.storageMode = MTLStorageModeShared; uvd.usage = MTLTextureUsageShaderRead;
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:cw height:ch mipmapped:NO];
        td.storageMode = MTLStorageModePrivate; td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        id<MTLTexture> source_y = [y.device newTextureWithDescriptor:yd iosurface:surface plane:0];
        id<MTLTexture> source_uv = [y.device newTextureWithDescriptor:uvd iosurface:surface plane:1];
        id<MTLTexture> temp_u = [y.device newTextureWithDescriptor:td], temp_v = [y.device newTextureWithDescriptor:td];
        NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            @"kernel void split_uv(texture2d<float, access::read> src [[texture(0)]], "
            @"texture2d<float, access::write> u [[texture(1)]], texture2d<float, access::write> v [[texture(2)]], "
            @"uint2 p [[thread_position_in_grid]]) { if (p.x >= src.get_width() || p.y >= src.get_height()) return; "
            @"float2 uv = src.read(p).rg; u.write(float4(uv.r,0,0,1),p); v.write(float4(uv.g,0,0,1),p); }";
        // Only trusted constant MSL enters this compiler; never guest shader text.
        NSError *error = nil;
        if (split_pipeline && split_pipeline.device != y.device) { [split_pipeline release]; split_pipeline = nil; }
        if (!split_pipeline) {
            id<MTLLibrary> library = [y.device newLibraryWithSource:source options:nil error:&error];
            id<MTLFunction> function = [library newFunctionWithName:@"split_uv"];
            split_pipeline = function ? [y.device newComputePipelineStateWithFunction:function error:&error] : nil;
            [library release]; [function release];
        }
        id<MTLComputePipelineState> pipeline = [split_pipeline retain];
        id<MTLCommandQueue> queue = retained_video_queue(y.device);
        id<MTLCommandBuffer> command = [queue commandBuffer];
        bool valid = source_y && source_uv && temp_u && temp_v && pipeline && command;
        if (valid) {
            id<MTLComputeCommandEncoder> compute = [command computeCommandEncoder];
            valid = compute != nil;
            if (compute) {
                [compute setComputePipelineState:pipeline]; [compute setTexture:source_uv atIndex:0];
                [compute setTexture:temp_u atIndex:1]; [compute setTexture:temp_v atIndex:2];
                [compute dispatchThreads:MTLSizeMake(cw,ch,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)]; [compute endEncoding];
            }
            id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder]; valid = valid && blit;
            if (blit) {
                id<MTLTexture> sources[] = {source_y, temp_u, temp_v}, destinations[] = {y,u,v};
                for (unsigned i = 0; i < 3; ++i) {
                    [blit copyFromTexture:sources[i] sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                        sourceSize:MTLSizeMake(i ? cw : width,i ? ch : height,1) toTexture:destinations[i]
                        destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
                }
                [blit endEncoding];
            }
            [command commit]; [command waitUntilCompleted]; valid = valid && command.status == MTLCommandBufferStatusCompleted;
        }
        [source_y release]; [source_uv release]; [temp_u release]; [temp_v release];
        [pipeline release]; [queue release];
        unsigned copy = ++planar_copies;
        double elapsed = video_milliseconds() - started;
        if (copy == 1 || copy == 50 || (elapsed >= 10 && copy % 30 == 0))
            os_log(OS_LOG_DEFAULT, "VideoToolbox planar copy=%u ms=%.3f valid=%u liveBuffers=%u",
                   copy, elapsed, valid, buffer_count);
        return valid ? 0 : -1;
    }
}
