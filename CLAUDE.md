# mob_screencast — Agent Instructions

**Read [`AGENTS.md`](AGENTS.md) first**, then [`~/code/mob/AGENTS.md`](../mob/AGENTS.md) for the system view, and `~/code/mob/MOB_PLUGINS.md` for the manifest schema. Together they cover the plugin anatomy, the `{:screencast, :frame, ...}` contract, per-session consent, and the cross-repo work with mob / mob_dev / sloppy_joe. This file goes deeper on Claude Code-specific workflow detail.

> **Keep AGENTS.md up to date** when you change the frame contract, add an option, or hit a new gotcha. Out-of-date guidance there causes wrong decisions downstream — fix it in the same commit.

## What this repo is

A Mob capability plugin extracted from mob core (Wave 2). Captures the **device's own screen** and hardware-encodes to H264 on-device (Android `MediaProjection` → `MediaCodec`; iOS `ReplayKit` → `VideoToolbox`). The BEAM receives Annex-B NAL units ready to drop into a WebRTC RTP payloader. `:max_size` is Android-only today (iOS captures at native resolution). Android verified Moto G Power 5G 2024 (API 30).

## Pre-commit checklist

Before committing, run all in this order:

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
* **Never ship without a device build on both platforms** — the encoder paths (`MediaCodec` on Android, `VideoToolbox` on iOS) are genuinely different code, and simulators lie about screen-capture behaviour. Kevin has a Moto G Power 5G 2024 and an iPhone SE for device verification.
