/* mob_screencast_nif — iOS screen-capture tier-1 plugin NIF (Objective-C).
 *
 * The iOS counterpart to priv/native/jni/mob_screencast_nif.zig: captures the
 * device's own screen with ReplayKit's in-app RPScreenRecorder (per-session user
 * consent, no broadcast extension), hardware-encodes it to H264 with a
 * VideoToolbox VTCompressionSession, converts the encoder's AVCC output to
 * Annex-B (start-code) NAL units (SPS/PPS prepended to keyframes), and pushes each
 * access unit to the BEAM as:
 *
 *   {:screencast, :frame, #{bytes, width, height, format: :h264, timestamp_ms, keyframe}}
 *
 * exactly like the Android bridge's nativeDeliverScreencastFrame. Consent outcome
 * is reported as {:screencast, :permission, :granted | :denied}.
 *
 * Compiled as ObjC (-fobjc-arc) via the plugin objc-NIF path (manifest lang: :objc).
 * Under ARC, CoreFoundation / CoreMedia / VideoToolbox objects are NOT managed — they
 * are released manually with CFRelease.
 */
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <ReplayKit/ReplayKit.h>
#import <VideoToolbox/VideoToolbox.h>
#include <erl_nif.h>

// ── Capture session state ───────────────────────────────────────────────────
// All VTCompressionSession lifecycle (create / encode / teardown) is serialized
// onto g_sc_queue so start_stream, the ReplayKit sample handler, and stop_stream
// never race on g_vt_session. The VT output callback runs on a VideoToolbox
// thread and only calls enif_send (documented thread-safe).
static ErlNifPid g_sc_pid;
static BOOL g_sc_have_pid = NO;
static VTCompressionSessionRef g_vt_session = NULL;
static dispatch_queue_t g_sc_queue = NULL;
static int g_sc_bitrate = 2000000;
static int g_sc_fps = 30;
static int g_sc_keyframe_interval_ms = 2000;
static int g_sc_max_size = 0; // honored on Android; iOS encodes at native res (TODO)
static int g_enc_w = 0;
static int g_enc_h = 0;
static BOOL g_sc_force_keyframe = NO;

static const uint8_t kAnnexBStartCode[4] = {0x00, 0x00, 0x00, 0x01};

static dispatch_queue_t sc_queue(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      g_sc_queue = dispatch_queue_create("io.mob.screencast.session", DISPATCH_QUEUE_SERIAL);
    });
    return g_sc_queue;
}

static void sc_send_permission(const char *status) {
    if (!g_sc_have_pid)
        return;
    ErlNifEnv *e = enif_alloc_env();
    ERL_NIF_TERM msg = enif_make_tuple3(e, enif_make_atom(e, "screencast"),
                                        enif_make_atom(e, "permission"),
                                        enif_make_atom(e, status));
    enif_send(NULL, &g_sc_pid, e, msg);
    enif_free_env(e);
}

