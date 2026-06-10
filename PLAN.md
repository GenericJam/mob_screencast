# mob_screencast — plan + checklist

In-app screen capture as a mob plugin: the device captures its **own** screen,
hardware-encodes it to **H264 on-device**, and hands Annex-B NAL units to the BEAM.
This is the in-app replacement for sloppy_joe's host-side `adb screenrecord`
(`SloppyJoe.Media.Capture.Adb`) — so a NAT'd phone can publish its screen with no adb
and no host on the same network. Follows the `mob_camera` frame-streaming template.

Pairs with sloppy_joe's WebRTC device view: the H264 NALs drop straight into
`SloppyJoe.Media.Capture.H264` (split + FU-A payload), the existing RTP path.

## Stages

- [x] **1a — package (Elixir + manifest).** `mix.exs` (path-dep mob), `lib/mob_screencast.ex`
  (`start_stream`/`stop_stream`/`request_keyframe`, delivers `{:screencast, :frame, %{bytes,
  format: :h264, keyframe, …}}`), `src/mob_screencast_nif.erl` (3 stubs), `priv/mob_plugin.exs`.
  Compiles vs local mob; manifest validates + classifies **tier 1**.
- [~] **1b — native capture + encode (the bulk).**
  - [x] **Android code written** (`priv/native/jni/mob_screencast_nif.zig` + `priv/native/android/MobScreencastBridge.kt`):
    zig NIF mirrors the device-proven mob_camera pattern (nativeRegister + 3 NIFs +
    nativeDeliverScreencastFrame → `{:screencast, :frame, %{bytes, …, keyframe}}`); Kotlin
    bridge = `MediaProjection` (consent via a headless `ScreencastConsentFragment`) →
    `MediaCodec` AVC encoder (surface input) ← `VirtualDisplay`, a drain thread that prepends
    SPS/PPS to keyframes and pushes Annex-B access units. `zig ast-check` clean; manifest
    tier 1. Targets API ≤ 33 (Moto G is API 30) so it runs without the foreground service.
  - [~] **Android device build + partial verify** (mob_plugin_demo host, Moto G ZY22DP6HFL):
    - [x] `--native` build merges the zig NIF + Kotlin bridge, compiles + links + **deploys**
      (`mix mob.plugins` shows it tier 1, vetting clean). Two real bugs found + fixed by the
      build/run: zig comptime atom (`erts.atom` needs a comptime string) + Kotlin main-thread
      fragment launch (consent dialog must post to the main thread).
    - [x] On-device: dist RPC confirmed `MobScreencast` + the NIF **load** and
      `start_stream/2` is **callable** (collector launched on the Moto G).
    - [x] **Consent → projection → encoder pipeline EXECUTES on the Moto G.** The
      MediaProjection consent dialog appears ("Start recording or casting with
      MobPluginDemo? … Start now"), and tapping Start now grants it + runs
      `onProjectionResult` (proven by a crash trace there before the guard landed). FOUR
      bugs found+fixed by the device build/run: zig comptime atom; main-thread; the host is
      a Compose ComponentActivity not a FragmentActivity (use ActivityResultRegistry like
      mob_camera); `onProjectionResult` crashed unguarded on the encoder setup (now wrapped
      + integer I-frame interval).
    - [x] **FRAMES FLOW END-TO-END ON THE MOTO G (2026-06-10).** `capturing 358x720 @
      1000000bps`; the collector saw `{:screencast, :frame, …}` count climb `{55,true}` →
      `{75,true}` (~10 fps, keyframes prefixed with SPS/PPS), `ERR=:none`,
      `screencast_stop_stream → :ok`. Two more real bugs found + fixed to get here:
      - **Stale binary / driver_tab:** the running app reported `:nif_not_loaded` for
        screencast while camera loaded — the installed `.so`'s compiled `driver_tab` predated
        the screencast row (the regen happened after that build). A clean Android-only
        `mix mob.deploy --native --device ZY22DP6HFL` rebuilt it and `screencast_request_keyframe`
        returned `:ok`. (The dual-platform build fails on the not-yet-written iOS `.m`; the
        `--device <android>` form builds Android only.)
      - **Foreground service required even on API 30:** `getMediaProjection` threw
        `SecurityException: Media projections require a foreground service of type …
        MEDIA_PROJECTION`. The "API ≤ 33 runs directly" assumption was wrong on this OEM build.
        Fixed: `ScreencastService` (foreground service, `FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION`,
        folded into bridge_kt since the merge copies only one Kotlin file) + a `<service
        android:foregroundServiceType="mediaProjection">` in the host AndroidManifest;
        `onProjectionResult` now stashes the consent result and starts the service, which
        foregrounds itself then calls `beginCaptureFromService` to obtain the projection.
  - [~] **iOS** (`priv/native/ios/mob_screencast_nif.m`): WRITTEN. `RPScreenRecorder`
    (in-app `startCaptureWithHandler`, per-session consent, mic off) → `VideoToolbox`
    `VTCompressionSession` (H264, constrained-baseline, no B-frames, realtime) → AVCC→Annex-B
    conversion in the VT output callback (SPS/PPS from the format description prepended to
    keyframes) → `enif_send` of the SAME `{:screencast, :frame, %{bytes, width, height, format:
    :h264, timestamp_ms, keyframe}}` map the Android NIF emits. Consent outcome →
    `{:screencast, :permission, :granted | :denied}` from the completion handler. All VT
    lifecycle is serialized on a single `io.mob.screencast.session` queue (sample buffers
    CFRetain'd across the async hop); `request_keyframe` sets a force-IDR flag for the next
    encode. `ERL_NIF_INIT(mob_screencast_nif, …)`.
    - [x] **Compiles + static-links** (verified isolated, not yet in a full mob build):
      `-fsyntax-only` clean against iPhoneOS26.4 SDK; `-c` with mob's exact iOS NIF flags
      (`-fobjc-arc -fmodules -DSTATIC_ERLANG_NIF -DSTATIC_ERLANG_NIF_LIBNAME=mob_screencast_nif`)
      exits 0 and produces the `_mob_screencast_nif_nif_init` symbol the iOS driver_tab references.
    - [ ] **Full mob iOS build + on-device verify** (iPhone — ReplayKit screen capture doesn't
      work on the simulator). Needs re-enabling `:mob_screencast` in the host mob.exs (now safe:
      the `.m` exists + compiles, so the dual-platform build no longer fails at
      `mob_screencast_nif.o`) and a device. Drive `start_stream` → ReplayKit consent → confirm
      `{:screencast, :frame, …}` H264 flows + a keyframe carries SPS/PPS. NOTE: `max_size` is
      NOT yet honored on iOS (encodes at native screen res; bitrate is still capped by the
      encoder's AverageBitRate, so output size is fine — quality/CPU only). A parallel iOS
      agent shares this device + mob.exs, so coordinate.
- [ ] **2 — sloppy_joe integration (architecture fork; downstream of the plugin).**
  The device BEAM has H264; getting it to the browser is the decision:
  - **A. Carrier relay** — the device ships NALs over its existing `/device` dial-out
    (DeviceLink); a new host-side `SloppyJoe.Media.Capture.MobScreencast` receives them and
    feeds the host Publisher's `send_rtp`. Reuses the whole stack; reaches NAT'd phones;
    **server relays media** (not pure P2P). Smallest lift.
  - **B. On-device WebRTC** — the device runs the WebRTC publisher itself (ex_webrtc on
    mob), P2P to the browser via STUN/TURN, server signaling-only. Truest decoupling;
    **large** native lift (SRTP/ICE on device).
  Recommendation: A first (it's mostly wiring + reuses everything), B as a later option.
- [ ] **3 — device-verify** Moto G ZY22DP6HFL + iPhone: `start_stream` → frames decode;
  foreground-service consent flow; parity with `Capture.Adb` output.
- [ ] **4 — tests, docs, `mix mob.plugin.sign`, CHANGELOG, mob_new wizard opt-in.**

## Known gaps

- **AndroidManifest fragment (foreground service):** a `MediaProjection` capture must run
  inside `<service android:foregroundServiceType="mediaProjection">`, which the plugin
  manifest can't yet contribute (`apply_plugin_android_manifest!` merges only
  `<uses-permission>`, not `<service>` — identical class to `mob_camera`'s
  FileProvider/uses-feature gap). **WORKED AROUND for the device verify** by carrying the
  `<service android:name="io.mob.screencast.ScreencastService" …
  foregroundServiceType="mediaProjection">` in the host (`mob_plugin_demo`) AndroidManifest;
  the plugin contributes the `FOREGROUND_SERVICE*` `<uses-permission>` entries. **Stage-2
  decision still open:** add a manifest-fragment capability to the plugin system so the
  `<service>` ships with the plugin, instead of every host having to declare it.
- **Per-session consent UX:** both platforms prompt the user each capture session. For an
  unattended emulator that's a one-time tap; for a phone it's per session by OS policy.
