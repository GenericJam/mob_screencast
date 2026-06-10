%% mob_screencast_nif — Erlang NIF module for the screen-capture tier-1 plugin.
%%
%% Android: priv/native/jni/mob_screencast_nif.zig bridges to the Kotlin
%% io.mob.screencast.MobScreencastBridge (MediaProjection capture + a MediaCodec
%% AVC encoder; encoded NAL units are handed back via nativeDeliverScreencastFrame).
%% iOS: priv/native/ios/mob_screencast_nif.m (ReplayKit / ScreenCaptureKit capture +
%% a VideoToolbox H264 encoder). Both register this module via ERL_NIF_INIT and are
%% statically linked into the host binary on device. On a host dev build neither is
%% linked, so on_load tolerates the failure and the NIFs fall back to nif_error until
%% the native merge links one.
-module(mob_screencast_nif).
-export([
    screencast_start_stream/1,
    screencast_stop_stream/0,
    screencast_request_keyframe/0
]).
-on_load(init/0).

init() ->
    case erlang:load_nif("mob_screencast_nif", 0) of
        ok -> ok;
        {error, _} -> ok
    end.

screencast_start_stream(_ConfigJson) ->
    erlang:nif_error(nif_not_loaded).

screencast_stop_stream() ->
    erlang:nif_error(nif_not_loaded).

screencast_request_keyframe() ->
    erlang:nif_error(nif_not_loaded).