// ── VideoToolbox output callback: AVCC -> Annex-B, deliver per access unit ───
static void sc_vt_output(void *outputCallbackRefCon, void *sourceFrameRefCon, OSStatus status,
                         VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer) {
    (void)outputCallbackRefCon;
    (void)sourceFrameRefCon;
    (void)infoFlags;
    if (status != noErr || sampleBuffer == NULL || !CMSampleBufferDataIsReady(sampleBuffer))
        return;

    // A sync sample (IDR) is a keyframe: the NotSync attachment is absent or false.
    BOOL keyframe = YES;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef dict = (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFBooleanRef notSync = NULL;
        if (CFDictionaryGetValueIfPresent(dict, kCMSampleAttachmentKey_NotSync,
                                          (const void **)&notSync) &&
            notSync != NULL) {
            keyframe = !CFBooleanGetValue(notSync);
        }
    }

    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);

    // AVCC NAL length-prefix size (almost always 4); read it from the format desc.
    int nal_header_len = 4;
    if (fmt) {
        size_t pcount = 0;
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, NULL, NULL, &pcount,
                                                           &nal_header_len);
    }

    NSMutableData *annexb = [NSMutableData data];

    // Prepend SPS/PPS (Annex-B) to keyframes so a freshly-joined decoder can start.
    if (keyframe && fmt) {
        size_t pcount = 0;
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, NULL, NULL, &pcount, NULL);
        for (size_t i = 0; i < pcount; i++) {
            const uint8_t *pset = NULL;
            size_t plen = 0;
            if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, i, &pset, &plen, NULL,
                                                                   NULL) == noErr &&
                pset && plen > 0) {
                [annexb appendBytes:kAnnexBStartCode length:4];
                [annexb appendBytes:pset length:plen];
            }
        }
    }

    // Walk the elementary-stream NALUs and swap each AVCC length prefix for a start code.
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t total = 0;
    char *data = NULL;
    if (block && CMBlockBufferGetDataPointer(block, 0, NULL, &total, &data) == noErr && data) {
        size_t offset = 0;
        while (offset + (size_t)nal_header_len <= total) {
            uint32_t nal_len = 0;
            for (int b = 0; b < nal_header_len; b++) {
                nal_len = (nal_len << 8) | (uint8_t)data[offset + b];
            }
            offset += nal_header_len;
            if (nal_len == 0 || offset + nal_len > total)
                break;
            [annexb appendBytes:kAnnexBStartCode length:4];
            [annexb appendBytes:(data + offset) length:nal_len];
            offset += nal_len;
        }
    }

    if (annexb.length == 0)
        return;

    uint64_t now_ms = (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);

    ErlNifEnv *e = enif_alloc_env();
    ErlNifBinary out;
    if (enif_alloc_binary(annexb.length, &out) == 0) {
        enif_free_env(e);
        return;
    }
    memcpy(out.data, annexb.bytes, annexb.length);

    ERL_NIF_TERM map = enif_make_new_map(e);
    enif_make_map_put(e, map, enif_make_atom(e, "bytes"), enif_make_binary(e, &out), &map);
    enif_make_map_put(e, map, enif_make_atom(e, "width"), enif_make_int(e, g_enc_w), &map);
    enif_make_map_put(e, map, enif_make_atom(e, "height"), enif_make_int(e, g_enc_h), &map);
    enif_make_map_put(e, map, enif_make_atom(e, "format"), enif_make_atom(e, "h264"), &map);
    enif_make_map_put(e, map, enif_make_atom(e, "timestamp_ms"), enif_make_uint64(e, now_ms), &map);
    enif_make_map_put(e, map, enif_make_atom(e, "keyframe"),
                      enif_make_atom(e, keyframe ? "true" : "false"), &map);

    ERL_NIF_TERM msg = enif_make_tuple3(e, enif_make_atom(e, "screencast"),
                                        enif_make_atom(e, "frame"), map);
    enif_send(NULL, &g_sc_pid, e, msg);
    enif_free_env(e);
}

