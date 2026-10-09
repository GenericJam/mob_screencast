# mob_screencast — Agent Instructions

You're in **mob_screencast**, a Mob capability plugin (extracted from mob core in Wave 2) that captures the **device's own screen** and hardware-encodes it to H264 on-device — the in-app replacement for host-side `adb screenrecord`. Encoded Annex-B NAL units arrive in the calling screen's mailbox as `{:screencast, :frame, %{bytes, format: :h264, keyframe, ...}}`, ready to drop into a WebRTC RTP payloader.

**Also read [`~/code/mob/AGENTS.md`](../mob/AGENTS.md)** for the system view — the three-repo topology, plugin manifest schema, `MobActivityAware`, native build pipeline, cross-cutting pre-empt-failure rules — and `~/code/mob/MOB_PLUGINS.md` for the manifest schema. This file is mob_screencast-specific.

> **Keep this file current.** When you change the frame contract, add an option, or hit a gotcha that would trip the next agent, fix it here in the same commit — not a follow-up.

## What mob_screencast is, in one paragraph

Three public functions: `start_stream/2`, `stop_stream/1`, `request_keyframe/0`. `start_stream` triggers the per-session consent flow (Android `MediaProjection` system dialog, iOS ReplayKit broadcast prompt), reports outcome as `{:screencast, :permission, :granted | :denied}`, then delivers each encoded H264 access unit as `{:screencast, :frame, %{bytes, format: :h264, width, height, timestamp_ms, keyframe}}`. Bytes are Annex-B (`00 00 00 01` start codes); keyframes are prefixed with SPS/PPS by the native drain thread so a fresh viewer's decoder can lock on. Options: `:bitrate` (default 2_000_000), `:fps` (30), `:keyframe_interval_ms` (2000), `:max_size` (Android only — caps the longer edge in px; iOS captures at native resolution today).

## What mob_screencast is NOT

