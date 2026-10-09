//! mob_screencast_nif — Android screen-capture tier-1 ZIG plugin NIF.
//!
//! Mirrors the mob_camera plugin NIF: the Kotlin side is the plugin-owned bridge
//! `io.mob.screencast.MobScreencastBridge` (MediaProjection → a MediaCodec AVC encoder
//! fed by a VirtualDisplay; the encoder's Annex-B NAL units come back via the exported
//! deliver thunk). Three NIFs (start/stop stream, request keyframe) call static bridge
//! methods; a fourth (service_declared, the self-test's probe) asks the bridge whether
//! the host manifest declares ScreencastService. Encoded frames are pushed to the BEAM
//! by nativeDeliverScreencastFrame.
//!
//! Build path: compiled via `addZigObject` from `-Dplugin_zig_nifs`, reaching mob-core
//! ERTS / JNI bindings through `@import("erts")` / `@import("jni")`. `get_jenv` + `g_jvm`
//! are mob-core exports linked into the same `.so`.
const std = @import("std");
const erts = @import("erts");
const jni = @import("jni");

// mob-core exports (linked into the same .so). NOT duplicated.
extern fn get_jenv(attached: *c_int) ?*jni.JNIEnv;
extern var g_jvm: ?*jni.JavaVM;

// ── Plugin-owned bridge-class method-id cache ────────────────────────────
const ScMethods = struct {
    start_stream: jni.JMethodID = null,
    stop_stream: jni.JMethodID = null,
    request_keyframe: jni.JMethodID = null,
    service_declared: jni.JMethodID = null,
};

var g_sc: ScMethods = .{};
var g_sc_cls: jni.JClass = null;

// ── nativeRegister thunk — cache the bridge jclass + method ids ───────────
// A failed GetStaticMethodID leaves a NoSuchMethodError pending, which would be
// thrown out of register() and crash the app at launch. Clear it (as mob core's
// mob_nif.zig does) so the NIF answers {error, bridge_not_registered} instead.
export fn Java_io_mob_screencast_MobScreencastBridge_nativeRegister(jenv: *jni.JNIEnv, cls: jni.JClass) callconv(.c) void {
    g_sc_cls = jni.newGlobalRef(jenv, cls);
    if (g_sc_cls == null) return;
    g_sc.start_stream = jni.getStaticMethodID(jenv, cls, "screencast_start_stream", "(JLjava/lang/String;)V");
    if (g_sc.start_stream == null) jni.exceptionClear(jenv);
    g_sc.stop_stream = jni.getStaticMethodID(jenv, cls, "screencast_stop_stream", "()V");
    if (g_sc.stop_stream == null) jni.exceptionClear(jenv);
    g_sc.request_keyframe = jni.getStaticMethodID(jenv, cls, "screencast_request_keyframe", "()V");
    if (g_sc.request_keyframe == null) jni.exceptionClear(jenv);
    g_sc.service_declared = jni.getStaticMethodID(jenv, cls, "screencast_service_declared", "()I");
    if (g_sc.service_declared == null) jni.exceptionClear(jenv);
}

/// True, with the exception cleared, when the last JNI call left one pending.
/// mob's JNIEnv wrapper does not declare ExceptionCheck, so this goes through
/// ExceptionOccurred (declared as an opaque slot) and drops its local ref.
fn takePendingException(jenv: *jni.JNIEnv) bool {
    const occurred: *const fn (*jni.JNIEnv) callconv(.c) jni.JObject = @ptrCast(@alignCast(jenv.*.ExceptionOccurred.?));
    const exc = occurred(jenv);
    if (exc == null) return false;
    jni.exceptionClear(jenv);
    jni.deleteLocalRef(jenv, exc);
    return true;
}

// ── Thread-attach + pid round-trip helpers (mirror mob-core / camera) ─────
inline fn detachIfAttached(attached: c_int) void {
    if (attached != 0) {
        if (g_jvm) |jvm| jni.detachCurrentThread(jvm);
    }
}

inline fn pidToJlong(pid: erts.ErlNifPid) jni.JLong {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) {
        return @bitCast(pid.pid);
    }
    return @intCast(pid.pid);
}

inline fn pidFromLong(jpid: jni.JLong) erts.ErlNifPid {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) {
        return .{ .pid = @bitCast(jpid) };
    }
    const low: u32 = @truncate(@as(u64, @bitCast(jpid)));
    return .{ .pid = low };
}

/// {error, bridge_not_registered}: nativeRegister never ran (MobPluginBootstrap
/// did not call register()) or a method-ID lookup failed. Calling through a null
/// jclass / method id would abort the VM; the public API ignores the return
/// value and MobScreencast.SelfTest turns it into a failure (MOB-418).
fn bridgeNotRegistered(env: ?*erts.ErlNifEnv) erts.ERL_NIF_TERM {
    return erts.makeTuple(env, .{ erts.atom(env, "error"), erts.atom(env, "bridge_not_registered") });
}

