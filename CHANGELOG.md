# Changelog

All notable changes to **mob_screencast** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added

- **On-device self-test** (MOB-418). `MobScreencast.SelfTest` implements
  `Mob.Plugin.SelfTest` and is declared in the manifest as `selftest:`. It
  calls `screencast_stop_stream/0` while nothing is capturing (must answer
  `:ok`: the NIF is linked and, on Android, the Kotlin bridge is registered),
  then the new `screencast_service_declared/0`: on Android the bridge asks
  `PackageManager.getServiceInfo` whether the host manifest declares
  `io.mob.screencast.ScreencastService` with `foregroundServiceType`
  `mediaProjection` (`true` passes; a host without it, such as a
  `mix mob.new --blank` app, is
  `{:skip, "host lacks <service io.mob.screencast.ScreencastService>"}`); on
  iOS it answers `true` (in-app ReplayKit needs nothing declared by the
  host). Run it with `mix mob.selftest` from a host app (mob_dev 0.7.17).
  Requires mob 0.9.15; `mob_version` in the manifest is now `~> 0.9`.
- **Android: the NIF reports an unregistered bridge.** `screencast_start_stream/1`,
  `screencast_stop_stream/0`, `screencast_request_keyframe/0` and
  `screencast_service_declared/0` answer `{:error, :bridge_not_registered}`
  when `MobScreencastBridge.register()` never ran or a method-ID lookup
  failed, instead of calling JNI through a null class. The public API ignores
  the return value; the self-test turns it into a failure.

## [0.1.2] - 2026-09-30

### Fixed

- **Android: `{:screencast, :permission, :granted | :denied}` is now
  actually delivered** (MOB-87). The MediaProjection consent callback
  in `MobScreencastBridge` only invoked `onProjectionResult` on
  `RESULT_OK` and dropped the denial path entirely — callers of
  `MobScreencast.start_stream/1` who awaited the documented
  `{:screencast, :permission, ...}` event blocked forever, and even
  the granted case never emitted one. A new
  `nativeDeliverScreencastPermission/2` thunk (zig NIF +
  Kotlin extern) fires from BOTH branches of the consent callback
  before the async begin-capture chain, so callers can distinguish
  "user said no" from "user said yes but frames not started yet".
- **Android: screencast frames are no longer corrupt** (MOB-298). In
  0.1.1 the zig `nativeDeliverScreencastFrame` thunk declared a raw
  pointer + length where the Kotlin `external fun` passes a `ByteArray`,
  shifting every JNI argument: each `{:screencast, :frame, ...}` event
  carried a garbage `bytes` payload (read from arbitrary memory, length =
  the capture width, no Annex-B start code), wrong `width`/`height`,
  `timestamp_ms: 0` and `keyframe: false`. The thunk now matches the
  Kotlin signature and copies the array with `GetByteArrayRegion`, so
  frames carry the real H.264 access unit, capture size, timestamp and
  keyframe flag.

### Changed
- **Re-signed with plugin envelope v2** (MOB-287). mob_dev 0.7.2+ verifies
  this signature before evaluating the manifest. mob_dev 0.7.0 / 0.7.1 can't
  read v2 signatures and report this release as `invalid signature` —
  upgrade the host app to `{:mob_dev, "~> 0.7.2", only: :dev, runtime: false}`.

## [0.1.1] - 2026-06-16

### Changed
- Signed release: the published package now carries a verified Ed25519
  signature (shared mob first-party key, regenerated in CI on every
  release). Generated apps trust it via `config :mob, :trusted_plugins`,
  so it clears the plugin signature gate without `acknowledge_unsafe_plugins`.

## [0.1.0] - 2026-06-12

Initial release. In-app screen capture to on-device H264 (MediaProjection / ReplayKit) for Mob apps.

- `MobScreencast.start_stream/2`, `stop_stream/1`, `request_keyframe/0`; Annex-B NAL units delivered to the caller.
- Extracted from mob core in the 0.7.0 plugin-extraction wave.
- Requires `mob ~> 0.7`.
