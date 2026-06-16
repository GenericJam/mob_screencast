# Changelog

All notable changes to **mob_screencast** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

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