/// Call `MobScreencastBridge.<method>(pid_long, arg)`.
fn callBridgePidStr(env: ?*erts.ErlNifEnv, method: jni.JMethodID, pid: erts.ErlNifPid, arg: ?[*:0]const u8) erts.ERL_NIF_TERM {
    if (g_sc_cls == null or method == null) return bridgeNotRegistered(env);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const jarg: jni.JString = if (arg) |a| jni.newStringUTF(jenv, a) else null;
    jenv.*.CallStaticVoidMethod.?(jenv, g_sc_cls, method, pidToJlong(pid), jarg);
    if (jarg != null) jni.deleteLocalRef(jenv, jarg);
    detachIfAttached(attached);
    return erts.ok(env);
}

/// Call a no-arg static void bridge method.
fn callBridgeVoid(env: ?*erts.ErlNifEnv, method: jni.JMethodID) erts.ERL_NIF_TERM {
    if (g_sc_cls == null or method == null) return bridgeNotRegistered(env);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    jenv.*.CallStaticVoidMethod.?(jenv, g_sc_cls, method);
    detachIfAttached(attached);
    return erts.ok(env);
}

// ── Inbound delivery — the MediaCodec drain calls this per access unit ────
// Builds {:screencast, :frame, %{bytes, width, height, format: :h264, timestamp_ms, keyframe}}.
// Signature mirrors the Kotlin `external fun nativeDeliverScreencastFrame(pid: Long,
// bytes: ByteArray, width: Int, height: Int, timestampMs: Long, keyframe: Int)` exactly
// (MOB-298: a raw pointer + length here shifted every argument). The byte[] is copied
// out with GetArrayLength + GetByteArrayRegion (no pin/release).
export fn Java_io_mob_screencast_MobScreencastBridge_nativeDeliverScreencastFrame(
    jenv: *jni.JNIEnv,
    cls: jni.JClass,
    pid_long: jni.JLong,
    bytes: jni.JByteArray,
    width: jni.JInt,
    height: jni.JInt,
    timestamp_ms: jni.JLong,
    keyframe: jni.JInt,
) callconv(.c) void {
    _ = cls;
    if (bytes == null) return;
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);

    const nbytes_j: jni.JInt = jenv.*.GetArrayLength.?(jenv, bytes);
    if (nbytes_j < 0) return;
    const nbytes: usize = @intCast(nbytes_j);
    var nal: erts.ErlNifBinary = undefined;
    if (erts.enif_alloc_binary(nbytes, &nal) == 0) return;
    if (nbytes_j > 0) {
        jenv.*.GetByteArrayRegion.?(jenv, bytes, 0, nbytes_j, @ptrCast(nal.data));
    }

    // erts.atom takes a comptime string, so select between two pre-built atom terms
    // (a runtime `if` inside the call isn't comptime-known).
    const kf_atom = if (keyframe != 0) erts.atom(env, "true") else erts.atom(env, "false");

    const keys = [_]erts.ERL_NIF_TERM{
        erts.atom(env, "bytes"),
        erts.atom(env, "width"),
        erts.atom(env, "height"),
        erts.atom(env, "format"),
        erts.atom(env, "timestamp_ms"),
        erts.atom(env, "keyframe"),
    };
    const vals = [_]erts.ERL_NIF_TERM{
        erts.enif_make_binary(env, &nal),
        erts.enif_make_int(env, @intCast(width)),
        erts.enif_make_int(env, @intCast(height)),
        erts.atom(env, "h264"),
        erts.enif_make_int64(env, timestamp_ms),
        kf_atom,
    };
    const map = erts.makeMap(env, &keys, &vals) orelse return;
    const msg = erts.makeTuple(env, .{ erts.atom(env, "screencast"), erts.atom(env, "frame"), map });
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── Inbound delivery — the MediaProjection consent callback calls this ────
// Builds {:screencast, :permission, :granted | :denied} so the caller of
// `MobScreencast.start_stream/1` knows the user's answer before any frame
// arrives. Before MOB-87 the granted/denied outcome was silent — the
// Elixir caller waited forever with no signal.
export fn Java_io_mob_screencast_MobScreencastBridge_nativeDeliverScreencastPermission(
    jenv: *jni.JNIEnv,
    cls: jni.JClass,
    pid_long: jni.JLong,
    granted: jni.JInt,
) callconv(.c) void {
    _ = jenv;
    _ = cls;
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);

    // erts.atom takes a comptime string, so pick the outcome atom via if
    // instead of formatting a runtime name.
    const outcome = if (granted != 0) erts.atom(env, "granted") else erts.atom(env, "denied");

    const msg =
        erts.makeTuple(env, .{ erts.atom(env, "screencast"), erts.atom(env, "permission"), outcome });
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── NIFs ──────────────────────────────────────────────────────────────────
// Copy a binary/iolist arg into a null-terminated buffer (the bridge call's
// newStringUTF copies it synchronously, so a stack buffer is fine).
fn binArgZ(env: ?*erts.ErlNifEnv, term: erts.ERL_NIF_TERM, buf: []u8) bool {
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_inspect_binary(env, term, &bin) == 0 and
        erts.enif_inspect_iolist_as_binary(env, term, &bin) == 0) return false;
    const n = @min(bin.size, buf.len - 1);
    @memcpy(buf[0..n], bin.data[0..n]);
    buf[n] = 0;
    return true;
}

