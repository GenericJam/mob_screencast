%{
  name: :mob_screencast,
  mob_version: "~> 0.6",
  plugin_spec_version: 1,
  description:
    "In-app screen capture → on-device H264 (MediaProjection/MediaCodec, ReplayKit/VideoToolbox), streamed to the BEAM as Annex-B NAL units for WebRTC",
  nifs: [
    # iOS: Objective-C NIF — ReplayKit/ScreenCaptureKit capture + a VideoToolbox AVC
    # encoder; emits Annex-B access units via cam_send-style enif_send. lang: :objc
    # (-fobjc-arc); platform: :ios so it isn't pulled into the Android build.
    %{module: :mob_screencast_nif, native_dir: "priv/native/ios", lang: :objc, platform: :ios},
    # Android: zig NIF bridging to MediaProjection + MediaCodec via the Kotlin
    # io.mob.screencast.MobScreencastBridge.
    %{module: :mob_screencast_nif, native_dir: "priv/native/jni", lang: :zig, platform: :android}
  ],
  android: %{
    bridge_kt: "priv/native/android/MobScreencastBridge.kt",
    bridge_class: "io.mob.screencast.MobScreencastBridge",
    # MediaProjection itself is granted per-session via a system consent dialog
    # (MediaProjectionManager.createScreenCaptureIntent), NOT a manifest permission —
    # the bridge drives that. What the manifest needs is the foreground-service perms a
    # MediaProjection capture must run under (API 34+ split out the typed one).
    permissions: [
      "android.permission.FOREGROUND_SERVICE",
      "android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION"
    ]
    # KNOWN GAP (same class as mob_camera's FileProvider): a MediaProjection capture
    # must run inside a foreground <service android:foregroundServiceType="mediaProjection">,
    # which is an AndroidManifest fragment the plugin manifest can't yet contribute.
    # Options (Stage-2 decision, tracked in EXTRACTION.md): add a manifest-fragment
    # capability to the plugin system, or carry the <service> in the host template gated
    # on mob_screencast. mob_camera flagged the identical gap for <provider>/<uses-feature>.
  },
  ios: %{
    # On-device capture uses ReplayKit's in-app RPScreenRecorder (no broadcast
    # extension, no plist key — the user grants per session). ScreenCaptureKit is the
    # simulator/macOS path. The VideoToolbox encoder needs no extra entitlement.
    frameworks: ["ReplayKit", "VideoToolbox", "CoreMedia", "CoreVideo"]
  }
}
