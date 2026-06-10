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
    - [ ] **Frame flow blocked by the device environment, not the plugin:** the Moto G's
      dist is flaky (two-phone port collision; Android backgrounding suspends the BEAM, so
      the node drops) and the shared demo host's other plugins (camera screen + its
      permission dialog) compete with the MediaProjection consent. Needs a clean dedicated
      session (a dedicated emulator, or the phone with the other Moto's app stopped + a fresh
      `mix mob.connect` kept foregrounded) to drive consent → `{:screencast, :frame, …}` →
      decode. Alternatively add a demo UI button so a tap triggers it without dist.
  - [ ] **iOS** (`priv/native/ios/mob_screencast_nif.m`): `RPScreenRecorder` (in-app, per-session
    consent) sample buffers → `VideoToolbox` `VTCompressionSession` (H264) → Annex-B NALs →
    enif_send. ScreenCaptureKit for the simulator/macOS path.
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
  manifest can't yet contribute (identical class to `mob_camera`'s FileProvider/uses-feature
  gap). Stage-2 decision: add a manifest-fragment capability to the plugin system, or carry
  the `<service>` in the host template gated on this plugin.
- **Per-session consent UX:** both platforms prompt the user each capture session. For an
  unattended emulator that's a one-time tap; for a phone it's per session by OS policy.