fn nif_screencast_start_stream(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var jbuf: [2048]u8 = undefined;
    if (!binArgZ(env, argv[0], &jbuf)) return erts.badarg(env);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, g_sc.start_stream, pid, @ptrCast(&jbuf));
}

fn nif_screencast_stop_stream(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    return callBridgeVoid(env, g_sc.stop_stream);
}

fn nif_screencast_request_keyframe(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    return callBridgeVoid(env, g_sc.request_keyframe);
}

// Whether the HOST AndroidManifest declares io.mob.screencast.ScreencastService
// (the typed foreground service every capture runs in; the plugin manifest lists
// it under :host_requirements). A PackageManager lookup in the bridge, no side
// effects. Kotlin answers 1 = declared with foregroundServiceType mediaProjection,
// 0 = not declared, 2 = declared without the mediaProjection type (API 29+),
// 3 = no Activity handed to the bridge, anything else = the lookup failed. A
// pending Java exception is also lookup_failed: CallStaticIntMethod's return is
// then meaningless and must never read as 0 = "not declared".
fn nif_screencast_service_declared(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (g_sc_cls == null or g_sc.service_declared == null) return bridgeNotRegistered(env);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const code = jenv.*.CallStaticIntMethod.?(jenv, g_sc_cls, g_sc.service_declared);
    const threw = takePendingException(jenv);
    detachIfAttached(attached);
    if (threw) return erts.makeTuple(env, .{ erts.atom(env, "error"), erts.atom(env, "lookup_failed") });
    return switch (code) {
        1 => erts.atom(env, "true"),
        0 => erts.atom(env, "false"),
        2 => erts.makeTuple(env, .{ erts.atom(env, "error"), erts.atom(env, "not_media_projection") }),
        3 => erts.makeTuple(env, .{ erts.atom(env, "error"), erts.atom(env, "no_activity") }),
        else => erts.makeTuple(env, .{ erts.atom(env, "error"), erts.atom(env, "lookup_failed") }),
    };
}

// ── NIF table + init entry point ─────────────────────────────────────────
fn nifLoad(env: ?*erts.ErlNifEnv, priv: *?*anyopaque, info: erts.ERL_NIF_TERM) callconv(.c) c_int {
    _ = env;
    _ = priv;
    _ = info;
    return 0;
}

const nif_funcs = [_]erts.ErlNifFunc{
    .{ .name = "screencast_start_stream", .arity = 1, .fptr = nif_screencast_start_stream, .flags = 0 },
    .{ .name = "screencast_stop_stream", .arity = 0, .fptr = nif_screencast_stop_stream, .flags = 0 },
    .{ .name = "screencast_request_keyframe", .arity = 0, .fptr = nif_screencast_request_keyframe, .flags = 0 },
    .{ .name = "screencast_service_declared", .arity = 0, .fptr = nif_screencast_service_declared, .flags = 0 },
};

var nif_entry: erts.ErlNifEntry = .{
    .major = erts.ERL_NIF_MAJOR_VERSION,
    .minor = erts.ERL_NIF_MINOR_VERSION,
    .name = "mob_screencast_nif",
    .num_of_funcs = nif_funcs.len,
    .funcs = &nif_funcs,
    .load = nifLoad,
    .reload = null,
    .upgrade = null,
    .unload = null,
    .vm_variant = erts.ERL_NIF_VM_VARIANT,
    .options = 1,
    .sizeof_ErlNifResourceTypeInit = erts.SIZEOF_ErlNifResourceTypeInit,
    .min_erts = erts.ERL_NIF_MIN_ERTS_VERSION,
};

pub export fn mob_screencast_nif_nif_init() callconv(.c) *erts.ErlNifEntry {
    return &nif_entry;
}
