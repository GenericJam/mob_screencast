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
- [ ] **1b — native capture + encode (the bulk).**
  - **Android** (`priv/native/android/MobScreencastBridge.kt` + `priv/native/jni/mob_screencast_nif.zig`):
    `MediaProjection` (system consent intent) → `VirtualDisplay` → a `MediaCodec` AVC
    encoder in surface mode → drain encoded NAL units → `nativeDeliverScreencastFrame`.
    Must run under a foreground service (see Known gap).
  - **iOS** (`priv/native/ios/mob_screencast_nif.m`): `RPScreenRecorder` (in-app, per-session
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
