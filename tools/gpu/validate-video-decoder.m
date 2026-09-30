// Trusted fixture only: require hardware H.264 decoding into shared NV12.
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#include <stdio.h>

struct video_fixture {
    CFMutableArrayRef samples;
    CVPixelBufferRef decoded;
    OSStatus encode_error, decode_error;
    unsigned decoded_count;
};

static void encoded(void *cookie, void *frame, OSStatus status,
                    VTEncodeInfoFlags flags, CMSampleBufferRef sample)
{
    (void)frame; (void)flags;
    struct video_fixture *fixture = cookie;
    if (status || !sample) { fixture->encode_error = status ? status : -1; return; }
    CFArrayAppendValue(fixture->samples, sample);
}

static void decoded(void *cookie, void *frame, OSStatus status,
                    VTDecodeInfoFlags flags, CVImageBufferRef image,
                    CMTime time, CMTime duration)
{
    (void)frame; (void)flags; (void)time; (void)duration;
    struct video_fixture *fixture = cookie;
    if (status || !image) { fixture->decode_error = status ? status : -1; return; }
    if (fixture->decoded) CVPixelBufferRelease(fixture->decoded);
    fixture->decoded = CVPixelBufferRetain(image);
    ++fixture->decoded_count;
}

int probe_video_decoder(void)
{
    @autoreleasepool {
        struct video_fixture fixture = {0};
        fixture.samples = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        VTCompressionSessionRef encoder = NULL;
        VTDecompressionSessionRef decoder = NULL;
        CVPixelBufferRef input = NULL;
        CFTypeRef hardware = NULL;
        OSStatus status = -1;
        int success = 0;
        NSDictionary *encoder_spec = @{
            (__bridge NSString *)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES,
        };
        NSDictionary *input_attrs = @{
            (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
        };
        NSDictionary *decoder_spec = @{
            (__bridge NSString *)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: @YES,
        };
        NSDictionary *output_attrs = @{
            (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
        };
        status = VTCompressionSessionCreate(NULL, 64, 64, kCMVideoCodecType_H264,
            (__bridge CFDictionaryRef)encoder_spec, NULL, NULL, encoded, &fixture, &encoder);
        if (status) goto cleanup;
        status = VTSessionSetProperty(encoder, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
        if (status) goto cleanup;
        status = VTSessionSetProperty(encoder, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
        if (status) goto cleanup;
        status = CVPixelBufferCreate(NULL, 64, 64, kCVPixelFormatType_32BGRA,
            (__bridge CFDictionaryRef)input_attrs, &input);
        if (status) goto cleanup;
        status = CVPixelBufferLockBaseAddress(input, 0);
        if (status) goto cleanup;
        for (size_t y = 0; y < 64; ++y) {
            uint8_t *row = (uint8_t *)CVPixelBufferGetBaseAddress(input) + y * CVPixelBufferGetBytesPerRow(input);
            for (size_t x = 0; x < 64; ++x) {
                row[x * 4] = 0; row[x * 4 + 1] = 0; row[x * 4 + 2] = 255; row[x * 4 + 3] = 255;
            }
        }
        CVPixelBufferUnlockBaseAddress(input, 0);
        for (int frame = 0; frame < 12; ++frame) {
            status = VTCompressionSessionEncodeFrame(encoder, input, CMTimeMake(frame, 30),
                CMTimeMake(1, 30), NULL, NULL, NULL);
            if (status) goto cleanup;
        }
        status = VTCompressionSessionCompleteFrames(encoder, kCMTimeInvalid);
        if (status || fixture.encode_error || CFArrayGetCount(fixture.samples) != 12) goto cleanup;
        CMSampleBufferRef first = (CMSampleBufferRef)CFArrayGetValueAtIndex(fixture.samples, 0);
        VTDecompressionOutputCallbackRecord callback = {decoded, &fixture};
        status = VTDecompressionSessionCreate(NULL, CMSampleBufferGetFormatDescription(first),
            (__bridge CFDictionaryRef)decoder_spec, (__bridge CFDictionaryRef)output_attrs,
            &callback, &decoder);
        if (status) goto cleanup;
        for (CFIndex frame = 0; frame < CFArrayGetCount(fixture.samples); ++frame) {
            status = VTDecompressionSessionDecodeFrame(decoder,
                (CMSampleBufferRef)CFArrayGetValueAtIndex(fixture.samples, frame),
                kVTDecodeFrame_EnableAsynchronousDecompression, NULL, NULL);
            if (status) goto cleanup;
        }
        status = VTDecompressionSessionWaitForAsynchronousFrames(decoder);
        if (status || fixture.decode_error || fixture.decoded_count != 12 || !fixture.decoded) goto cleanup;
        status = VTSessionCopyProperty(decoder, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                      NULL, &hardware);
        if (status || !hardware || !CFEqual(hardware, kCFBooleanTrue)) goto cleanup;
        if (CVPixelBufferGetPixelFormatType(fixture.decoded) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
            CVPixelBufferGetPlaneCount(fixture.decoded) != 2 || !CVPixelBufferGetIOSurface(fixture.decoded)) goto cleanup;
        // One fixture pixel checks decoding, not just decoder allocation.
        status = CVPixelBufferLockBaseAddress(fixture.decoded, kCVPixelBufferLock_ReadOnly);
        if (status) goto cleanup;
        const uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(fixture.decoded, 0);
        const uint8_t *uv = CVPixelBufferGetBaseAddressOfPlane(fixture.decoded, 1);
        if (y && uv) printf("VIDEO FIXTURE: NV12 Y=%u Cb=%u Cr=%u; hardware decoder active\n", y[0], uv[0], uv[1]);
        // Accept red in either BT.601 or BT.709 limited-range conversion.
        success = y && uv && y[0] >= 55 && y[0] <= 95 && uv[0] >= 75 && uv[0] <= 115 && uv[1] >= 225;
        CVPixelBufferUnlockBaseAddress(fixture.decoded, kCVPixelBufferLock_ReadOnly);
        if (success) puts("PASS: twelve H.264 frames decoded by hardware VideoToolbox into IOSurface-backed NV12; red fixture verified");
cleanup:
        if (!success) fprintf(stderr, "FAIL: hardware H.264 decoding (status %d, encode %d, decode %d, frames %u)\n",
                              (int)status, (int)fixture.encode_error, (int)fixture.decode_error, fixture.decoded_count);
        if (decoder) { VTDecompressionSessionInvalidate(decoder); CFRelease(decoder); }
        if (encoder) { VTCompressionSessionInvalidate(encoder); CFRelease(encoder); }
        if (hardware) CFRelease(hardware);
        if (input) CVPixelBufferRelease(input);
        if (fixture.decoded) CVPixelBufferRelease(fixture.decoded);
        if (fixture.samples) CFRelease(fixture.samples);
        return success;
    }
}