// Lazily create the compression session from the first frame's dimensions. Must run
// on sc_queue.
static void sc_ensure_session(CVImageBufferRef image) {
    if (g_vt_session)
        return;
    size_t w = CVPixelBufferGetWidth(image);
    size_t h = CVPixelBufferGetHeight(image);
    if (w == 0 || h == 0)
        return;
    g_enc_w = (int)w;
    g_enc_h = (int)h;

    OSStatus s = VTCompressionSessionCreate(kCFAllocatorDefault, (int32_t)w, (int32_t)h,
                                            kCMVideoCodecType_H264, NULL, NULL, NULL, sc_vt_output,
                                            NULL, &g_vt_session);
    if (s != noErr || !g_vt_session) {
        NSLog(@"[mob/screencast] VTCompressionSessionCreate failed: %d", (int)s);
        g_vt_session = NULL;
        return;
    }

    VTSessionSetProperty(g_vt_session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    // Constrained baseline, no B-frames: low latency + broad decoder compat (matches the
    // host Publisher's H264 mode-1 default + the FU-A payloader).
    VTSessionSetProperty(g_vt_session, kVTCompressionPropertyKey_ProfileLevel,
                         kVTProfileLevel_H264_Baseline_AutoLevel);
    VTSessionSetProperty(g_vt_session, kVTCompressionPropertyKey_AllowFrameReordering,
                         kCFBooleanFalse);

    CFNumberRef br = CFNumberCreate(NULL, kCFNumberIntType, &g_sc_bitrate);
    VTSessionSetProperty(g_vt_session, kVTCompressionPropertyKey_AverageBitRate, br);
    CFRelease(br);

    CFNumberRef fps = CFNumberCreate(NULL, kCFNumberIntType, &g_sc_fps);
    VTSessionSetProperty(g_vt_session, kVTCompressionPropertyKey_ExpectedFrameRate, fps);
    CFRelease(fps);

    double kf_sec = g_sc_keyframe_interval_ms / 1000.0;
    CFNumberRef kf = CFNumberCreate(NULL, kCFNumberDoubleType, &kf_sec);
    VTSessionSetProperty(g_vt_session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, kf);
    CFRelease(kf);

    VTCompressionSessionPrepareToEncodeFrames(g_vt_session);
    NSLog(@"[mob/screencast] capturing %zux%zu @ %dbps", w, h, g_sc_bitrate);
}

static void sc_teardown_session(void) {
    if (g_vt_session) {
        VTCompressionSessionCompleteFrames(g_vt_session, kCMTimeInvalid);
        VTCompressionSessionInvalidate(g_vt_session);
        CFRelease(g_vt_session);
        g_vt_session = NULL;
    }
}

// ── NIFs ─────────────────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_screencast_start_stream(ErlNifEnv *env, int argc,
                                                const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin)) {
        return enif_make_badarg(env);
    }
    NSString *json = [[NSString alloc] initWithBytes:bin.data
                                              length:bin.size
                                            encoding:NSUTF8StringEncoding];
    NSDictionary *opts =
        [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                                        options:0
                                          error:nil];
    if ([opts isKindOfClass:[NSDictionary class]]) {
        if (opts[@"bitrate"])
            g_sc_bitrate = [opts[@"bitrate"] intValue];
        if (opts[@"fps"])
            g_sc_fps = [opts[@"fps"] intValue];
        if (opts[@"keyframe_interval_ms"])
            g_sc_keyframe_interval_ms = [opts[@"keyframe_interval_ms"] intValue];
        if (opts[@"max_size"])
            g_sc_max_size = [opts[@"max_size"] intValue];
    }

    enif_self(env, &g_sc_pid);
    g_sc_have_pid = YES;
    g_sc_force_keyframe = NO;

    RPScreenRecorder *rec = [RPScreenRecorder sharedRecorder];
    rec.microphoneEnabled = NO;

    [rec startCaptureWithHandler:^(CMSampleBufferRef sampleBuffer, RPSampleBufferType bufferType,
                                   NSError *error) {
      if (error || bufferType != RPSampleBufferTypeVideo || sampleBuffer == NULL)
          return;
      if (!CMSampleBufferDataIsReady(sampleBuffer))
          return;
      // Retain across the async hop to sc_queue (the sample buffer owns the image buffer).
      CFRetain(sampleBuffer);
      dispatch_async(sc_queue(), ^{
        CVImageBufferRef image = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (image) {
            sc_ensure_session(image);
            if (g_vt_session) {
                CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
                CFDictionaryRef frame_props = NULL;
                if (g_sc_force_keyframe) {
                    const void *k = kVTEncodeFrameOptionKey_ForceKeyFrame;
                    const void *v = kCFBooleanTrue;
                    frame_props = CFDictionaryCreate(NULL, &k, &v, 1,
                                                     &kCFTypeDictionaryKeyCallBacks,
                                                     &kCFTypeDictionaryValueCallBacks);
                    g_sc_force_keyframe = NO;
                }
                VTEncodeInfoFlags flags;
                VTCompressionSessionEncodeFrame(g_vt_session, image, pts, kCMTimeInvalid,
                                                frame_props, NULL, &flags);
                if (frame_props)
                    CFRelease(frame_props);
            }
        }
        CFRelease(sampleBuffer);
      });
    }
        completionHandler:^(NSError *error) {
          // Called once when capture starts (error == nil) or the user declines / it fails.
          sc_send_permission(error == nil ? "granted" : "denied");
          if (error)
              NSLog(@"[mob/screencast] startCapture failed: %@", error);
        }];

    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_screencast_stop_stream(ErlNifEnv *env, int argc,
                                               const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    [[RPScreenRecorder sharedRecorder] stopCaptureWithHandler:^(NSError *error) {
      (void)error;
    }];
    dispatch_async(sc_queue(), ^{
      sc_teardown_session();
    });
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_screencast_request_keyframe(ErlNifEnv *env, int argc,
                                                    const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    g_sc_force_keyframe = YES;
    return enif_make_atom(env, "ok");
}

// ── Registration ──────────────────────────────────────────────────────────────
static ErlNifFunc nif_funcs[] = {
    {"screencast_start_stream", 1, nif_screencast_start_stream, 0},
    {"screencast_stop_stream", 0, nif_screencast_stop_stream, 0},
    {"screencast_request_keyframe", 0, nif_screencast_request_keyframe, 0},
};

ERL_NIF_INIT(mob_screencast_nif, nif_funcs, NULL, NULL, NULL, NULL)