* **Not [mob_camera](https://hexdocs.pm/mob_camera).** That's the camera feed; this is the screen's pixels. Different platform surfaces (`CameraX` / `AVCaptureSession` vs `MediaProjection` / `ReplayKit`), different consent flows, different frame streams. The Elixir shapes deliberately rhyme (`mob_screencast` follows the mob_camera frame-streaming template), but they are separate plugins.
* **Not a WebRTC stack.** mob_screencast produces H264 access units. Pairing with a WebRTC sender is the caller's problem — the NAL bytes drop straight into `SloppyJoe.Media.Capture.H264` (split + FU-A payload) on the sloppy_joe side, but that's WebRTC's job, not this plugin's.
* **Not a raw-pixel API.** The BEAM receives already-encoded H264; the encoder (`MediaCodec` / `VideoToolbox`) runs in the native layer. Do not add a "give me raw frames" mode — the whole point is that only compressed bytes cross the NIF boundary.
* **Not a schedule.** `start_stream` needs an active screen and a granted consent dialog every session; there is no background-mode screen capture here.

## Anatomy of the plugin

* `lib/mob_screencast.ex` — the public API. Moduledoc is the canonical contract for the `{:screencast, :frame, ...}` and `{:screencast, :permission, ...}` message shapes.
* `src/mob_screencast_nif.erl` — four Erlang NIF stubs (`screencast_start_stream/1`, `screencast_stop_stream/0`, `screencast_request_keyframe/0`, and the self-test probe `screencast_service_declared/0`: Android asks `PackageManager` whether the host manifest declares `ScreencastService` with the `mediaProjection` type, iOS always answers `true`).
* `lib/mob_screencast/self_test.ex` — `MobScreencast.SelfTest` (`Mob.Plugin.SelfTest`, run by `mix mob.selftest`): `screencast_stop_stream/0` while idle must answer `:ok`, then `screencast_service_declared/0`; a host without the service is a skip, not a pass. On Android every NIF answers `{:error, :bridge_not_registered}` (instead of calling JNI through a null class) when `MobScreencastBridge.register()` never ran.
* `priv/mob_plugin.exs` — the manifest. Android `:permissions` = `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MEDIA_PROJECTION`. `:host_requirements` warns about a manifest fragment the plugin cannot yet contribute.
* `priv/native/ios/mob_screencast_nif.m` — Objective-C NIF: ReplayKit / ScreenCaptureKit capture + VideoToolbox AVC encoder; emits Annex-B via `enif_send` (mob_camera-style).
* `priv/native/jni/mob_screencast_nif.zig` — Android NIF glue.
* `priv/native/android/MobScreencastBridge.kt` — `MediaProjection` consent (via a headless `ScreencastConsentFragment`) → `MediaCodec` AVC encoder (surface input) ← `VirtualDisplay`, drain thread prepends SPS/PPS to keyframes.
* `PLAN.md` — staged rollout + verification checkpoints (Android verified Moto G API 30; iOS pieces staged).

## Cross-repo work

**mob (framework):** the Android bridge follows mob_camera's `nativeRegister` + `nativeDeliverFrame` template; if `MobActivityAware` or the plugin bootstrap changes in mob core, this plugin is on the re-verify list. See [`~/code/mob/AGENTS.md`](../mob/AGENTS.md).

**mob_dev:** builds the native sources on `mix mob.deploy --native`. **Host manifest gap:** MediaProjection capture must run inside a typed foreground `<service android:foregroundServiceType="mediaProjection" />` — the plugin manifest can't contribute a manifest fragment yet, so `priv/mob_plugin.exs` declares this under `:host_requirements` and the build prints a warning on every native deploy. Without it, the host builds fine and throws `SecurityException` at first capture. mob_camera has the same class of gap.

**Pair-with (not depend-on): [sloppy_joe](../sloppy_joe/AGENTS.md).** The H264 NALs are shaped to drop into sloppy_joe's WebRTC device-view pipeline. mob_screencast has no code dependency on sloppy_joe; the contract is the wire format.

## Testing

Elixir suite (validator + `stream_opts/1` defaults):

```bash
mix deps.get
mix test
```

Native code isn't exercised by `mix test`. Device test:

* `mix mob.deploy --native` a host that calls `MobScreencast.start_stream(socket)` from a screen.
* Confirm the consent dialog appears (Android system UI; iOS ReplayKit prompt).
* Confirm `{:screencast, :frame, %{keyframe: true}}` arrives first, then a stream of `keyframe: false` frames.
* Confirm `request_keyframe/0` produces a new IDR within one `keyframe_interval_ms` window.
* Android verified on a Moto G Power 5G 2024 (ZY22DP6HFL, API 30) — real reliability signal.

## The pre-empt-failure rules that matter here

1. **Consent is per-session.** Do not cache the `MediaProjection` intent across app launches — Android tightened this post-14 and iOS never allowed it. `start_stream` triggers a fresh dialog every time.
2. **`:max_size` is Android-only today.** iOS captures at native resolution — do not document a cross-platform `max_size`; there's a TODO in the iOS NIF and it hasn't landed. If you fix that, update `lib/mob_screencast.ex`'s moduledoc + `stream_opts/1` + this file in the same commit.
3. **Keyframes carry SPS/PPS.** Downstream decoders need them prepended. The drain thread does this; if you refactor the encoder path, verify a fresh viewer joining mid-stream can decode after the next `request_keyframe/0`.
4. **The foreground-service host_requirement is not optional.** Every host running a real MediaProjection capture must declare that `<service>` — the plugin can print a warning but cannot enforce it. If a host reports `SecurityException` on first capture, check their AndroidManifest first.
5. **BEAM receives compressed bytes only.** Never expose a raw-frame path in the NIF — the encoder-on-device story is the point.

## Pre-commit checklist

Standard mob plugin gate. Before committing, run all in this order:

```bash
mix format
mix credo --strict                  # includes ExSlop + jump_credo_checks
mix compile --warnings-as-errors
mix test
zig fmt priv/native/jni/*.zig
xcrun clang-format -i priv/native/ios/*.m
mix mob.validate_plugin             # from a host app
```

Pre-push hook (`.githooks/pre-push`) adds format + credo strict + compile + fast tests on every push. Activate once per clone:

```bash
git config core.hooksPath .githooks
```

Native changes (.m / .zig / .kt) aren't exercised by `mix test`. They need `mix mob.deploy --native` of a host app and a device check — for this plugin the check is: consent dialog fires, first frame is `keyframe: true`, `request_keyframe/0` produces an IDR within a `keyframe_interval_ms` window.

### Tests are part of the change

New behaviour ships with a test unless the change is small enough that a test would only restate it. Bar: **would this test fail if the fix were reverted?** For mob_screencast specifically:

* Any change to `stream_opts/1` defaults needs a pin — the encoder is watching those numbers.
* Any change to the `{:screencast, :frame, ...}` shape needs a matching moduledoc + Kotlin + zig + ObjC update in the same commit.

### Adversarial review — before every non-trivial commit

Spawn a subagent, point it at the diff, tell it to find defects. Especially:

* **Per-session consent.** MediaProjection intents can't be cached across launches — a "clever optimization" here is a security regression.
* **Keyframe SPS/PPS prepending.** A fresh viewer joining mid-stream must be able to decode after the next IDR. Off-by-one on prepending breaks this silently.
* **Foreground-service host_requirement.** The `:host_requirements` warning is not decorative — a host without the `<service android:foregroundServiceType="mediaProjection" />` fragment throws `SecurityException` at first capture, not at build time.

Skip only for: formatting, a typo, a version bump, a changelog edit.

## Release flow

Canonical process in [`~/code/mob/RELEASE.md`](../mob/RELEASE.md). mob_screencast specifics:

* `@version` in `mix.exs` is the trigger. Push to master, GH Actions handles tag / GitHub release / Hex publish, signed with the shared mob first-party key.
* Do NOT bump without a green device build and explicit permission.
* **Never ship without a device build on both platforms** — the encoder paths (`MediaCodec` on Android, `VideoToolbox` on iOS) are genuinely different code, and simulators lie about screen-capture behaviour. Kevin has a Moto G Power 5G 2024 and an iPhone SE for device verification.
